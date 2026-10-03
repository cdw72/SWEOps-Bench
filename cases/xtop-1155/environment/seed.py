#!/usr/bin/env python3
"""Generic containerized seeding engine (N4) — config-driven.

Reads /seed-data/seed-config.json (per-case recipe) and drives the whole
fault-seeding sequence with pure kubectl. Baked into the task env image;
runs INSIDE the harbor `main` service BEFORE the agent (healthcheck-gated on
/tmp/seed-done).

Config schema (see another-case's seed-config.json for a worked example):
  pre_manifests:   [files] applied before the operator (cert-manager etc.)
  pre_ready:       [[kubectl args, want-string], ...] waits after pre
  operator_bundle: file applied with CRDs server-side + optional rewrites
  image_rewrites:  [[from, to], ...]
  operator_ready:  [kubectl args, want-string]
  cr_sequence:     [{file, ns?, wait?[[args,want],...]?, settle?sec, timeout?}]
  fault_verify:    [[args, want], ...]  (STRICT: a MISS aborts the seed;
                   set fault_verify_optional:true to degrade it to log-only.
                   Commands go through `sh -c`, so quote any argument holding
                   shell metacharacters -- notably the `(...)` of a
                   `?(@.name==...)` jsonpath filter, which otherwise dies with
                   `Syntax error: "(" unexpected` and MISSes for a reason that
                   has nothing to do with the fault.)
  trigger:         [[args, ...], ...]   kubectl commands after fault
  settle_sec:      int
  fault_verify_after:
                   same shape as fault_verify but evaluated AFTER trigger +
                   settle_sec, and always strict. Use it -- not fault_verify --
                   whenever the trigger itself injects the fault; a probe in
                   the wrong slot MISSes no matter how healthy the fault is.
  stale_proxy:     optional {ns, cluster_ip, operator:{kind,name}, scope}
                   deploy an in-cluster read-stale/write-real TLS proxy and
                   route the operator through it (see setup_stale_proxy).
  trigger_timeout: seconds allowed for trigger_script (default 1500)
  wait_nodes:      int -- how many nodes must be Ready before anything is
                   applied. Default 0 = the single-node behaviour (step 1's
                   `get nodes` returns as soon as ANY node is Ready, which is
                   all a single-node env needs and all it can ever see).
  node_labels:     {"k=v": count, ...} -- labels that must be present on at
                   least `count` Ready nodes. Multi-node cases carry these on
                   the k3s AGENT services (`--node-label` in docker-compose),
                   because the fault is usually "the CR selects a label only
                   some nodes carry": if a worker registers late, the CR just
                   waits on Pending pods and the fault never forms.
"""
import json
import os
import subprocess
import time

K3S_SERVER = os.environ.get("K3S_SERVER", "https://k3s:6443")
SRC_KC = "/seed-kc/kubeconfig"
WORK_KC = "/tmp/kc.yaml"
CTR_ADDR = "/run/k3s/containerd/containerd.sock"
DATA = "/seed-data"
IMAGES = "/images"
AGENT_KC = "/kube/config"

log = lambda *a: print("[seed]", *a, flush=True)


def sh(cmd, timeout=30):
    log("$", cmd)
    try:
        r = subprocess.run(cmd, shell=True, capture_output=True, text=True,
                           timeout=timeout)
    except subprocess.TimeoutExpired:
        log("! timeout after %ss" % timeout)
        return None
    if r.returncode != 0:
        log("! rc=%s: %s" % (r.returncode, r.stderr.strip()[-400:]))
    return r


def kctl(args, timeout=30):
    return sh(f"kubectl --kubeconfig {WORK_KC} {args}", timeout=timeout)


def wait_kubectl(args, want=None, timeout=300, interval=3):
    deadline = time.time() + timeout
    while time.time() < deadline:
        r = kctl(args, timeout=25)
        if r is not None and r.returncode == 0 and (want is None or want in r.stdout):
            return r
        time.sleep(interval)
    raise SystemExit(f"[seed] timeout waiting: {args}")


def _has_object(block):
    """True when a `---`-split block actually carries a YAML document.

    Mirrors resolution/run_resolution.py:_has_object. A bundle that opens with
    a `#`-comment header splits into a first block that is non-blank text but
    holds no object; `kubectl apply` on it fails with "error: no objects passed
    to apply", which aborts the seed at block 0 and reads like a broken bundle.
    """
    return any(l.strip() and not l.lstrip().startswith("#")
               for l in block.splitlines())


def apply_manifest(path, label, rewrites=None, apply_ns=None, no_ssa=False):
    import re as _re
    blocks = [b for b in _re.split(r"^---\s*$", open(path).read(), flags=_re.M)
              if _has_object(b)]
    for i, b in enumerate(blocks):
        for frm, to in (rewrites or []):
            b = b.replace(frm, to)
        p = f"/tmp/apply-{i}.yaml"
        open(p, "w").write(b)
        # -n only when the block has no explicit namespace (else kubectl
        # rejects the mismatch)
        nsflag = ""
        if apply_ns and not _re.search(r"^\s*namespace:\s*\S+", b, _re.M):
            nsflag = f"-n {apply_ns} "
        ss = "apply --server-side=true -f " if (
            "kind: CustomResourceDefinition" in b and not no_ssa) else "apply -f "
        cmd = nsflag + ss + p
        r = kctl(cmd, timeout=60)
        for _ in range(5):  # webhook endpoints may still be settling
            if r is not None and (r.returncode == 0 or "webhook" not in (r.stderr + r.stdout).lower()):
                break
            time.sleep(10)
            r = kctl(cmd, timeout=60)
        if r is None or r.returncode != 0:
            raise SystemExit(f"[seed] {label} block {i} apply failed")
    log(f"{label} applied ({len(blocks)} blocks)")


