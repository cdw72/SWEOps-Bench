#!/usr/bin/env bash
# ROOK-17372 -- bring a Ceph cluster up on loop devices, create a CephFilesystem
# with activeStandby:false, and inject the ONE precondition the fault needs
# (standby_count_wanted=1) so the pinned operator's failure to zero it becomes
# visible as ceph's MDS_INSUFFICIENT_STANDBY warning.
#
# Used as BOTH the N3 env's trigger_script and the host bridge's scene step
# (same calling convention on both: `bash <script> <kubeconfig>`), so it must
# run unchanged on
#   * the N3 env  -- k3s-in-compose, nodes `k3s` (untainted, schedulable) +
#                    `k3s-worker-N`, 3 nodes, no internet;
#   * the host bridge -- kind, nodes `<cluster>-control-plane` (TAINTED) +
#                    `<cluster>-worker[N]`, 3 workers, internet available.
# Hence every topology fact is DISCOVERED here, never assumed: nodes are read
# back from the API and the control plane is dropped by name/taint.
#
# ---------------------------------------------------------------------------
# Why three nodes, and why the loop device comes from inside the cluster
# ---------------------------------------------------------------------------
# Same two requirements as triggers/rook-17198-scene.sh, and the same answers:
#   * mon.count=3 + one OSD per host. Ceph needs a real block device, the N3
#     `main` container has no docker socket, so provisioning moves into a
#     privileged pod per node (docker copies the host's /dev/loop* into every
#     privileged container; the k3s nodes are already `privileged: true`).
#   * rook's OSD prepare ignores the CR's per-node `devices` list when it
#     enumerates, and loop devices are HOST-GLOBAL -- so every OTHER loop device
#     node must be removed from this node's /dev, and ceph-volume needs the udev
#     db entry this container cluster has no udevd to write.
# Read the 17198 header for the full reasoning (loop-number probing, the
# per-cluster ownership tag, why a dangling test does not work). It is not
# repeated here because the code below is the same code.
#
# ---------------------------------------------------------------------------
# The fault, and what has to be injected for it to exist
# ---------------------------------------------------------------------------
#   buggy (pin v1.19.4)  AllowStandbyReplay() runs `fs set <fs>
#     allow_standby_replay <bool>` and NOTHING ELSE. With activeStandby:false
#     rook deploys no standby MDS, while ceph's `standby_count_wanted` stays at
#     whatever it was -> ceph reports MDS_INSUFFICIENT_STANDBY ("insufficient
#     standby MDS daemons available") and the CephCluster sits in HEALTH_WARN.
#   fixed (#17373, translated in runtime/build/rookop/fix-17372-pin.patch)
#     AllowStandbyReplay takes the wanted count and forces it to 0 whenever
#     standby replay is being switched off, so the warning clears.
#
# TWO things this scene therefore has to do that the 17198 scene does not:
#
#  1. INJECT `standby_count_wanted 1`. On ceph 19.2.4 (the image this case is
#     pinned to, and the only one whose ceph-volume survives loop devices -- see
#     the v20 note in seed_sieve_case.py:seed_rook_17372) a freshly created fs
#     defaults the wanted count to 0, so the buggy operator's omission would be
#     INVISIBLE: no warning on either leg, no discriminator. The legacy
#     collection injected the same value on both variants; the leg is separated
#     by what the operator does with it afterwards, not by who set it.
#
#  2. FORCE one CephFilesystem reconcile. #17373 lives inside createFilesystem,
#     which only runs on a real reconcile -- and rook's owned-object watcher
#     filters Deployment CREATE/UPDATE out of the CephFilesystem queue, so an
#     mds rollout restart does NOT re-enter it (fixed would then never zero the
#     count and would fail the gate for the wrong reason). The reliable trigger
#     is a CR SPEC change: patching `preservePoolsOnDelete` bumps
#     metadata.generation, WatchControllerPredicate admits it, createFilesystem
#     re-runs -> AllowStandbyReplay -> fixed zeroes the count, buggy does not.
#     The field is only read on the delete path and is patched back to its
#     original value at the end, so the CR ends the scene as it started.
#
# A marker ConfigMap carries what was actually observed, so the env's
# fault_verify_after can tell "the fault is present" from "the scene never got
# that far". It deliberately records BOTH the operator-visible quantity
# (`wanted`, read out of the toolbox) and ceph's derived warning (`mds`), and it
# decides `fault` from the FORMER: `wanted` is what the operator under test
# actually did, it settles within seconds, whereas the warning is a mgr
# side-effect that lags by a status-refresh cycle. `fault=present` therefore
# means "ceph still expects a standby MDS while rook deploys none" -- the fault
# condition itself -- not "a message happened to be in a status map".
#
# Exit code is ALWAYS 0: the same file runs on both bridge legs, and a non-zero
# exit would abort the seed on whichever leg is behaving correctly. The verdict
# is carried by the marker and by the cluster's own status.
#
# $1 = kubeconfig.
set -uo pipefail
KC="${1:?usage: rook-17372-scene.sh <kubeconfig>}"
NS=rook-ceph
CLUSTER=my-cluster
FS=myfs
MARK=rook-17372-scene-state
LOOP_BASE="${LOOP_BASE:-70}"
# wide: an allocation is never freed (a torn-down cluster's loop keeps the
# number), so the span is what buys headroom across runs and concurrent lanes
LOOP_SPAN="${LOOP_SPAN:-200}"
LOOP_SIZE_GIB="${LOOP_SIZE_GIB:-5}"
BRINGUP_TIMEOUT="${BRINGUP_TIMEOUT:-900}"
MDS_TIMEOUT="${MDS_TIMEOUT:-300}"
# How long to let the operator's answer to the generation bump settle. The
# fixed side issues `fs set wanted 0` as part of the reconcile, so this is a
# generous ceiling, not a latency budget; the buggy side simply never changes.
WANT_WINDOW="${WANT_WINDOW:-180}"
# ceph's health detail is refreshed by the operator on its cluster-status tick,
# so the warning can outlive the wanted change by a refresh cycle.
DETAIL_WINDOW="${DETAIL_WINDOW:-240}"

