#!/usr/bin/env bash
# k8spsmdb-430 -- stale-view trigger (recreate pattern), N3 flavour.
#
# The bug needs the operator to hold a FROZEN view of one CR while its writes
# land for real; the env reaches that state with an in-cluster read-stale
# proxy (seed.py `stale_proxy`, already deployed and routing this operator by
# the time this script runs). Ported from stale_inject.run_recreate, ns207
# collection:
#
#   1. gen0 (mongodb-cluster) is healthy -- seed.py's cr_sequence waited.
#   2. PARK gen0's CR in the deleting state and freeze that view (below).
#   3. gen0 is torn down for real -- exactly what the operator's own
#      `delete-psmdb-pvc` finalizer does -- and the CR disappears.
#   4. re-apply the CR -> gen1 comes up with NEW sts/PVCs and a NEW uid.
#   5. /stale/on + restart the operator: its relist now serves the SNAPSHOT
#      (old CR, deletionTimestamp, old uid) while deletes still hit the real
#      cluster. The buggy finalize path deletes sts/PVCs BY LABEL
#      (clusterLabels keys off cr.Name, not the uid), so it destroys gen1's
#      statefulset -- which no longer belongs to that CR.
#   6. the fixed operator checks ownership (metav1.IsControlledBy) and leaves
#      gen1 alone.
#
# $1 = kubeconfig.
set -uo pipefail
KC="$1"
NS=default
PROXY=10.43.0.100
OP=percona-server-mongodb-operator
CR=mongodb-cluster
CRD=perconaservermongodbs
STS=mongodb-cluster-rs0
DATA=/seed-data
MARK=k8spsmdb-430-stale-state
# the label set the finalizer's deleteAllStatefulsets/deleteAllPVC use --
# clusterLabels(cr), i.e. keyed off the CR NAME. That is precisely why the
# buggy path hits gen1: gen1's objects carry the same name.
LBL=app.kubernetes.io/instance=mongodb-cluster

kc() { kubectl --kubeconfig "$KC" "$@"; }
# The control API listens on the pod's loopback only (the ClusterIP is not
# routable from the seed container), so it is driven through kubectl exec --
# the proxy image is busybox, hence wget.
ctl() {
  kc -n "$NS" exec deploy/stale-proxy -- \
     wget -qO- --post-data='{}' "http://127.0.0.1:8080$1" 2>&1 | tr -d '\n'
}
fail() { echo "[430] FAIL: $*" >&2; kc -n "$NS" create configmap "$MARK" \
           --from-literal=stage="$*" --dry-run=client -o yaml | kc -n "$NS" apply -f - >/dev/null 2>&1
         exit 1; }

echo "[430] == gen0 state"
kc -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null | grep -q '^3$' \
  || fail "gen0 ${STS} is not 3/3 before the scene starts"

# ---------------------------------------------------------------------------
# The capture below is the one step the scene cannot do as a race.
#
# /capture is a LIST of the scoped kind that REPLACES that kind's snapshot
# entry, so it has to land while the CR is still present AND already carrying
# its deletionTimestamp -- the timestamp is the whole reason the operator walks
# the finalize path at all, and a snapshot of the pre-delete CR would just be
# reconciled as a healthy cluster. But the operator's finalizer clears the CR
# in well under a second, while one control-API call is a `kubectl exec` round
# trip (~1s): the LIST lands after the object is already gone. Measured on the
# first smoke of this case -- one capture attempt, `0 objects`, ~4s elapsed.
#
# So do not race it: PARK the object in the deleting state. With the operator
# scaled to 0 nothing is left to run its finalizer, so the CR keeps its
# deletionTimestamp indefinitely and the capture is deterministic. The snapshot
# it stores is exactly what a mid-deletion CR looks like to the operator:
# deletionTimestamp set, `delete-psmdb-pvc` still present, old uid.
# ---------------------------------------------------------------------------
echo "[430] == park gen0's CR in the deleting state (operator down)"
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
echo "[430] parked: deletionTimestamp=$ts uid=$olduid"