K3S_TLS = "/k3s-tls"          # k3s's PKI dir, shared from the k3s service
STALE_IMG = "sweops/stale-proxy:n3"
# SANs every in-cluster client of the apiserver might dial. 10.43.0.1 is
# k3s's own apiserver ClusterIP (first address of the default 10.43.0.0/16
# service CIDR); the case's pinned proxy IP is added separately.
STALE_DNS = ["kubernetes.default.svc", "kubernetes.default", "kubernetes",
             "kubernetes.default.svc.cluster.local"]
# Upstream by ClusterIP, never by name: `kubernetes.default.svc` resolves via
# CoreDNS, which is still coming up in the first minutes of a fresh env -- the
# first proxied request then dies in the resolver and the symptom ("upstream
# error: ... read: connection refused") looks like a proxy bug. 10.43.0.1 is
# the apiserver's own ClusterIP and it is a SAN of the apiserver's serving
# cert, so there is nothing DNS was buying us.
STALE_UPSTREAM = "https://10.43.0.1:443"
STALE_IPS = ["10.43.0.1", "127.0.0.1"]


def _b64(path):
    import base64
    return base64.b64encode(open(path, "rb").read()).decode()


def proxy_ctl(ns, name, path, body=None):
    """Drive the proxy's control API (:8080) from a script outside the cluster.

    The Service ClusterIP is not routable from this container -- it only
    exists inside the k3s network namespace (services are iptables rules in
    the node, not addresses on the docker bridge) -- and a `kubectl
    port-forward` would have to outlive the call. So the request rides
    `kubectl exec` into the pod and never leaves its loopback; the busybox
    base carries wget, which is the only reason this needs no sidecar.
    """
    import shlex
    post = f"--post-data={shlex.quote(body)} " if body is not None else ""
    r = kctl(f"-n {ns} exec deploy/{name} -- wget -qO- {post}"
             f"http://127.0.0.1:8080{path}", timeout=60)
    if r is None or r.returncode != 0:
        raise SystemExit(f"[seed] stale_proxy: {path} failed: "
                         f"{(r.stderr if r else 'timeout')[-300:]}")
    return r.stdout.strip()