k() { kubectl --kubeconfig "$KC" "$@"; }
NODES=()   # declared before bail(), which reports on it

# The scene has stages that can fail for reasons that have nothing to do with
# the bug (no third node, no free loop, ceph never converging, the toolbox or
# the fs never coming up). Each of them still has to leave a marker behind and
# return 0: the env's fault_verify_after turns a marker saying scene=<not ok>
# into a loud MISS, whereas aborting the seed here would leave the harness to
# time out on a container that never becomes healthy -- the same silence, an
# hour later. bail() always writes fault=unknown, never present.
mkdir -p /tmp
bail() {  # $1=scene value, rest = key=value pairs for the marker
  local scene="$1"; shift
  local args=(--from-literal=nodes="${#NODES[@]}" --from-literal=tag="$TAG"
              --from-literal=scene="$scene" --from-literal=fault=unknown)
  local kv
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  echo "[17372] SCENE FAILED: $scene ($*)"
  k -n "$NS" create configmap "$MARK" "${args[@]}" \
    --dry-run=client -o yaml 2>/dev/null | k apply -f - >/dev/null 2>&1
  echo "=== rook-17372 scene done (scene=$scene) ==="
  exit 0
}

# ---------------------------------------------------------------------------
# [O-24] 相位路由:这一遍是"建集群"还是"只注入"
# ---------------------------------------------------------------------------
# 这个脚本以前是"建集群 + 注入"一整条,由驱动在**注入那一刻**跑一次。后果:术前
# (k=0)这台机器上**根本没有 CephCluster** —— 而健康闸的第一问 `workloads_settled`
# 只取材 sts/deploy/ds(看不见 CR)⇒ 闸在集群还是 Creating 时就放行,k=0 快照天生
# 带警告(台账 O-24;`rook-17372 20260924-105948`:wait=0.9s、k=0 快照 0 个
# cephcluster,而 k=1 快照已有集群 + MDS 警告)。
# 现在:seed 的 pre 相位带 `SWEOPS_SCENE_PHASE=build` 先把本脚本跑到"建完";注入那
# 一刻不带该变量,靠**探测集群已建成**决定从哪往下走。探测只看"建完才有"的
# cephcluster `.status.phase=Ready`,避免误判。探测不成立(桥 / oracle 冒烟 /
# pre 建集群失败)⇒ 原样整条跑一遍,与旧行为零差。
SCENE_PHASE="${SWEOPS_SCENE_PHASE:-auto}"
SCENE_SKIP_BUILD=""
fs_wanted() {  # -> the wanted count, or "" when ceph could not be asked
  k -n "$NS" exec deploy/rook-ceph-tools -- ceph fs get "$FS" -f json 2>/dev/null \
    | python3 -c 'import json,sys
try: print(json.load(sys.stdin).get("mdsmap",{}).get("standby_count_wanted",""))
except Exception: print("")' 2>/dev/null
}
if [ "$SCENE_PHASE" = "auto" ] && \
   [ "$(k -n "$NS" get cephcluster "$CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Ready" ]; then
  SCENE_SKIP_BUILD=1
  NODES=(); LOOPS=(); TAG="prebuilt"; ceph_phase=Ready
  echo "[17372] cluster already built (cephcluster phase=Ready) -> skipping the build sections"
fi
if [ -z "$SCENE_SKIP_BUILD" ]; then
# ---------------------------------------------------------------------------
# 0. keep this case's images reachable in EVERY node's containerd
# ---------------------------------------------------------------------------
# The seed imports images/*.tar into all three stores ONCE, at env build. That
# is not enough for THIS scene: the bring-up below is where the env's disk
# churns hardest (three loop files, a 1.4GB ceph image unpacked into every
# store, cold page cache, two other lanes on the same host), and until the
# CephCluster is applied this case's locally-built operator tag is referenced
# by exactly ONE node -- the one running the operator pod. k3s's kubelet image
# GC measures the HOST filesystem (>=85% usage) and deletes what no container
# references, so the tags this case needs can be gone from the other two stores
# by the time rook asks for them. Same mechanism the zkop-312 pilot recorded on
# 2026-09-14; the difference here is that no scale-to-zero is needed -- the
# image is simply unreferenced until the CephCluster exists.
#
# 2026-09-22 实证 (run 20260922-005853; host 79~97G free = 80~84% used, three
# lanes in flight): rook's mon CANARY pods run the OPERATOR image; at 17:52
# worker-1 reported "already present on machine" while the k3s server and
# k3s-worker-2 both said `docker.io/rook/ceph:srcbuggy-17372: not found` (that
# tag exists nowhere upstream) -> ErrImagePull -> no mon ever formed ->
# CephCluster stuck at phase Progressing -> the scene bailed ceph-not-ready
# after BRINGUP_TIMEOUT. The CEPH image was gone from those stores too (rook
# re-pulled it: 6m46s, which by itself ate ~18 of the 900s bring-up budget
# through the version-check timeout). Net effect: THE INJECTED FAULT NEVER
# EXISTED, and the round was scored as if the agent had cried wolf.
#
# So: check all three stores and re-import whatever is missing -- once now,
# then every 60s for the rest of the scene. The tars live in this container
# (/images), the sockets are mounted here, and `ctr` is on PATH: the same three
# facts the seed's own import step relies on, with the same command shape (and
# therefore the same namespace, the one kubelet reads). kubelet retries a
# failed pull with backoff (<=5 min), so repairing within a minute is enough
# for the pod that needs it. If the case's image set ever changes, this table
# changes with it (it is the same list the Dockerfile copies into /images).
#
# Guarded on purpose: the host bridge leg (kind, no /images, no ctr) skips the
# whole block and behaves exactly as it did before.
IMG_GUARD=( "/images/busybox-1.36.tar:busybox:1.36"
            "/images/ceph-v19.2.4.tar:quay.io/ceph/ceph:v19.2.4"
            "/images/rook-ceph-srcpinned-17372.tar:docker.io/rook/ceph:srcpinned-17372" )
img_guard() {
  command -v ctr >/dev/null 2>&1 || return 0
  [ -d /images ] || return 0
  local sock pair tar ref have
  for sock in /run/k3s/containerd/containerd.sock \
              /run/k3s/ctr-w1/containerd.sock \
              /run/k3s/ctr-w2/containerd.sock; do
    [ -S "$sock" ] || continue
    have=$(ctr --address "$sock" images ls -q 2>/dev/null) || have=""
    for pair in "${IMG_GUARD[@]}"; do
      tar="${pair%%:*}"; ref="${pair#*:}"
      case "$have" in *"$ref"*) continue;; esac
      echo "[17372] image guard: $ref absent from $sock -> importing $tar"
      ctr --address "$sock" images import "$tar" >/dev/null 2>&1 \
        || echo "[17372] image guard: import $tar -> $sock FAILED (non-fatal)"
    done
    # 2026-09-23:集群里跑的是**中立别名**(seed.py 的 neutralize_image_names 把
    # `srcbuggy-` 换成了 `srcpinned-`,免得"这是注入的故障"顺着镜像名泄漏给
    # agent),而 tar 里带的还是老名字 ⇒ 补一次 tag。表里第三项也按别名判在不在。
    ctr --address "$sock" images tag docker.io/rook/ceph:srcbuggy-17372 \
        docker.io/rook/ceph:srcpinned-17372 >/dev/null 2>&1 || true
    # 老名字还得从 store 里摘掉:只挂别名不够 —— CRI 报的 pod status
    # `containerStatuses[].image` 用的是镜像**本名**(2026-09-23 冒烟实证)。
    ctr --address "$sock" images rm docker.io/rook/ceph:srcbuggy-17372 \
        >/dev/null 2>&1 || true
  done
}
# Three positive tests, not a negation: the host bridge leg runs this file on a
# box that HAS /usr/bin/ctr but has neither /images nor this socket, so the
# socket check is what makes "we are inside the N3 env's main container" exact.
if command -v ctr >/dev/null 2>&1 && [ -d /images ] \
   && [ -S /run/k3s/containerd/containerd.sock ]; then
  img_guard
  # stdout/stderr to a file, never to the scene's own stdout: an in-flight
  # `sleep` would otherwise keep the exec's pipe open after the script exits and
  # stall the driver's inject() call for up to a minute.
  ( while :; do sleep 60; img_guard; done ) >/tmp/17372-image-guard.log 2>&1 &
  IMG_GUARD_PID=$!
  trap '[ -n "${IMG_GUARD_PID:-}" ] && kill "$IMG_GUARD_PID" 2>/dev/null; true' EXIT
  echo "[17372] image guard up (pid $IMG_GUARD_PID)"
