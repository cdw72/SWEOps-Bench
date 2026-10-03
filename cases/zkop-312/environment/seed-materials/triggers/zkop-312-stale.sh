#!/usr/bin/env bash
# zkop-312 -- stale-view trigger (recreate pattern), N3 flavour.
#
# The bug (upstream #312 / fix PR #313) is the twin of k8spsmdb-430's, one
# layer lower: `getPVCList` builds its selector from
#     map[string]string{"app": instance.GetName()}
# with no UID term, so the delete path of a *stale* ZookeeperCluster -- one
# whose delete event the operator still holds -- matches the PVCs of a RE-
# CREATED cluster that happens to carry the same name. `cleanUpAllPVCs` then
# deletes them. #313 adds `"uid": string(instance.UID)` to that selector and
# the matching `uid` label to the volumeClaimTemplate, so the fixed operator
# only ever touches PVCs of the CR it is actually finalizing.
#
# The scene is 430's, ported: the frozen read comes from seed.py's in-cluster
# `stale_proxy` (already deployed and routing this operator by the time this
# script runs), and the recreate is made deterministic by PARKING the operator
# while the CR is put into the deleting state -- a finalizer cannot clear an
# object nobody is reconciling, so the capture is not a race.
#
#   1. gen0 (zookeeper-cluster) is healthy -- seed.py's cr_sequence waited.
#   2. PARK gen0's CR in the deleting state and freeze that view.
#   3. gen0 is torn down for real (clear the finalizer by hand, then delete the
#      sts and PVCs under the same `app` label the finalizer selects on).
#   4. re-apply the CR -> gen1 comes up with a NEW sts/PVC and a NEW uid.
#   5. /stale/on + restart: the relist now serves the SNAPSHOT (old CR,
#      deletionTimestamp, old uid, ZkFinalizer still present) while deletes
#      land for real. The buggy selector `app=zookeeper-cluster` matches
#      gen1's `data-zookeeper-cluster-0` and deletes it; the fixed one asks
#      for `app=<name>,uid=<gen0 uid>` and matches nothing.
#   6. the pod that mounts the deleted PVC never comes back -> the sts stops
#      being ready -- which is exactly the recorded discriminator
#      (`sts_ready zookeeper-cluster`: buggy 0/1, fixed 1/1).
#
# $1 = kubeconfig.
#
# Runs in BOTH environments. Only three things differ, and they are addresses:
#   STALE_PROXY_IP  k3s pins 10.43.0.100 (service CIDR 10.43.0.0/16); the host
#                   bridge's kind cluster pins 10.96.0.100 (10.96.0.0/12).
#   SCENE_DATA      where zkc-1.yaml is re-applied from: /seed-data in the N3
#                   env, the task's seed-materials dir on the bridge.
#   SCENE_EXPECT    `fault` (default) = this is a fault-reproduction run, so a
#                   gen1 PVC that survives means the scene did not reproduce
#                   and the script must fail. `none` = the host bridge, where
#                   the same script runs on BOTH legs and a surviving PVC is
#                   the CANDIDATE's correct behaviour; there the recovery
#                   predicate (object_present + min_hold_sec) owns the verdict
#                   and the script must not pre-empt it.
set -uo pipefail
KC="$1"
NS=default
PROXY="${STALE_PROXY_IP:-10.43.0.100}"
OP=zookeeper-operator
CR=zookeeper-cluster
CRD=zookeeperclusters
STS=zookeeper-cluster
PVC=data-zookeeper-cluster-0
DATA="${SCENE_DATA:-/seed-data}"
MARK=zkop-312-stale-state
SCENE_EXPECT="${SCENE_EXPECT:-fault}"
# The label set cleanUpAllPVCs's selector uses -- {"app": cr.Name}, i.e. keyed
# off the CR NAME. That is precisely why the buggy path hits gen1: gen1's PVCs
# carry the same name-based label (plus, on the fixed side only, `uid`).
LBL=app=zookeeper-cluster

kc() { kubectl --kubeconfig "$KC" "$@"; }
# The control API listens on the pod's loopback only (the ClusterIP is not
# routable from the seed container), so it is driven through kubectl exec --
# the proxy image is busybox, hence wget.
ctl() {
  kc -n "$NS" exec deploy/stale-proxy -- \
     wget -qO- --post-data='{}' "http://127.0.0.1:8080$1" 2>&1 | tr -d '\n'
}
fail() { echo "[312] FAIL: $*" >&2; kc -n "$NS" create configmap "$MARK" \
           --from-literal=stage="$*" --dry-run=client -o yaml | kc -n "$NS" apply -f - >/dev/null 2>&1
         exit 1; }