def setup_stale_proxy(cfg):
    """Deploy an in-cluster read-stale/write-real proxy and route the operator
    into it (config key `stale_proxy`).

    Why in-cluster rather than the host-side docker container the sieve track
    used: the operator under test runs as a pod, so the only network path it
    has to the apiserver is the one client-go builds from
    KUBERNETES_SERVICE_HOST/PORT -- and the only CA it will accept for that
    connection is the one in its serviceaccount ca.crt (= k3s's server CA).
    A proxy therefore has to (a) live somewhere the pod can dial and (b) serve
    a cert signed by that CA. Both are satisfied by running it as a pod behind
    a pinned ClusterIP, with /k3s-tls (shared from the k3s service) supplying
    the CA key at seed time.

    Fault semantics are unchanged from the host version: scope names the
    resources whose LIST/GET come from a captured snapshot once /stale/on is
    posted; every write and every unscoped read is forwarded to the real
    apiserver.
    """
    sp = cfg["stale_proxy"]
    ns, name, ip = sp["ns"], sp.get("name", "stale-proxy"), sp["cluster_ip"]
    work = "/tmp/stale-proxy"
    os.makedirs(work, exist_ok=True)

    ca, cak = f"{K3S_TLS}/server-ca.crt", f"{K3S_TLS}/server-ca.key"
    deadline = time.time() + 180
    while time.time() < deadline and not (os.path.exists(ca) and os.path.exists(cak)):
        time.sleep(3)
    if not (os.path.exists(ca) and os.path.exists(cak)):
        raise SystemExit(f"[seed] stale_proxy: k3s server CA never appeared in "
                         f"{K3S_TLS} -- is the k3s-tls volume mounted in BOTH "
                         "compose services?")

    ips = [ip] + list(sp.get("ips", STALE_IPS))
    dns = list(sp.get("dns", STALE_DNS))
    with open(f"{work}/server.ext", "w") as f:
        f.write("subjectAltName=" + ",".join([f"DNS:{d}" for d in dns]
                                             + [f"IP:{i}" for i in ips]) +
                "\nextendedKeyUsage=serverAuth\n")
    # -CAserial is a PATH we own: /k3s-tls is mounted read-only here, so
    # openssl's default (a .srl next to the CA cert) would fail on write.
    for cmd in (
        f"openssl genrsa -out {work}/server.key 2048",
        f"openssl req -new -key {work}/server.key -out {work}/server.csr "
        f"-subj /CN=kubernetes.default.svc",
        f"openssl x509 -req -in {work}/server.csr -CA {ca} -CAkey {cak} "
        f"-CAcreateserial -CAserial {work}/ca.srl -out {work}/server.crt "
        f"-days 3650 -extfile {work}/server.ext",
    ):
        r = sh(cmd)
        if r is None or r.returncode != 0:
            raise SystemExit(f"[seed] stale_proxy: cert step failed ({cmd})")

    # Upstream identity: the admin client cert out of the kubeconfig k3s wrote
    # for us (same identity the host bridge copied off the control-plane
    # container). The operator's own token rides along in the forwarded
    # headers, but a snapshot must never depend on the caller's RBAC.
    import base64 as _b64mod
    kc = open(WORK_KC).read()
    emb = {}
    for field in ("client-certificate-data", "client-key-data"):
        for line in kc.splitlines():
            if line.strip().startswith(field + ":"):
                emb[field] = _b64mod.b64decode(line.split(":", 1)[1].strip())
    if len(emb) != 2:
        raise SystemExit("[seed] stale_proxy: kubeconfig carries no embedded "
                         "client cert/key; cannot authenticate upstream")
    for field, dest in (("client-certificate-data", "client.crt"),
                        ("client-key-data", "client.key")):
        with open(f"{work}/{dest}", "wb") as f:
            f.write(emb[field])

    man = f"""apiVersion: v1
kind: Secret
metadata:
  name: {name}-certs
  namespace: {ns}
type: Opaque
data:
  server.crt: {_b64(work + '/server.crt')}
  server.key: {_b64(work + '/server.key')}
  ca.crt: {_b64(ca)}
  client.crt: {_b64(work + '/client.crt')}
  client.key: {_b64(work + '/client.key')}
---
apiVersion: v1
kind: Service
metadata:
  name: {name}
  namespace: {ns}
spec:
  clusterIP: {ip}
  selector:
    app: {name}
  ports:
  - name: https
    port: 443
    targetPort: 443
  - name: control
    port: 8080
    targetPort: 8080
---
apiVersion: apps/v1
kind: Deployment
metadata:
  name: {name}
  namespace: {ns}
spec:
  replicas: 1
  selector:
    matchLabels:
      app: {name}
  template:
    metadata:
      labels:
        app: {name}
    spec:
      containers:
      - name: proxy
        image: {sp.get("image", STALE_IMG)}
        imagePullPolicy: Never
        args:
        - -cert=/certs/server.crt
        - -key=/certs/server.key
        - -ca=/certs/ca.crt
        - -client-cert=/certs/client.crt
        - -client-key=/certs/client.key
        - -upstream={sp.get("upstream", STALE_UPSTREAM)}
        ports:
        - name: https
          containerPort: 443
        - name: control
          containerPort: 8080
        readinessProbe:
          httpGet:
            path: /health
            port: control
          initialDelaySeconds: 2
          periodSeconds: 2
        resources:
          requests:
            cpu: 50m
            memory: 64Mi
          limits:
            memory: 512Mi
        volumeMounts:
        - name: certs
          mountPath: /certs
          readOnly: true
      volumes:
      - name: certs
        secret:
          secretName: {name}-certs
"""
    p = "/tmp/stale-proxy.yaml"
    open(p, "w").write(man)
    r = kctl(f"apply -f {p}", timeout=90)
    if r is None or r.returncode != 0:
        raise SystemExit("[seed] stale_proxy: manifest apply failed")
    wait_kubectl(f"-n {ns} get deploy {name}", want="1/1", timeout=420)
    r = kctl(f"-n {ns} get svc {name} -o jsonpath='{{.spec.clusterIP}}'")
    got = (r.stdout or "").strip() if r is not None else ""
    if got != ip:
        raise SystemExit(f"[seed] stale_proxy: service clusterIP {got!r} != "
                         f"pinned {ip!r} (the serving cert SAN would not match "
                         "the address the operator dials)")
    sc = json.dumps(sp.get("scope", {"cr": {}, "resources": []}))
    proxy_ctl(ns, name, "/scope", sc)
    log(f"stale proxy up at {ip} in ns/{ns}; scope set")

    op = sp["operator"]
    rk = op.get("kind", "deploy")
    r = kctl(f"-n {ns} set env {rk}/{op['name']} "
             f"KUBERNETES_SERVICE_HOST={ip} KUBERNETES_SERVICE_PORT=443",
             timeout=90)
    if r is None or r.returncode != 0:
        raise SystemExit(f"[seed] stale_proxy: routing {rk}/{op['name']} "
                         "through the proxy failed")
    # set env bumps the pod template, so the old pod lingers ready for a while
    # -- a plain readiness wait would pass on it and the next step would race
    # the not-yet-rerouted operator. rollout status waits for the NEW one.
    r = sh(f"kubectl --kubeconfig {WORK_KC} -n {ns} rollout status "
           f"{rk}/{op['name']} --timeout=420s", timeout=460)
    if r is not None and r.stdout:
        log("rollout:", r.stdout.strip()[-200:])
    rargs, rwant = cfg["operator_ready"]
    wait_kubectl(rargs, want=rwant, timeout=600)
    log(f"operator routed through stale proxy ({ip})")