fi

# ---------------------------------------------------------------------------
# 1. which nodes may carry an OSD
# ---------------------------------------------------------------------------
# kind's control plane is tainted; the N3 env's k3s server is NOT (which is why
# it is usable as a third host there). The name check covers old kind versions
# that rely on the `node-role.kubernetes.io/master` label instead of a taint.
mapfile -t NODES < <(k get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key' \
  --no-headers 2>/dev/null | awk '{n=$1; t=$2; if (t ~ /control-plane|master/) next; if (n ~ /control-plane/) next; print n}')
echo "[17372] OSD hosts: ${NODES[*]:-none}"

# Ownership tag for the backing files: unique per cluster, identical on every
# node of it, so a second lane's loops are recognised as foreign. kube-system's
# uid is minted fresh with the cluster -- two lanes can never collide, and a
# re-created env simply gets a new one (its predecessor's loops are leaked, not
# stolen). The fallback only has to be collision-free, not stable.
TAG=$(k get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null | cut -c1-8)
case "$TAG" in
  ''|*[!0-9a-fA-F]*) TAG="fallback$$$(date +%s)";;
esac
echo "[17372] loop backing tag: $TAG"

if [ "${#NODES[@]}" -lt 3 ]; then
  bail no-nodes loops=- \
    "why=need 3 schedulable non-control-plane nodes (mon.count=3 + one OSD per host), found ${#NODES[@]}"
