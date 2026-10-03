#!/usr/bin/env bash
# ROOK-17198 -- bring a Ceph cluster up on loop devices, then apply the
# erasure-coded pool that the pinned operator can never mark Ready.
#
# Used as BOTH the N3 env's trigger_script and the host bridge's scene step
# (same calling convention on both: `bash <script> <kubeconfig>`), so it must
# run unchanged on
#   * the N3 env  -- k3s-in-compose, nodes `k3s` (untainted, schedulable) +
#                    `k3s-worker-N`, 3 nodes, no internet;
#   * the host bridge -- kind, nodes `<cluster>-control-plane` (TAINTED) +
#                    `<cluster>-worker[N]`, 3 workers, internet available.
# Hence: every topology fact is DISCOVERED here, never assumed. Nodes are
# read back from the API and the control plane is dropped by name/taint, so
# the same script works on both shapes without a single hard-coded node name.
#
# ---------------------------------------------------------------------------
# Why the environment needs three nodes (and this script cannot shrink to one)
# ---------------------------------------------------------------------------
# The fault object is a CephBlockPool with `failureDomain: host`,
# dataChunks=2/codingChunks=1 -- an EC pool whose CRUSH rule needs THREE
# distinct hosts. On a smaller cluster ceph cannot create the rule and the
# pool would fail for a reason that has nothing to do with #17198 (and, worse,
# the FIXED operator could not rescue it either, so the case would lose its
# discriminator). One OSD per node, three nodes, is the minimum that makes the
# pool legitimate -- which is exactly what the legacy collection used
# (seed_sieve_case.py:seed_rook_common, 3 workers).
#
# ---------------------------------------------------------------------------
# Why the loop device is provisioned from INSIDE the cluster
# ---------------------------------------------------------------------------
# Ceph needs a real block device; on a container cluster that means a loop
# device attached to a file. The legacy recipe did it from the host with
# `docker exec <node>`, but the N3 env's `main` container has no docker
# socket -- so the provisioning moves into a privileged pod per node, which
# needs no compose privileges beyond what the k3s nodes already carry
# (`privileged: true`): docker copies the host's /dev/loop* into every
# privileged container, pods inherit `hostPath: /dev`, and a pod with
# CAP_SYS_ADMIN can mknod + losetup exactly like the legacy `docker exec` did.
# Verified end to end on 2026-09-12 before this script was written.
#
# Two details inherited from the legacy recipe, both load-bearing:
#   * rook's OSD prepare IGNORES the CR's per-node `devices` list when it
#     enumerates (`configureCVDevices` provisions every loop it can see), and
#     loop devices are HOST-GLOBAL -- so every other loop device node must be
#     removed from this node's /dev or all three prepares claim the same set.
#   * ceph-volume refuses a device with no udev db entry, and a container node
#     runs no udevd, so `/run/udev/data/b7:<N>` is written by hand.
# The loop NUMBER is allocated by probing (losetup a candidate, keep it if it
# takes), never assumed: two rook clusters can run concurrently on one host
# (a harbor smoke env and a host bridge lane), and the kernel loop pool is
# shared between them -- so candidates must never be freed blindly. Ownership
# is made EXPLICIT rather than inferred: every backing file this script creates
# lives under `/loop/<cluster-tag>/`, and a candidate holding somebody else's
# attachment is skipped, never detached. The tag is the cluster's own
# kube-system namespace uid, so two concurrent lanes (and a restarted env) get
# distinct tags while all three nodes of ONE cluster share one.
# (A dangling-attachment test does NOT work here: the 57 loops leaked by the
# legacy host-side recipe lost their backing files with their kind nodes and
# still report a full 5G -- the loop holds the inode.)
#
# ---------------------------------------------------------------------------
# The fault
# ---------------------------------------------------------------------------
# `pool-ec.yaml` (inlined below, mirrored from runtime/build/rookop/pool-ec.yaml)
# is applied once the cluster is Ready.
#   buggy (pin 13ddabd99)  ReconcileCephBlockPool only reaches
#     updateStatus(ConditionReady) through configurePoolMirroring(), and
#     canConfigurePoolMirroring() returns false for EC pools (#17143
#     regression) -- so the pool is created and usable (the operator logs
#     "creating EC pool ec-pool succeeded" / "successfully initialized pool
#     for RBD use") but status.phase stays Progressing forever.
#   fixed (#17200, 47a3c123b5)  the Ready update is reached on the normal
#     path, so the same pool reports phase=Ready.
# A marker ConfigMap carries what was actually observed so the env's
# fault_verify_after can distinguish "the fault is present" from "the scene
# never got that far".
#
# Exit code is ALWAYS 0: this same file runs on both bridge legs, and a
# non-zero exit would abort the seed on whichever leg is behaving correctly
# (the same reason triggers/xtop-1155-scene.sh always exits 0). The verdict
# is carried by the marker and by the pool's own status.
#
# $1 = kubeconfig.
set -uo pipefail
KC="${1:?usage: rook-17198-scene.sh <kubeconfig>}"
NS=rook-ceph
POOL=ec-pool
CLUSTER=my-cluster
MARK=rook-17198-scene-state
LOOP_BASE="${LOOP_BASE:-70}"
# wide: an allocation is never freed (a torn-down cluster's loop keeps the
# number), so the span is what buys headroom across runs and concurrent lanes
LOOP_SPAN="${LOOP_SPAN:-200}"
LOOP_SIZE_GIB="${LOOP_SIZE_GIB:-5}"
BRINGUP_TIMEOUT="${BRINGUP_TIMEOUT:-900}"
POOL_WINDOW="${POOL_WINDOW:-120}"