# >>> poll-neutralize-images (2026-09-23)
def _ref_split(ref):
    """`host/repo:tag` -> (name, tag)。tag 里不可能有 `/`,据此定位最后一个冒号。"""
    i = ref.rfind(":")
    if i > ref.rfind("/"):
        return ref[:i], ref[i:]
    return ref, ""


def _norm_ref(ref):
    """按 docker 的规则补全 registry host —— **别名必须规范化**。

    集群里跑起来的名字一律是规范化过的(`ctr images ls -q` 实测:`k8ssandra/
    cass-operator:v1.22.1` 存成 `docker.io/k8ssandra/cass-operator:v1.22.1`),
    而 `ctr images tag` 是**逐字**存的(containerd 对 OCI 注解
    `io.containerd.image.name` 不做规范化 —— 2026-09-13 another-case 实证:
    未规范化的 repack 名 CRI 查不到 ⇒ 永久 ErrImagePull)。所以别名两种拼法都挂:
    逐字那份给 `ctr` / step-0 看,规范化那份给 kubelet 看。
    """
    name, tag = _ref_split(ref)
    if "/" not in name:
        return "docker.io/library/" + name + tag
    head = name.split("/")[0]
    if "." in head or ":" in head or head == "localhost":
        return name + tag
    return "docker.io/" + name + tag


def _buggy_refs(text):
    import re as _re
    return set(_re.findall(
        r"[A-Za-z0-9._/-]+:[A-Za-z0-9._-]*buggy[A-Za-z0-9._-]*", text or ""))