echo "[312] == gen0 state"
kc -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^1$' \
  || fail "gen0 ${STS} is not 1/1 before the scene starts"

# ---------------------------------------------------------------------------
# Park, do not race. /capture is a LIST of the scoped kind that REPLACES that
# kind's snapshot entry, so it has to land while the CR is still present AND
# already carrying its deletionTimestamp -- and the operator's finalizer clears
# the CR in well under a second, while one control-API call is a `kubectl exec`
# round trip. With the operator scaled to 0 nothing runs the finalizer, the CR
# keeps its deletionTimestamp indefinitely, and the capture is deterministic.
# ---------------------------------------------------------------------------
echo "[312] == park gen0's CR in the deleting state (operator down)"
kc -n "$NS" scale "deploy/$OP" --replicas=0 >/dev/null || fail "could not scale the operator down"
for _ in $(seq 1 90); do
  n=$(kc -n "$NS" get pods --no-headers 2>/dev/null | grep -c "^$OP-" || true)
  [ "$n" = "0" ] && break
  sleep 2
done
n=$(kc -n "$NS" get pods --no-headers 2>/dev/null | grep -c "^$OP-" || true)
[ "$n" = "0" ] || fail "the operator pod did not go away; the finalizer would still race the capture"

kc -n "$NS" delete "$CRD" "$CR" --wait=false >/dev/null 2>&1 || true
ts=""
for _ in $(seq 1 100); do
  ts=$(kc -n "$NS" get "$CRD" "$CR" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
  [ -n "$ts" ] && break
  sleep 0.5
done
[ -n "$ts" ] || fail "the CR never entered the deleting state"
olduid=$(kc -n "$NS" get "$CRD" "$CR" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
echo "[312] parked: deletionTimestamp=$ts uid=$olduid"

echo "[312] == freeze the parked CR"
ctl /capture >/dev/null
d=$(ctl /dump)
# capture MERGES on error -- a failed capture leaves the previous entry in
# place -- so a matching /dump alone would not prove the capture worked; but a
# matching /dump right after a capture that had the object in hand does.
case "$d" in
  *"$NS/$CR rv="*)
    echo "[312] snapshot frozen: $NS/$CR deletionTimestamp=$ts uid=$olduid" ;;
  *)
    fail "capture did not store the deleting CR: $(printf '%s' "$d" | head -c 300)" ;;
esac

echo "[312] == tear gen0 down for real"
# Reproduce the operator's own finalize path by hand, because the operator is
# parked: clear the finalizer so the object goes away, then delete the sts and
# PVCs under the same label set cleanUpAllPVCs uses. gen1 below therefore
# starts from an empty slate with a fresh uid -- the entire point of the scene.
kc -n "$NS" patch "$CRD" "$CR" --type=json \
  -p='[{"op":"replace","path":"/metadata/finalizers","value":[]}]' >/dev/null \
  || fail "could not clear the parked CR's finalizers"
for _ in $(seq 1 60); do
  kc -n "$NS" get "$CRD" "$CR" >/dev/null 2>&1 || break
  sleep 1
done
kc -n "$NS" get "$CRD" "$CR" >/dev/null 2>&1 \
  && fail "the parked CR survived clearing its finalizers"
kc -n "$NS" delete sts -l "$LBL" --ignore-not-found >/dev/null 2>&1 || true
kc -n "$NS" delete pvc -l "$LBL" --ignore-not-found >/dev/null 2>&1 || true
echo "[312] gen0 torn down (CR, sts, PVCs all gone)"