k() { kubectl --kubeconfig "$KC" "$@"; }
NODES=()   # declared before bail(), which reports on it

# The scene has stages that can fail for reasons that have nothing to do with
# the bug (no third node, no free loop, ceph never converging). Each of them
# still has to leave a marker behind and return 0: the env's fault_verify_after
# is what turns a marker saying scene=<not ok> into a loud MISS, whereas
# aborting the seed here would leave the harness to time out on a container
# that never becomes healthy -- the same silence, an hour later.
mkdir -p /tmp
bail() {  # $1=scene value, rest = key=value pairs for the marker
  local scene="$1"; shift
  local args=(--from-literal=nodes="${#NODES[@]}" --from-literal=tag="$TAG"
              --from-literal=scene="$scene" --from-literal=fault=unknown)
  local kv
  for kv in "$@"; do args+=(--from-literal="$kv"); done
  echo "[17198] SCENE FAILED: $scene ($*)"
  k -n "$NS" create configmap "$MARK" "${args[@]}" \
    --dry-run=client -o yaml 2>/dev/null | k apply -f - >/dev/null 2>&1
  echo "=== rook-17198 scene done (scene=$scene) ==="
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
if [ "$SCENE_PHASE" = "auto" ] && \
   [ "$(k -n "$NS" get cephcluster "$CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)" = "Ready" ]; then
  SCENE_SKIP_BUILD=1
  NODES=(); LOOPS=(); TAG="prebuilt"; ceph_phase=Ready
  echo "[17198] cluster already built (cephcluster phase=Ready) -> skipping the build sections"
fi
if [ -z "$SCENE_SKIP_BUILD" ]; then
# ---------------------------------------------------------------------------
# 1. which nodes may carry an OSD
# ---------------------------------------------------------------------------
# kind's control plane is tainted; the N3 env's k3s server is NOT (which is why
# it is usable as a third host there). Name check covers old kind versions that
# rely on the `node-role.kubernetes.io/master` label instead of a taint.
mapfile -t NODES < <(k get nodes -o custom-columns='NAME:.metadata.name,TAINTS:.spec.taints[*].key' \
  --no-headers 2>/dev/null | awk '{n=$1; t=$2; if (t ~ /control-plane|master/) next; if (n ~ /control-plane/) next; print n}')
echo "[17198] OSD hosts: ${NODES[*]:-none}"

# Ownership tag for the backing files: unique per cluster, identical on every
# node of it, so a second lane's loops are recognised as foreign. kube-system's
# uid is minted fresh with the cluster -- two lanes can never collide, and a
# re-created env simply gets a new one (its predecessor's loops are leaked, not
# stolen). The fallback only has to be collision-free, not stable.
TAG=$(k get ns kube-system -o jsonpath='{.metadata.uid}' 2>/dev/null | cut -c1-8)
case "$TAG" in
  ''|*[!0-9a-fA-F]*) TAG="fallback$$$(date +%s)";;
esac
echo "[17198] loop backing tag: $TAG"

if [ "${#NODES[@]}" -lt 3 ]; then
  bail no-nodes loops=- \
    "why=need 3 schedulable non-control-plane nodes for a failureDomain=host EC pool, found ${#NODES[@]}"
fi

# ---------------------------------------------------------------------------
# 2. no CSI
# ---------------------------------------------------------------------------
# The oracle is the block pool's status, and CSI is orthogonal to it -- but the
# CSI operator would deploy 6 DaemonSet/Deployment images (2.3GB+) on every OSD
# host, several of which the N3 env has no internet to pull. Disabling both
# drivers keeps the env's image set to the operator + ceph + busybox and keeps
# the two bridge legs bit-identical (the script runs on both).
NO_CSI='{"data":{"ROOK_CSI_ENABLE_CEPHFS":"false","ROOK_CSI_ENABLE_RBD":"false"}}'
if k -n "$NS" get configmap rook-ceph-operator-config >/dev/null 2>&1; then
  k -n "$NS" patch configmap rook-ceph-operator-config --type merge -p "$NO_CSI" >/dev/null 2>&1 \
    && echo "[17198] CSI drivers disabled (pool status is the oracle; CSI is orthogonal)"
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
    echo "[17198] loop provisioning FAILED on $node:"
    k -n default logs "job/$job" --tail=20 2>&1 | sed 's/^/    /'
    bail no-loops "loops=${LOOPS[*]:-none}" "why=loop provisioning job failed on $node"
  fi
  out=$(k -n default logs "job/$job" 2>/dev/null | tr -d '\r')
  n=$(echo "$out" | sed -n 's/^LOOP=\([0-9]\+\)$/\1/p' | tail -1)
  if [ -z "$n" ]; then
    echo "[17198] no LOOP=<n> in the job log for $node:"
    echo "$out" | tail -5 | sed 's/^/    /'
    bail no-loops "loops=${LOOPS[*]:-none}" "why=no LOOP line in the provisioning job log for $node"
  fi
  LOOPS+=("$n")
  NODE_YAML="${NODE_YAML}    - name: ${node}
      devices:
      - name: loop${n}