def neutralize_image_names(cfg):
    """把种子镜像名里的 `buggy` 记号从**集群可见面**上抹掉。

    见文件顶部注释;返回 (cfg, [(old, new), ...]),后者并进 §4 的 rewrites。
    """
    import re as _re

    class _Agg:
        """sh() 的返回值形状(stdout/returncode),给下面的 _ctr 汇总用。"""

        def __init__(self, out, rc):
            self.stdout, self.returncode = out, rc

    def _ctr(arg, timeout=30):
        """在**每一个**节点的 containerd 上做同一件事;`images ls` 取并集。

        ★ O-28(2026-09-24):以前只打 CTR_ADDR(= k3s server 那一台)。k3s agent
        各有**私有** containerd(见 §2 "import operator images" 那段),所以只挂
        在 server 上的中立别名,worker 上**不存在** ⇒ pod spec 写
        `…:srcpinned-<case>` 而落到 worker 的 pod 报
          `failed to resolve reference "…:srcpinned-<case>": not found`
        ⇒ ErrImagePull ⇒ 种子里"等算子起来"那步超时 ⇒ `/tmp/seed-done` 永不出现
        ⇒ 整案白跑。实证:another-case `20260924-084050` 与 `20260924-133455__oracle`
        两场同死(同日 11:19 那场落在 server 上就没事)⇒ 三节点约 2/3 抛硬币。
        单 socket 的案:列表里只有 CTR_ADDR ⇒ 与旧行为逐字一致。
        """
        socks = cfg.get("ctr_sockets") or [CTR_ADDR]
        outs, rcs = [], []
        for sock in socks:
            r = sh("ctr --address " + sock + " " + arg, timeout=timeout)
            outs.append("" if r is None else (r.stdout or ""))
            rcs.append(None if r is None else r.returncode)
        allok = all(x == 0 for x in rcs)
        # `ls` 只要有**一台**回话就信(它在"看库存");tag/rm 要**每台都成**
        # (它们本来就是要把东西落到每一台上)。没成的都记一行,别静默。
        ok = any(x == 0 for x in rcs) if "images ls" in arg else allok
        if not allok:
            log("neutralize: ctr %r rc=%s (sockets=%d)"
                % (arg[:40], rcs, len(socks)))
        return _Agg("\n".join(x for x in outs if x.strip()), 0 if ok else 1)

    # cfg 的 image_rewrites 已经兜住的 ref 不碰:那些案子集群里跑的是发行版名,
    # 本来就干净;硬换成 store 里不存在的别名反而会把案子弄死。
    covered = set()
    for pair in (cfg.get("image_rewrites") or []):
        if isinstance(pair, (list, tuple)) and pair:
            covered.add(pair[0])

    olds = set()
    try:
        with open(f"{DATA}/{cfg['operator_bundle']}") as fh:
            olds |= _buggy_refs(fh.read())
    except Exception as exc:                      # noqa: BLE001 - 缺 bundle 不致命
        log("neutralize: cannot read operator bundle (%s)" % exc)

    KEEP = ("image_rewrites", "ns_rewrites")

    def _collect(obj, key=None):
        if key in KEEP:
            return
        if isinstance(obj, str):
            olds.update(_buggy_refs(obj))
        elif isinstance(obj, dict):
            for k, v in obj.items():
                _collect(v, k)
        elif isinstance(obj, list):
            for v in obj:
                _collect(v)

    _collect(cfg)
    olds -= covered
    if not olds:
        log("neutralize: no buggy image ref on the cluster-visible face")
        return cfg, []

    store = set()
    for ns in ("", "k8s.io"):
        pre = ("-n " + ns + " ") if ns else ""
        r = _ctr(pre + "images ls -q", timeout=60)
        if r is not None and r.returncode == 0:
            store |= {x.strip() for x in r.stdout.splitlines() if x.strip()}

    def _key(ref):
        name, tag = _ref_split(ref)
        tail = "/".join(name.split("/")[-2:])
        return _re.sub(r"(?i)buggy", "", tail) + tag

    by_key = {}
    for ref in store:
        if "buggy" in ref.lower():
            by_key.setdefault(_key(ref), ref)

    pairs = []
    for old in sorted(olds):
        new = _re.sub(r"(?i)buggy", "pinned", old)
        # ★ 2026-09-27:别名再去掉数字 —— <案号>=上游 issue 号,别名带着它就顺着
        #   pod spec / kubelet 事件 / 算子日志漏给 agent(与 dsh session_id 同源)。
        #   只动 tag 段(repo 里的数字合法,如 matt12313);普查 44 案 44 条
        #   srcbuggy ref、零同 repo 重复 ⇒ 去数字不撞名。
        _ci = new.rfind(":")
        if _ci > new.rfind("/"):
            _tag = _re.sub(r"[-_.]*\d+[-_.]*", "", new[_ci + 1:]) or "pinned"
            new = new[:_ci + 1] + _tag
        src = by_key.get(_key(old))
        if src is None:
            # 8 个"env 里没有 tar、算子镜像从 registry 拉"的案子走这里:名字照样
            # 改写(改完还能被 CRI 从 store 里按规范化名找到),只是没东西可 tag。
            log("neutralize: %s: no store image -> rewrite only" % old)
        else:
            tagged = False
            for dst in sorted({new, _norm_ref(new)}):
                for ns in ("", "k8s.io"):
                    pre = ("-n " + ns + " ") if ns else ""
                    r = _ctr(pre + "images tag " + src + " " + dst, timeout=60)
                    if r is not None and r.returncode == 0:
                        log("neutralize: tagged %s -> %s" % (src, dst))
                        tagged = True
                        break
            # 老名字还要**从 store 里摘掉**:只挂别名的话,CRI 报出来的
            # `status.containerStatuses[].image` 仍是镜像的**本名**(= buggy 那个)。
            # 2026-09-23 冒烟 env 实证:pod spec 写 `…:1.7.0-pinned434`,status 回
            # `docker.io/…:1.7.0-buggy434`;把老名字 rm 掉、pod 重建后才回别名。
            # 别名先挂好了才摘,摘的只是**名字**,digest 与内容都还在(step-0 的
            # "store 里按规范化名导出"照旧能命中别名)。
            # ★ O-28②(2026-09-24 用户拍板「不要留着老名字啊」):摘老名**与
            #   `tagged` 解耦**,不再"别名没全挂上就先别摘"。原理由是"留老名比
            #   '摘了老名、别名没挂上'安全",但那层保护**不存在**:§4 的 rewrites
            #   已经把 pod spec / bundle 文本里所有老名字换成别名(`pairs` 无条件
            #   返回),**没有任何东西再引用老名** ⇒ 留着只是让 `buggy` 继续出现在
            #   pod status / kubelet 事件 / 监控快照里 —— 纯泄漏、零保护。
            #   (某台 store 里本来就没有老名时,该台的 `images rm` 报 not found,
            #   只落一行日志、不影响别的台。)
            if not tagged:
                log("neutralize: %s: alias not on EVERY socket (rc 见上一行日志)"
                    % src)
            for stale in [s for s in store
                          if "buggy" in s.lower() and _key(s) == _key(old)]:
                    for ns in ("", "k8s.io"):
                        pre = ("-n " + ns + " ") if ns else ""
                        _ctr(pre + "images rm " + stale, timeout=60)
                    log("neutralize: dropped old store name %s" % stale)
        pairs.append((old, new))

    # cfg 里当命令/字段用的那几处也得跟着改:最典型的是 rook 两案的 fault_verify,
    # 它拿**在跑的**算子镜像名跟种子名对表 —— 不改就从此恒 MISS ⇒ 种子自检判死。
    def _sub(obj, key=None):
        if key in KEEP:
            return obj
        if isinstance(obj, str):
            for a, b in pairs:
                obj = obj.replace(a, b)
            return obj
        if isinstance(obj, dict):
            return {k: _sub(v, k) for k, v in obj.items()}
        if isinstance(obj, list):
            return [_sub(v) for v in obj]
        return obj

    log("neutralize: %d ref(s) hidden from the cluster face" % len(pairs))
    return _sub(cfg), pairs
# <<< poll-neutralize-images