echo "[312] == bring the operator back and recreate the CR; wait for gen1"
kc -n "$NS" scale "deploy/$OP" --replicas=1 >/dev/null
kc -n "$NS" rollout status "deploy/$OP" --timeout=600s >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  r=$(kc -n "$NS" get deploy "$OP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "$r" = "1" ] && break
  sleep 5
done
kc -n "$NS" apply -f "$DATA/zkc-1.yaml" >/dev/null || fail "re-apply of the CR failed"
newuid=$(kc -n "$NS" get "$CRD" "$CR" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
gen1=0
for _ in $(seq 1 450); do
  n=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "$n" = "1" ]; then gen1=1; break; fi
  sleep 2
done
[ "$gen1" = 1 ] || fail "gen1 ${STS} never reached 1/1"
kc -n "$NS" get pvc "$PVC" >/dev/null 2>&1 \
  || fail "gen1 ${PVC} is missing before the stale view is even engaged"
echo "[312] gen1 up: uid=$newuid (old was $olduid), ${PVC} present"

echo "[312] == stale ON + operator restart"
ctl /stale/on >/dev/null
kc -n "$NS" rollout restart "deploy/$OP" >/dev/null
kc -n "$NS" rollout status "deploy/$OP" --timeout=600s >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  r=$(kc -n "$NS" get deploy "$OP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "$r" = "1" ] && break
  sleep 5
done

# Two observation windows: the stale finalize fires on the first reconcile
# after the restart, but the operator has a retry loop and the PVC's own
# kubernetes.io/pvc-protection finalizer can hold it in Terminating while a
# pod still mounts it -- so give it a second window before concluding.
sleep 60
mid=$(kc -n "$NS" get pvc "$PVC" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
sleep 60

# Three states, and only one of them is "the fault did not happen": the PVC is
# there and untouched. `terminating` means the buggy delete landed but the
# protection finalizer has not released it yet -- the fault DID happen, and it
# is the state a bare `kubectl get` would otherwise read as healthy.
state=present
if ! kc -n "$NS" get pvc "$PVC" >/dev/null 2>&1; then
  state=gone
elif [ -n "$(kc -n "$NS" get pvc "$PVC" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]; then
  state=terminating
fi
echo "[312] gen1 ${PVC}: $state (mid-check: ${mid:-<none>})"
echo "[312] --- operator delete-path lines ---"
kc -n "$NS" logs "deploy/$OP" --tail=400 2>/dev/null \
  | grep -iE 'Deleting PVC|prepareForDeletion|stale|finaliz' | tail -5 || true

# --- strand the workload ---------------------------------------------------
# The buggy finalize lands ONLY as a PVC carrying a deletionTimestamp, and on a
# single-node k3s that is all it lands: the pod mounting the claim keeps
# running (pvc-protection will not release a claim still in use), so the sts
# still reads 1/1 and the recorded discriminator (`sts_ready` 0/1 -> 1/1) can
# never see the fault. The recorded multi-node kind scene shows what has to
# happen instead -- the controller kills the pod whose claim is being deleted
# and cannot bring it back:
#   FailedCreate ... create Pod zookeeper-cluster-0 ... failed error:
#       pvc data-zookeeper-cluster-0 is being deleted
#   Killing pod/zookeeper-cluster-0
#   FailedScheduling ... persistentvolumeclaim "data-zookeeper-cluster-0" not found
# leaving sts 0/1 / pod Pending. Force that recycle deterministically, and
# require the sts to actually leave 1/1: a scene that fails to strand must be
# caught HERE, not surface later as a silent VACUOUS recovery read.
if [ "$state" != "present" ]; then
  kc -n "$NS" delete pod "${STS}-0" --ignore-not-found --wait=false >/dev/null 2>&1 || true
  stranded=0
  for _ in $(seq 1 120); do
    r=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
    if [ "$r" != "1" ]; then stranded=1; break; fi
    sleep 2
  done
  r=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
  echo "[312] post-recycle ${STS}: readyReplicas=${r:-<none>} stranded=$stranded"
  [ "$stranded" = 1 ] \
    || fail "recycling ${STS}-0 did not strand the workload (sts still reads ${r:-1}); the recorded discriminator cannot read the fault"
fi

# The marker is what seed.py's post-trigger slot asserts on: `kubectl get` on a
# missing object exits non-zero, so absence itself is not expressible as a
# probe there, and "gone or terminating" is not a substring test either. So the
# trigger records the OBSERVATION (`pvc=`) plus a single-valued summary of it
# (`fault=present` for either non-present state), and the seed asserts the
# summary. gen1=up is the positive control: the world is otherwise healthy.
if [ "$state" = "present" ]; then fault=absent; else fault=present; fi
kc -n "$NS" create configmap "$MARK" \
  --from-literal=pvc="$state" --from-literal=fault="$fault" \
  --from-literal=gen1=up --dry-run=client -o yaml \
  | kc -n "$NS" apply -f - >/dev/null

if [ "$state" = "present" ]; then
  if [ "$SCENE_EXPECT" = "none" ]; then
    # host bridge, candidate leg: the PVC surviving IS the fixed behaviour. The
    # recovery predicate (object_present + min_hold_sec) judges it; exiting
    # non-zero here would abort the seed before it ever got to poll.
    echo "[312] gen1 ${PVC} untouched -- expected on the candidate leg; leaving the verdict to recovery"
  else
    fail "the stale finalize path did not touch gen1 ${PVC}"
  fi
fi
echo "=== zkop-312 stale scene done (${PVC} ${state}) ==="
exit 0