fi

# ---------------------------------------------------------------------------
# 2. no CSI
# ---------------------------------------------------------------------------
# The fault is the MDS standby count, and the CSI drivers are orthogonal to it
# (the mds pod mounts a config/secret/hostPath set, NOT a CSI volume -- verified
# against the captured pod spec). They would deploy six more images (cephcsi +
# the sig-storage sidecars, 2.3GB+) on every host, several of which the N3 env
# has no internet to pull. Disabling both drivers keeps the env's image set at
# operator + ceph + busybox and keeps the two bridge legs bit-identical.
NO_CSI='{"data":{"ROOK_CSI_ENABLE_CEPHFS":"false","ROOK_CSI_ENABLE_RBD":"false"}}'
if k -n "$NS" get configmap rook-ceph-operator-config >/dev/null 2>&1; then
  k -n "$NS" patch configmap rook-ceph-operator-config --type merge -p "$NO_CSI" >/dev/null 2>&1 \
    && echo "[17372] CSI drivers disabled (the mds standby count is the oracle; CSI is orthogonal)"
fi

# ---------------------------------------------------------------------------
# 3. one loop device per OSD host
# ---------------------------------------------------------------------------
# Sequential, not parallel: each pod takes the first candidate that attaches,
# and running them one at a time is what guarantees three DISTINCT numbers
# without any shared state to coordinate on. --wait=true + a completed Job is
# the readiness signal (no log scraping), and the number comes back from the
# job's own stdout.
gen_job() {  # $1=index $2=node
  sed -e "s/__IDX__/$1/" -e "s/__NODE__/$2/" -e "s/__BASE__/$LOOP_BASE/" \
      -e "s/__SPAN__/$LOOP_SPAN/" -e "s/__GIB__/$LOOP_SIZE_GIB/" \
      -e "s/__TAG__/$TAG/" <<'YAML'
apiVersion: batch/v1
kind: Job
metadata:
  name: rook-loop-prov-__IDX__
  namespace: default
spec:
  backoffLimit: 0
  ttlSecondsAfterFinished: 3600
  template:
    spec:
      nodeName: __NODE__
      restartPolicy: Never
      containers:
      - name: p
        image: busybox:1.36
        imagePullPolicy: IfNotPresent
        securityContext:
          privileged: true
        command:
        - sh
        - -c
        - |
          BASE=__BASE__; SPAN=__SPAN__; TAG=__TAG__
          DIR=/loop/$TAG
          IMG_PRE="$DIR/osd"
          mkdir -p "$DIR"
          L=""
          for off in $(seq 0 $((SPAN - 1))); do
            N=$((BASE + off))
            IMG="$IMG_PRE$N.img"
            mknod -m 666 /dev/loop-control c 10 237 2>/dev/null || true
            mknod -m 666 /dev/loop$N b 7 $N 2>/dev/null || true
            # A live attachment belongs to somebody. Ours only if its backing
            # file sits under OUR tag dir (losetup prints it as "(<path>)" and
            # that string is exactly what we passed in); anything else is a
            # neighbour lane's and must be skipped, never detached.
            if cur=$(losetup /dev/loop$N 2>/dev/null); then
              case "$cur" in
                *"($IMG)"*) losetup -d /dev/loop$N 2>/dev/null || true ;;
                *) continue ;;
              esac
            fi
            rm -f "$IMG"
            truncate -s __GIB__G "$IMG" 2>/dev/null || continue
            if losetup /dev/loop$N "$IMG" 2>/dev/null; then L=$N; break; fi
            rm -f "$IMG"
          done
          if [ -z "$L" ]; then echo "LOOP ALLOC FAILED (base=$BASE span=$SPAN)"; exit 1; fi
          # rook's OSD prepare provisions every loop device it can SEE, so all
          # of this node's other loop nodes must go (they belong to other
          # clusters; only this node's /dev is touched)
          for dev in /dev/loop[0-9]*; do
            n=${dev#/dev/loop}
            case "$n" in *[!0-9]*) continue;; esac
            [ "$n" = "$L" ] || rm -f "$dev"
          done
          # no udevd in a container node -> hand-write the udev db entry that
          # ceph-volume inventory requires
          mkdir -p /host-run/udev/data
          printf 'E:ID_SERIAL=loop-7:%s\n' "$L" > /host-run/udev/data/b7:$L
          echo "LOOP=$L"
        volumeMounts:
        - {name: dev, mountPath: /dev}
        - {name: loop, mountPath: /loop}
        - {name: runudev, mountPath: /host-run/udev}
      volumes:
      - {name: dev, hostPath: {path: /dev}}
      - {name: loop, hostPath: {path: /var/lib/rook-loop, type: DirectoryOrCreate}}
      - {name: runudev, hostPath: {path: /run/udev, type: DirectoryOrCreate}}
