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


def apply_manifest(path, label, rewrites=None, apply_ns=None, no_ssa=False):
    import re as _re
    blocks = [b for b in _re.split(r"^---\s*$", open(path).read(), flags=_re.M)
              if b.strip()]
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
    wait_kubectl("get nodes", want="Ready", timeout=240)

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
    for tar in sorted(os.listdir(IMAGES)):
        r = sh(f"ctr --address {CTR_ADDR} images import {IMAGES}/{tar}",
               timeout=600)
        if r is None or r.returncode != 0:
            raise SystemExit(f"[seed] image import failed: {tar}")
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
        r = sh(f"bash {DATA}/triggers/{cfg['trigger_script']} {AGENT_KC}", timeout=1500)
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