def main():
    cfg = json.load(open(f"{DATA}/seed-config.json"))
    log("starting; case=%s k3s=%s" % (cfg.get("case_id", "?"), K3S_SERVER))

    # 0. kubeconfig from k3s
    deadline = time.time() + 240
    while time.time() < deadline:
        if os.path.exists(SRC_KC):
            txt = open(SRC_KC).read().replace(
                "127.0.0.1:6443", K3S_SERVER.replace("https://", ""))
            open(WORK_KC, "w").write(txt)
            os.makedirs(os.path.dirname(AGENT_KC), exist_ok=True)
            open(AGENT_KC, "w").write(txt)
            break
        time.sleep(3)
    else:
        raise SystemExit("[seed] kubeconfig not produced by k3s in time")

    # 1. k3s ready
    #
    # `want="Ready"` is a substring test, so it returns the moment the FIRST
    # node reports Ready -- correct for a single-node env (the only node there
    # is) and wrong for every multi-node one. Cases that depend on distinct
    # HOSTNAMES (a required pod anti-affinity spreads replicas one-per-node,
    # so "2 of 3 replicas Running, the third Pending forever" needs 3 real
    # nodes, not 3 Pending pods on one) therefore declare wait_nodes and are
    # held here until the whole cluster is up.
    wait_kubectl("get nodes", want="Ready", timeout=240)

    def ready_nodes():
        r = kctl("get nodes --no-headers", timeout=20)
        if r is None or r.returncode != 0:
            return []
        # a NotReady node prints one token "NotReady", so an exact token match
        # never confuses the two (the ROLES column is comma-joined, no spaces).
        return [ln for ln in r.stdout.splitlines()
                if "Ready" in ln.split()]

    want_nodes = cfg.get("wait_nodes")
    if want_nodes:
        deadline = time.time() + cfg.get("wait_nodes_timeout", 480)
        n = 0
        while time.time() < deadline:
            n = len(ready_nodes())
            if n >= want_nodes:
                break
            time.sleep(5)
        else:
            raise SystemExit(f"[seed] only {n}/{want_nodes} nodes Ready after "
                             f"{cfg.get('wait_nodes_timeout', 480)}s")
        log(f"cluster up: {n}/{want_nodes} nodes Ready")

    for sel, count in (cfg.get("node_labels") or {}).items():
        deadline = time.time() + cfg.get("node_labels_timeout", 300)
        k = 0
        while time.time() < deadline:
            r = kctl(f"get nodes -l {sel} --no-headers", timeout=20)
            k = len([l for l in (r.stdout or "").splitlines() if l.strip()]) \
                if r is not None and r.returncode == 0 else 0
            if k >= count:
                break
            time.sleep(5)
        else:
            raise SystemExit(f"[seed] want {count} node(s) labelled {sel}, "
                             f"found {k}")
        log(f"node label {sel} on {k} node(s)")

    # 2. import operator images
    #
    # An EXPLICIT timeout, not sh()'s 30s default: `ctr images import` unpacks
    # every layer into containerd's content store, and the first tars of a
    # cold env (fresh containerd, empty page cache, parallel lanes hammering
    # the same disk) run far slower than the later ones. Measured: a 643MB tar
    # takes 11s on a warm host but blew past 30s during a two-lane smoke fan --
    # another-case's SEED FAILED on `cassandra-mgmtapi-3_11_7-v0.1.13.tar`
    # (48s of work, 30s budget) and the whole 40-minute smoke was lost to it.
    # The 30s default exists for the cheap echo-style commands sh() also runs;
    # an import is not one of them.
    # EVERY node that can host a pod needs the tar in ITS OWN containerd: a k3s
    # agent runs a private containerd (same socket path, different store) and
    # has no mirror pointing at the server, so a pod scheduled onto a worker
    # pulls from the internet -- which works for a public image and fails hard
    # for a locally-built tag (`srcbuggy-*` exists nowhere) with
    # ImagePullBackOff 10 minutes into the seed. On a single-node env the
    # server's store is the only one there is, so `ctr_sockets` is absent and
    # the list below is exactly [CTR_ADDR] -- byte-identical behaviour.
    sockets = cfg.get("ctr_sockets") or [CTR_ADDR]
    if len(sockets) > 1:
        log(f"importing into {len(sockets)} containerd(s): {' '.join(sockets)}")
    for sock in sockets:
        for tar in sorted(os.listdir(IMAGES)):
            r = sh(f"ctr --address {sock} images import {IMAGES}/{tar}",
                   timeout=600)
            if r is None or r.returncode != 0:
                raise SystemExit(f"[seed] image import failed: {tar} -> {sock}")
    log("images imported")
# >>> poll-neutralize-images (2026-09-23)
    # 2b. 种子镜像名中立化(2026-09-23) —— 细则见 neutralize_image_names():
    #     `...:srcbuggy-<case>` 这个名字会顺着 pod spec / pod status 的
    #     `containerStatuses[].image` / kubelet 事件 / 算子日志告诉 agent"这是注入
    #     的故障"(普查:52 案材料带着它、35 案的最新快照里露过)。这里改名:挂中立
    #     别名 + 把**老名字从 store 里摘掉**(只挂别名不够,CRI 报的是镜像本名),
    #     §4 的 rewrites 再用返回的 pair 把 bundle 文本里的老名字换掉。
    cfg, _neutral_images = neutralize_image_names(cfg)