YAML
}

LOOPS=()
NODE_YAML=""
idx=0
for node in "${NODES[@]}"; do
  idx=$((idx + 1))
  job=rook-loop-prov-$idx
  k -n default delete job "$job" --ignore-not-found --wait=true >/dev/null 2>&1
  gen_job "$idx" "$node" | k apply -f - >/dev/null 2>&1
  if ! k -n default wait --for=condition=complete "job/$job" --timeout=300s >/dev/null 2>&1; then
    echo "[17372] loop provisioning FAILED on $node:"
    k -n default logs "job/$job" --tail=20 2>&1 | sed 's/^/    /'
    bail no-loops "loops=${LOOPS[*]:-none}" "why=loop provisioning job failed on $node"
  fi
  out=$(k -n default logs "job/$job" 2>/dev/null | tr -d '\r')
  n=$(echo "$out" | sed -n 's/^LOOP=\([0-9]\+\)$/\1/p' | tail -1)
  if [ -z "$n" ]; then
    echo "[17372] no LOOP=<n> in the job log for $node:"
    echo "$out" | tail -5 | sed 's/^/    /'
    bail no-loops "loops=${LOOPS[*]:-none}" "why=no LOOP line in the provisioning job log for $node"
  fi
  LOOPS+=("$n")
  NODE_YAML="${NODE_YAML}    - name: ${node}
      devices:
      - name: loop${n}
"
  echo "[17372] $node -> loop${n}  ($(echo "$out" | tail -1))"
done

# ---------------------------------------------------------------------------
# 4. the Ceph cluster itself
# ---------------------------------------------------------------------------
cat <<YAML >/tmp/rook-17372-cephcluster.yaml
apiVersion: ceph.rook.io/v1
kind: CephCluster
metadata:
  name: $CLUSTER
  namespace: $NS
spec:
  dataDirHostPath: /var/lib/rook
  cephVersion:
    image: quay.io/ceph/ceph:v19.2.4
    allowUnsupported: false
  mon:
    count: 3
  mgr:
    count: 1
    modules:
      - name: rook
        enabled: true
  dashboard:
    enabled: false
  monitoring:
    enabled: false
  # loop devices are auto-assigned deviceClass=ssd, which puts the OSD
  # deployments in a permanent "needs update" state; ok-to-stop then blocks on
  # a fresh cluster (PGs not clean) and the orchestration never completes ->
  # the cluster never reaches Ready. Standard rook CI knob.
  skipUpgradeChecks: true
  storage:
    useAllNodes: false
    useAllDevices: false
    nodes:
$NODE_YAML
YAML
k apply -f /tmp/rook-17372-cephcluster.yaml >/dev/null 2>&1 \
  || echo "[17372] WARN: CephCluster apply returned non-zero"