"
  echo "[17198] $node -> loop${n}  ($(echo "$out" | tail -1))"
done

# ---------------------------------------------------------------------------
# 4. the Ceph cluster itself
# ---------------------------------------------------------------------------
cat <<YAML >/tmp/rook-17198-cephcluster.yaml
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
k apply -f /tmp/rook-17198-cephcluster.yaml >/dev/null 2>&1 \
  || echo "[17198] WARN: CephCluster apply returned non-zero"

ceph_phase=""
deadline=$(( $(date +%s) + BRINGUP_TIMEOUT ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  ceph_phase=$(k -n "$NS" get cephcluster "$CLUSTER" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ "$ceph_phase" = "Ready" ] && break
  sleep 15
done
echo "[17198] cephcluster phase=${ceph_phase:-<none>} (loops: ${LOOPS[*]})"
if [ "$ceph_phase" != "Ready" ]; then
  bail ceph-not-ready "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" "pool=missing" \
    "why=cephcluster never reached Ready within ${BRINGUP_TIMEOUT}s"
fi

fi   # ← [O-24] 关闭"建集群"区
# [O-24] build 相位到此为止:集群已建好、故障**还没**注入。写一个与 ok/unknown 都
# 不同的 scene=built —— 注入那一刻第 5 节才会把它覆盖成 ok;若注入那半没能跑到
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
  echo "=== rook-17198 scene built (pre phase; cluster ready, fault NOT injected) ==="
  exit 0
fi
# ---------------------------------------------------------------------------
# 5. the fault: an erasure-coded pool
# ---------------------------------------------------------------------------
# Mirrors runtime/build/rookop/pool-ec.yaml (the legacy collection's trigger).
k apply -f - >/dev/null 2>&1 <<'YAML'
apiVersion: ceph.rook.io/v1
kind: CephBlockPool
metadata:
  name: ec-pool
  namespace: rook-ceph
spec:
  failureDomain: host
  erasureCoded:
    dataChunks: 2
    codingChunks: 1
YAML

# Wait for the pool to acquire a status at all: "no phase yet" and "phase stuck
# at Progressing" are different scenes, and only the second one is the fault.
pool=""
deadline=$(( $(date +%s) + POOL_WINDOW ))
while [ "$(date +%s)" -lt "$deadline" ]; do
  pool=$(k -n "$NS" get cephblockpool "$POOL" -o jsonpath='{.status.phase}' 2>/dev/null || true)
  [ -n "$pool" ] && break
  sleep 10
done
if [ -z "$pool" ]; then
  bail pool-no-status "loops=${LOOPS[*]}" "ceph=${ceph_phase:-none}" "pool=missing" \
    "why=CephBlockPool/ec-pool acquired no status.phase within ${POOL_WINDOW}s"
fi
# Settle, then read the phase the leg is meant to be judged on. On the buggy
# env this is the fault itself (Progressing, forever). On the bridge's
# candidate leg the same reading is taken -- the pool simply has not finished
# reconciling yet -- and the bridge's own poll is what waits for Ready, so this
# value is a scene record here, not a verdict. What it DOES separate is the
# fault from "ceph refused the pool", which would park the phase at the same
# value for an unrelated reason and hand the RCA agent a fake signal.
sleep 20
pool=$(k -n "$NS" get cephblockpool "$POOL" -o jsonpath='{.status.phase}' 2>/dev/null || true)
# Did the operator actually create the pool in ceph? The ground truth is
# explicit that it does: "the pool is created and usable (Normal
# ReconcileSucceeded event) but status.phase stays Progressing".
created=$(k -n "$NS" logs deploy/rook-ceph-operator --tail=600 2>/dev/null \
  | grep -c "initializing pool for RBD use" || true)
echo "[17198] pool phase=${pool:-<none>} (operator 'initializing pool for RBD use' x${created:-0})"

fault=present
[ "$pool" = "Ready" ] && fault=absent

k -n "$NS" create configmap "$MARK" \
  --from-literal=nodes="${#NODES[@]}" \
  --from-literal=tag="$TAG" \
  --from-literal=scene=ok \
  --from-literal=loops="${LOOPS[*]}" \
  --from-literal=ceph="${ceph_phase:-none}" \
  --from-literal=pool="${pool:-none}" \
  --from-literal=pool_created="${created:-0}" \
  --from-literal=fault="$fault" --dry-run=client -o yaml \
  | k apply -f - >/dev/null 2>&1

echo "=== rook-17198 scene done (ceph=${ceph_phase:-none} pool=${pool:-none} fault=$fault) ==="
# Always 0 -- see the header. The marker carries the verdict.
exit 0