# <<< poll-neutralize-images

    # 2b. 核对每个 socket 里"工作负载真正要用的镜像"到齐了没有。
    #     为什么必须查:缺镜像时现场**没有一句话说明**——kubelet 只会
    #     ImagePullBackOff(而 env 里没有外网,docker.io 直接 invalid_token),
    #     而 seed 的 cr_sequence wait 只是在刷重复的 `get sts ... readyReplicas`,
    #     看着像"算子卡了",实际是镜像没到,白等 900s 才 SEED FAILED。
    #     pod 调度到 worker 时用的是 **worker 自己的 containerd**,所以每个
    #     socket 都要单独满足,不能只看 server 那份。
    #     两个命名空间都算命中(ctr 的默认命名空间跟 CRI 的 k8s.io 不一定是同一个),
    #     但把 k8s.io 的命中数单独打出来,方便一眼看出是不是"进错了 store"。
    required = list(cfg.get("images_required", []))
    for sock in sockets:
        seen, per_ns = set(), {}
        for ns in ("k8s.io", "default"):
            r = sh(f"ctr --address {sock} -n {ns} images ls -q", timeout=60)
            refs = set()
            if r is not None and r.returncode == 0:
                refs = {x.strip() for x in r.stdout.splitlines() if x.strip()}
            per_ns[ns] = len(refs)
            seen |= refs
        missing = [i for i in required
                   if i not in seen and f"docker.io/{i}" not in seen]
        log(f"image check {sock}: k8s.io={per_ns.get('k8s.io')} "
            f"default={per_ns.get('default')} missing={missing or 'none'}")
        if missing:
            raise SystemExit(f"[seed] required images missing in {sock}: {missing}")

    # 3. pre-manifests (cert-manager etc.)
    # [poll-split] healthy prefix for the poll driver: pre-phase config
    # surgery BEFORE any pre-manifest is applied -- faults hiding in
    # pre_manifests (another-case CA keystore, another-case fake Route CRD,
    # another-case block-rack1) sit in section 3, so a section-5 guard would
    # be too late for them. Skips poll_skip_pre manifests, keeps only the
    # healthy prefix (poll_pre_sequence when hand-authored, else the first
    # poll_healthy_steps steps) and defuses fault_verify -- a STRICT probe
    # MISSes on the healthy state and would abort the pre seed. Any other
    # phase (harbor run / gate-1 smoke) leaves this config untouched.
    if os.environ.get("SWEOPS_SEED_PHASE") == "pre":
        _skip = set(cfg.get("poll_skip_pre") or [])
        if _skip:
            cfg["pre_manifests"] = [m for m in (cfg.get("pre_manifests") or [])
                                    if m not in _skip]
        _pre = cfg.get("poll_pre_sequence")
        if _pre is None:
            _pre = (cfg.get("cr_sequence") or [])[:int(cfg.get("poll_healthy_steps", 0))]
        cfg["cr_sequence"] = _pre
        cfg["fault_verify"] = []
        log("SWEOPS_SEED_PHASE=pre: healthy prefix only (%d step(s), %d pre-manifest skipped)"
            % (len(_pre), len(_skip)))

    for m in cfg.get("pre_manifests", []):
        apply_manifest(f"{DATA}/{m}", m)
    # 3b. ensure StorageClasses the CR references exist (host clusters had
    #     them; k3s only ships local-path by default)
    for sc in cfg.get("ensure_sc", []):
        r = kctl(f"get sc {sc['name']}", timeout=15)
        if r is not None and r.returncode == 0:
            continue
        p = "/tmp/ensure-sc.yaml"
        open(p, "w").write(
            "apiVersion: storage.k8s.io/v1\nkind: StorageClass\n"
            f"metadata:\n  name: {sc['name']}\n"
            f"provisioner: {sc.get('provisioner', 'rancher.io/local-path')}\n"
            "volumeBindingMode: WaitForFirstConsumer\nreclaimPolicy: Delete\n")
        r = kctl(f"apply -f {p}", timeout=30)
        if r is None or r.returncode != 0:
            raise SystemExit(f"[seed] ensure_sc {sc['name']} failed")
    for args, want in cfg.get("pre_ready", []):
        wait_kubectl(args, want=want, timeout=cfg.get("pre_ready_timeout", 600))
    log("pre-reqs ready")

    # 4. operator bundle (ensure the operator namespace exists first — some
    #    bundles do not carry a Namespace resource)
    for ns in cfg.get("ensure_ns", []):
        r = kctl(f"create namespace {ns} --dry-run=client -o yaml", timeout=20)
        if r is None or r.returncode != 0:
            raise SystemExit(f"[seed] ensure_ns {ns} failed")
        p = "/tmp/ensure-ns.yaml"
        open(p, "w").write(r.stdout)
        r = kctl(f"apply -f {p}", timeout=30)
        if r is None or r.returncode != 0:
            raise SystemExit(f"[seed] ensure_ns {ns} apply failed")
    rewrites = (list(cfg.get("image_rewrites", [])) + list(cfg.get("ns_rewrites", [])) + list(_neutral_images))
    apply_manifest(f"{DATA}/{cfg['operator_bundle']}", "operator bundle",
                   rewrites=rewrites, apply_ns=cfg.get("apply_ns"),
                   no_ssa=cfg.get("no_ssa", False))
    rargs, rwant = cfg["operator_ready"]
    wait_kubectl(rargs, want=rwant, timeout=cfg.get("operator_ready_timeout", 1500))
    log("operator ready")

    # 4b. stale-view proxy (optional): route the operator through an in-cluster
    #     read-stale/write-real proxy BEFORE the CR exists, so the whole
    #     generate-0 lifecycle happens over the same path the fault needs.
    if cfg.get("stale_proxy"):
        setup_stale_proxy(cfg)

    # 5. CR sequence (fault injection)
    for step in cfg["cr_sequence"]:
        ns = step.get("ns")
        f = f"{DATA}/{step['file']}"
        r = kctl(f"{'-n ' + ns + ' ' if ns else ''}apply -f {f}", timeout=60)
        if r is None or r.returncode != 0:
            raise SystemExit(f"[seed] apply {step['file']} failed")
        for args, want in step.get("wait", []):
            wait_kubectl(f"{'-n ' + ns + ' ' if ns else ''}{args}",
                         want=want, timeout=step.get("timeout", 300))
        if step.get("settle"):
            log(f"settling {step['settle']}s after {step['file']}")
            time.sleep(step["settle"])

    def verify(key, when, strict):
        """Run one probe list; abort on a MISS when `strict`.

        Two lists exist because the two fault classes verify at different
        points in the seed, and putting either in the other's slot turns the
        probe into a lie:

          fault_verify        CR-inherent faults -- the fault is a property of
                              the CR/manifests, so it exists the moment the CR
                              sequence settles. Runs BEFORE the trigger.
          fault_verify_after  trigger-created faults -- the trigger (or
                              trigger_script) is what injects the fault, so
                              anything asserted here is guaranteed to MISS if
                              evaluated earlier. Runs AFTER trigger + settle.

        A probe written for the wrong slot is the same failure either way: it
        MISSes for a reason unrelated to the fault. Before `fault_verify` was
        strict that just logged; now it aborts the seed, which is the point --
        a green env whose fault was never reproduced is worse than a red one.
        """
        missed = []
        for args, want in cfg.get(key, []):
            r = kctl(args, timeout=30)
            ok = r is not None and r.returncode == 0 and want in r.stdout
            if r is not None and r.returncode != 0:
                # non-zero rc used to be reported as a bare empty MISS, which
                # hid the quoting blow-ups; surface stderr instead.
                detail = f"rc={r.returncode} {r.stderr.strip()[-200:]}"
            else:
                detail = (r.stdout.strip()[-200:] if r else "<none>")
            log(f"fault verify[{when}] {want!r}: {'OK' if ok else 'MISS'}: {detail}")
            if not ok:
                missed.append(want)
        if missed and strict:
            raise SystemExit(
                f"[seed] fault verify[{when}] MISSED {missed}: the env did not "
                "reach the fault state, so the oracle smoke would pass "
                "vacuously. Fix the probe, move it to the other verify slot if "
                "the fault is trigger-created, or set fault_verify_optional to "
                "accept a best-effort check.")

    # 6. fault verify, pre-trigger -- STRICT by default.
    #    `fault_verify_optional: true` opts a case back into log-only.
    verify("fault_verify", "pre-trigger",
           strict=not cfg.get("fault_verify_optional"))

    # 7. trigger + settle (either inline kubectl steps or a bundled script)
    # [poll-pre] healthy start for the poll driver: stop right
    # after the healthy workload is up; the poll driver replays the fault
    # injection later at the user-set moment (same trigger script, same kc).
    if os.environ.get("SWEOPS_SEED_PHASE") == "pre":
        with open("/tmp/seed-done", "w") as f:
            f.write("pre\n")
        log("SWEOPS_SEED_PHASE=pre: seeded healthy, fault steps skipped")
        return

    for targs in cfg.get("trigger", []):
        r = kctl(" ".join(targs), timeout=60)
        if r is None or r.returncode != 0:
            raise SystemExit(f"[seed] trigger failed: {' '.join(targs)}")
    if cfg.get("trigger_script"):
        r = sh(f"bash {DATA}/triggers/{cfg['trigger_script']} {AGENT_KC}",
               timeout=cfg.get("trigger_timeout", 1500))
        if r is not None and r.stdout:
            log("trigger stdout:", r.stdout.strip()[-800:])
        if r is None or r.returncode != 0:
            raise SystemExit(f"[seed] trigger script failed: {cfg['trigger_script']}")
    if cfg.get("settle_sec"):
        log(f"settling {cfg['settle_sec']}s")
        time.sleep(cfg["settle_sec"])

    # 7b. fault verify, post-trigger -- always strict, no opt-out. This is the
    #     only slot that can assert a fault the trigger itself injects; see the
    #     `verify` docstring above.
    verify("fault_verify_after", "post-trigger", strict=True)

    # 8. gate marker
    with open("/tmp/seed-done", "w") as f:
        f.write("done\n")
    log("SEED COMPLETE")


if __name__ == "__main__":
    try:
        main()
    except SystemExit as e:
        log("SEED FAILED:", e)
        time.sleep(3600)
    except Exception as e:  # noqa: BLE001
        log("SEED FAILED (exception):", repr(e))
        time.sleep(3600)