echo "[430] == freeze the parked CR"
ctl /capture >/dev/null
d=$(ctl /dump)
# capture MERGES on error -- a failed capture leaves the previous entry in
# place -- so a matching /dump alone would not prove the capture worked; but a
# matching /dump right after a capture that had the object in hand does.
case "$d" in
  *"$NS/$CR rv="*)
    echo "[430] snapshot frozen: $NS/$CR deletionTimestamp=$ts uid=$olduid" ;;
  *)
    fail "capture did not store the deleting CR: $(printf '%s' "$d" | head -c 300)" ;;
esac

echo "[430] == tear gen0 down for real"
# Reproduce the operator's `delete-psmdb-pvc` finalizer by hand, because the
# operator is parked: clear the finalizer so the object goes away, then delete
# the statefulsets and PVCs under the same label set the finalizer uses. gen1
# below therefore starts from an empty slate with a fresh uid -- which is the
# entire point of the scene.
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
echo "[430] gen0 torn down (CR, sts, PVCs all gone)"

echo "[430] == bring the operator back and recreate the CR; wait for gen1"
kc -n "$NS" scale "deploy/$OP" --replicas=1 >/dev/null
kc -n "$NS" rollout status "deploy/$OP" --timeout=600s >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  r=$(kc -n "$NS" get deploy "$OP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "$r" = "1" ] && break
  sleep 5
done
kc -n "$NS" apply -f "$DATA/cr-shard.yaml" >/dev/null || fail "re-apply of the CR failed"
newuid=$(kc -n "$NS" get "$CRD" "$CR" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
gen1=0
for _ in $(seq 1 450); do
  n=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "$n" = "3" ]; then gen1=1; break; fi
  sleep 2
done
[ "$gen1" = 1 ] || fail "gen1 ${STS} never reached 3/3"
echo "[430] gen1 up: uid=$newuid (old was $olduid)"

echo "[430] == stale ON + operator restart"
ctl /stale/on >/dev/null
kc -n "$NS" rollout restart "deploy/$OP" >/dev/null
kc -n "$NS" rollout status "deploy/$OP" --timeout=600s >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  r=$(kc -n "$NS" get deploy "$OP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "$r" = "1" ] && break
  sleep 5
done

# two observation windows: the delete shows up on the first reconcile after
# the restart, but the operator has a retry loop, so give it a second one
# before concluding anything.
sleep 60
mid=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null || true)
sleep 60

state=present
if ! kc -n "$NS" get sts "$STS" >/dev/null 2>&1; then
  state=gone
elif [ -n "$(kc -n "$NS" get sts "$STS" -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)" ]; then
  state=terminating
fi
echo "[430] gen1 ${STS}: $state (mid-check: ${mid:-<none>})"
echo "[430] --- operator delete-path lines ---"
kc -n "$NS" logs "deploy/$OP" --tail=400 2>/dev/null \
  | grep -iE 'deleting|prepareForDeletion|delete.*statefulset|stale' | tail -5 || true

# The marker is what seed.py's post-trigger slot asserts on: `kubectl get` on
# a missing object exits non-zero, so absence itself is not expressible as a
# probe there, and "gone or terminating" is not a substring test either. So
# the trigger records the OBSERVATION (`sts=`) plus a single-valued summary of
# it (`fault=present` for either non-present state), and the seed asserts the
# summary. gen1=up is the positive control: the world is otherwise healthy.
if [ "$state" = "present" ]; then fault=absent; else fault=present; fi
kc -n "$NS" create configmap "$MARK" \
  --from-literal=sts="$state" --from-literal=fault="$fault" \
  --from-literal=gen1=up --dry-run=client -o yaml \
  | kc -n "$NS" apply -f - >/dev/null

if [ "$state" = "present" ]; then
  fail "the stale finalize path did not touch gen1 ${STS}"
fi
echo "=== k8spsmdb-430 stale scene done (${STS} ${state}) ==="
exit 0