ceph_phase=""
deadline=$(( $(date +%s) + BRINGUP_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  ceph_phase=$(k -n "$NS" get cephcluster "$CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$ceph_phase" = "Ready" ] && break
  sleep 15
done
echo "[17372] cephcluster phase=${ceph_phase:-<none>} (loops: ${LOOPS[*]})"
if [ "$ceph_phase" != "Ready" ]; then
  bail ceph-not-ready "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" \
    "why=cephcluster never reached Ready within ${BRINGUP_TIMEOUT}s"
fi

# ---------------------------------------------------------------------------
# 5. the filesystem whose standby count the operator fails to zero
# ---------------------------------------------------------------------------
# Mirrors runtime/build/rookop/cephfs.yaml (the legacy collection's trigger).
# activeStandby:false is the whole point: rook then deploys no standby MDS, so a
# non-zero standby_count_wanted can never be satisfied.
k apply -f - >/dev/null 2>&1 <<'YAML'
apiVersion: ceph.rook.io/v1
kind: CephFilesystem
metadata:
  name: myfs
  namespace: rook-ceph
spec:
  metadataPool:
    replicated:
      size: 1
  dataPools:
    - name: data0
      replicated:
        size: 1
  preservePoolsOnDelete: true
  metadataServer:
    activeCount: 1
    activeStandby: false
YAML

# The operator creates pools -> fs -> mds deployment asynchronously, and
# `rollout status` fails fast on a deployment that does not exist yet, so wait
# for it to appear first.
mds_ready=""
deadline=$(( $(date +%s) + MDS_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if k -n "$NS" get deploy rook-ceph-mds-$FS-a >/dev/null 2>&1; then
    if k -n "$NS" rollout status deploy/rook-ceph-mds-$FS-a --timeout=30s >/dev/null 2>&1; then
      mds_ready=yes; break
    fi
  fi
  sleep 5
done
if [ -z "$mds_ready" ]; then
  bail mds-not-ready "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" \
    "why=deploy/rook-ceph-mds-$FS-a never became ready within ${MDS_TIMEOUT}s"
fi
echo "[17372] mds deployment rook-ceph-mds-$FS-a ready"

# ---------------------------------------------------------------------------
# 6. the toolbox -- the only place `ceph` can be run from
# ---------------------------------------------------------------------------
# Inlined from the captured runs/rook-17372/toolbox.yaml (the upstream example
# with the image pinned to this case's ceph build). It is the handle the scene
# uses to read and write the fsmap, exactly as the legacy seed did.
k apply -f - >/dev/null 2>&1 <<'YAML'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: rook-ceph-tools
  namespace: rook-ceph
  labels:
    app: rook-ceph-tools
spec:
  replicas: 1
  selector:
    matchLabels:
      app: rook-ceph-tools
  template:
    metadata:
      labels:
        app: rook-ceph-tools
    spec:
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: rook-ceph-default
      containers:
        - name: rook-ceph-tools
          image: quay.io/ceph/ceph:v19.2.4
          command:
            - /bin/bash
            - -c
            - |
              CEPH_CONFIG="/etc/ceph/ceph.conf"
              MON_CONFIG="/etc/rook/mon-endpoints"
              KEYRING_FILE="/etc/ceph/keyring"
              CONFIG_OVERRIDE="/etc/rook-config-override/config"

              write_endpoints() {
                endpoints=$(cat ${MON_CONFIG})
                mon_endpoints=$(echo "${endpoints}"| sed 's/[a-z0-9_-]\+=//g')
                DATE=$(date)
                echo "$DATE writing mon endpoints to ${CEPH_CONFIG}: ${endpoints}"
                cat <<EOF > ${CEPH_CONFIG}
              [global]
              mon_host = ${mon_endpoints}

              [client.admin]
              keyring = ${KEYRING_FILE}
              EOF
                if [ -f "${CONFIG_OVERRIDE}" ] && [ -s "${CONFIG_OVERRIDE}" ]; then
                  echo "$DATE merging config override from ${CONFIG_OVERRIDE}"
                  echo "" >> ${CEPH_CONFIG}
                  cat ${CONFIG_OVERRIDE} >> ${CEPH_CONFIG}
                fi
              }

              watch_endpoints() {
                real_path=$(realpath ${MON_CONFIG})
                initial_time=$(stat -c %Z "${real_path}")
                while true; do
                  real_path=$(realpath ${MON_CONFIG})
                  latest_time=$(stat -c %Z "${real_path}")
                  if [[ "${latest_time}" != "${initial_time}" ]]; then
                    write_endpoints
                    initial_time=${latest_time}
                  fi
                  sleep 10
                done
              }

              ceph_secret=${ROOK_CEPH_SECRET}
              if [[ "$ceph_secret" == "" ]]; then
                ceph_secret=$(cat /var/lib/rook-ceph-mon/secret.keyring)
              fi
              cat <<EOF > ${KEYRING_FILE}
              [${ROOK_CEPH_USERNAME}]
              key = ${ceph_secret}
              EOF
              write_endpoints
              watch_endpoints
          imagePullPolicy: IfNotPresent
          tty: true
          securityContext:
            runAsNonRoot: true
            runAsUser: 2016
            runAsGroup: 2016
            capabilities:
              drop: ["ALL"]
          env:
            - name: ROOK_CEPH_USERNAME
              valueFrom:
                secretKeyRef:
                  name: rook-ceph-mon
                  key: ceph-username
          volumeMounts:
            - mountPath: /etc/ceph
              name: ceph-config
            - name: mon-endpoint-volume
              mountPath: /etc/rook
            - name: ceph-admin-secret
              mountPath: /var/lib/rook-ceph-mon
              readOnly: true
            - name: rook-config-override
              mountPath: /etc/rook-config-override
              readOnly: true
      volumes:
        - name: ceph-admin-secret
          secret:
            secretName: rook-ceph-mon
            optional: false
            items:
              - key: ceph-secret
                path: secret.keyring
        - name: mon-endpoint-volume
          configMap:
            name: rook-ceph-mon-endpoints
            items:
              - key: data
                path: mon-endpoints
        - name: rook-config-override
          configMap:
            name: rook-config-override
            optional: true
        - name: ceph-config
          emptyDir: {}
      tolerations:
        - key: "node.kubernetes.io/unreachable"
          operator: "Exists"
          effect: "NoExecute"
          tolerationSeconds: 5
YAML

if ! k -n "$NS" rollout status deploy/rook-ceph-tools --timeout=300s >/dev/null 2>&1; then
  bail toolbox-not-ready "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" \
    "why=deploy/rook-ceph-tools never became ready (it is the only ceph CLI handle)"
fi
echo "[17372] toolbox ready"

# ceph-side helpers. Every read goes through the toolbox; there is no local
# ceph client in the scene's own container.

# The filesystem shows up in `ceph fs ls` asynchronously -- the mds deployment
# can be Ready while ceph's fsmap has not registered it yet, and `fs set` on a
# fs ceph does not know about fails.
fs_seen=""
deadline=$(( $(date +%s) + MDS_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  if k -n "$NS" exec deploy/rook-ceph-tools -- ceph fs ls 2>/dev/null | grep -q "$FS"; then
    fs_seen=yes; break
  fi
  sleep 10
done
if [ -z "$fs_seen" ]; then
  bail fs-unknown "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" \
    "why=ceph fs ls never listed $FS within ${MDS_TIMEOUT}s"
fi

fi   # ← [O-24] 关闭"建集群"区
# [O-24] build 相位到此为止:集群已建好、故障**还没**注入。写一个与 ok/unknown 都
# 不同的 scene=built —— 注入那一刻第 7 节才会把它覆盖成 ok;若注入那半没能跑到
# 收尾,`fault_verify_after` 读到的就是 built ⇒ 驱动按"造景没成"记账(O-23),
# 而不是把半成品当"故障已注入"。
if [ "$SCENE_PHASE" = "build" ]; then
  k -n "$NS" create configmap "$MARK" \
    --from-literal=nodes="${#NODES[@]}" \
    --from-literal=tag="${TAG:-prebuilt}" \
    --from-literal=scene=built \
    --from-literal=ceph="${ceph_phase:-none}" \
    --from-literal=fault=unknown --dry-run=client -o yaml \
    | k apply -f - >/dev/null 2>&1
  echo "=== rook-17372 scene built (pre phase; cluster ready, fault NOT injected) ==="
  exit 0
fi
# ---------------------------------------------------------------------------
# 7. inject the precondition: wanted > 0
# ---------------------------------------------------------------------------
# On ceph 19.2.4 a new filesystem defaults standby_count_wanted to 0, so the
# bug's omission is invisible until something asks for a standby. Inject on
# BOTH legs (the legacy collection did the same): the legs are separated by what
# the operator does with the value afterwards, not by who wrote it.
wanted_injected=""
for _ in $(seq 1 30); do
  if k -n "$NS" exec deploy/rook-ceph-tools -- ceph fs set "$FS" standby_count_wanted 1 >/dev/null 2>&1; then
    if [ "$(fs_wanted)" = "1" ]; then wanted_injected=1; break; fi
  fi
  sleep 10
done
if [ "$wanted_injected" != "1" ]; then
  bail wanted-inject-failed "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" \
    "wanted=$(fs_wanted)" \
    "why=could not set standby_count_wanted=1; without it the pinned operator's omission is invisible on BOTH legs, so the scene would be vacuous"
fi
echo "[17372] injected standby_count_wanted=1"

# ---------------------------------------------------------------------------
# 8. force one CephFilesystem reconcile (this is the trigger)
# ---------------------------------------------------------------------------
# See the header: #17373 only runs inside createFilesystem, and rook's
# owned-object watcher filters Deployment events out of the CephFilesystem work
# queue, so an mds rollout restart does NOT re-enter it. A CR spec change does.
gen_before=$(k -n "$NS" get cephfilesystem "$FS" -o jsonpath='{.metadata.generation}' 2>/dev/null)
if ! k -n "$NS" patch cephfilesystem "$FS" --type merge \
     -p '{"spec":{"preservePoolsOnDelete":false}}' >/dev/null 2>&1; then
  bail gen-bump-failed "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" \
    "wanted=$(fs_wanted)" "why=CR spec patch (generation bump) was rejected"
fi
gen_after="$gen_before"
deadline=$(( $(date +%s) + 120 ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  gen_after=$(k -n "$NS" get cephfilesystem "$FS" -o jsonpath='{.metadata.generation}' 2>/dev/null)
  [ -n "$gen_after" ] && [ "$gen_after" != "$gen_before" ] && break
  sleep 5
done
if [ -z "$gen_after" ] || [ "$gen_after" = "$gen_before" ]; then
  bail gen-bump-failed "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" \
    "wanted=$(fs_wanted)" \
    "why=metadata.generation stayed at ${gen_before:-none}; createFilesystem was never re-entered, so neither leg was actually tested"
fi
echo "[17372] CR spec patched -> CephFilesystem reconcile fired (gen ${gen_before}->${gen_after})"

# ---------------------------------------------------------------------------
# 9. read the answer
# ---------------------------------------------------------------------------
# The fixed operator issues `fs set <fs> standby_count_wanted 0` as part of
# that reconcile; the pinned one never touches the value. Poll until it lands
# (or until the window closes on the leg where it never will).
wanted="$(fs_wanted)"
deadline=$(( $(date +%s) + WANT_WINDOW ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  w="$(fs_wanted)"
  [ -n "$w" ] && wanted="$w"
  [ "$w" = "0" ] && break
  sleep 10
done
echo "[17372] standby_count_wanted=${wanted:-<none>} (was 1 after injection)"
# An unreadable arbiter is NOT "the fault is present": the whole case rests on
# this number, so a scene that cannot read it has to say so loudly rather than
# leave a marker that reads like a repro.
if [ -z "$wanted" ]; then
  bail wanted-unknown "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" "wanted=none" \
    "why=could not read standby_count_wanted back from ceph after the reconcile"
fi

# The fault condition itself: ceph still expects a standby MDS while rook
# deploys none. Read from the operator-visible quantity, which settles in
# seconds -- the derived warning below is recorded for the record and for the
# bridge's own poll, but the marker does not wait on it.
fault=present
[ "$wanted" = "0" ] && fault=absent

# ceph's own verdict, through the CephCluster status the operator refreshes.
# buggy: MDS_INSUFFICIENT_STANDBY must appear; fixed: it must disappear.
mds=""
if [ "$fault" = "present" ]; then target=present; else target=absent; fi
deadline=$(( $(date +%s) + DETAIL_WINDOW ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  details=$(k -n "$NS" get cephcluster "$CLUSTER" -o jsonpath='{.status.ceph.details}' 2>/dev/null || true)
  case "$details" in
    *MDS_INSUFFICIENT_STANDBY*) mds=present ;;
    *) mds=absent ;;
  esac
  [ "$mds" = "$target" ] && break
  sleep 15
done
health=$(k -n "$NS" get cephcluster "$CLUSTER" -o jsonpath='{.status.ceph.health}' 2>/dev/null || true)
echo "[17372] ceph health=${health:-<none>} MDS_INSUFFICIENT_STANDBY=${mds:-<none>} (target $target)"

# Put the CR back the way the scene found it. preservePoolsOnDelete is only
# read on the delete path, and the extra reconcile this costs is idempotent on
# the fixed leg and a no-op on the buggy one -- the wanted value does not move.
k -n "$NS" patch cephfilesystem "$FS" --type merge \
  -p '{"spec":{"preservePoolsOnDelete":true}}' >/dev/null 2>&1 \
  || echo "[17372] WARN: preservePoolsOnDelete restore patch failed (does not affect the verdict)"

k -n "$NS" create configmap "$MARK" \
  --from-literal=nodes="${#NODES[@]}" \
  --from-literal=tag="$TAG" \
  --from-literal=scene=ok \
  --from-literal=loops="${LOOPS[*]}" \
  --from-literal=ceph="${ceph_phase:-none}" \
  --from-literal=fs="$FS" \
  --from-literal=wanted_injected="$wanted_injected" \
  --from-literal=wanted="${wanted:-none}" \
  --from-literal=mds="${mds:-none}" \
  --from-literal=health="${health:-none}" \
  --from-literal=fault="$fault" --dry-run=client -o yaml \
  | k apply -f - >/dev/null 2>&1

echo "=== rook-17372 scene done (ceph=${ceph_phase:-none} wanted=${wanted:-none} mds=${mds:-none} fault=$fault) ==="
# Always 0 -- see the header. The marker carries the verdict.
exit 0
