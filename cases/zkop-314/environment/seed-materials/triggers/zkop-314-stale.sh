#!/usr/bin/env bash
# zkop-314 -- stale-view trigger (scale-up pattern), N3 flavour.
#
# The bug (upstream #314 / fix PR #359) is the operator trusting a STALE
# ZookeeperCluster when it writes the StatefulSet. The pin this case was
# recorded on (cda03d2f, Mar 2021) reconciles the sts straight from whatever CR
# it currently holds -- there is no resource-version comparison at all
# (`grep -c owner-rv` on that tree: 0). PR #359 introduces compareResourceVersion
# and makes reconcileStatefulSet refuse when `cr.ResourceVersion` is SMALLER
# than the `owner-rv` label the operator stamped on the sts, so a stale read can
# no longer drive a scale-down.
#
# The scene is the issue's own story -- "scaled down, then scaled up, then a
# stale read scales it back down":
#
#   1. gen0 is a ONE replica cluster (zkc-2.yaml), healthy.
#   2. FREEZE the read of that one-replica CR. This is the whole difficulty: a
#      frozen read HAS to be what the operator consults, or the second write
#      below is just a normal reconcile and both variants look the same. seed.py
#      already put the in-cluster `stale_proxy` in front of this operator, so
#      /capture is a local call.
#   3. scale the CR UP for real (patch replicas -> 2). This write goes straight
#      through the proxy to the apiserver; the sts follows to 2/2 and gets a
#      fresh `owner-rv` on the fixed side.
#   4. /stale/on + restart the operator: from here on the operator reads the
#      FROZEN one-replica CR while its writes land for real.
#      * buggy  -- builds the sts from replicas=1, sees a size change, updates
#                  the ZK cluster size and scales the sts down: pod
#                  zookeeper-cluster-1 is deleted. That is the fault.
#      * fixed  -- compareResourceVersion(cr RV_old, sts owner-rv RV_new) = -1
#                  -> returns the "Staleness" error before touching anything,
#                  and the sts stays at 2/2.
#   which is exactly the recorded discriminator (`sts_ready zookeeper-cluster`:
#   buggy 1/1, fixed 2/2).
#
# $1 = kubeconfig.
#
# Runs in BOTH environments. Only three things differ, and they are addresses:
#   STALE_PROXY_IP  k3s pins 10.43.0.100 (service CIDR 10.43.0.0/16); the host
#                   bridge's kind cluster pins 10.96.0.100 (10.96.0.0/12).
#   SCENE_DATA      where zkc-2.yaml is re-read from (only used for a sanity
#                   check here -- the scale-up is a patch, not a re-apply).
#   SCENE_EXPECT    `fault` (default) = this is a fault-reproduction run, so an
#                   intact 2/2 after the flip means the scene did not reproduce
#                   and the script must fail. `none` = the host bridge, where
#                   the same script runs on BOTH legs and an intact sts is the
#                   CANDIDATE's correct behaviour; there the recovery predicate
#                   (object_present + min_hold_sec) owns the verdict and the
#                   script must not pre-empt it.
set -uo pipefail
KC="$1"
NS=default
PROXY="${STALE_PROXY_IP:-10.43.0.100}"
OP=zookeeper-operator
CR=zookeeper-cluster
CRD=zookeeperclusters
STS=zookeeper-cluster
POD1=zookeeper-cluster-1
DATA="${SCENE_DATA:-/seed-data}"
MARK=zkop-314-stale-state
SCENE_EXPECT="${SCENE_EXPECT:-fault}"

kc() { kubectl --kubeconfig "$KC" "$@"; }
# The control API listens on the pod's loopback only (the ClusterIP is not
# routable from the seed container), so it is driven through kubectl exec --
# the proxy image is busybox, hence wget.
ctl() {
  kc -n "$NS" exec deploy/stale-proxy -- \
     wget -qO- --post-data='{}' "http://127.0.0.1:8080$1" 2>&1 | tr -d '\n'
}
fail() { echo "[314] FAIL: $*" >&2; kc -n "$NS" create configmap "$MARK" \
           --from-literal=stage="$*" --dry-run=client -o yaml | kc -n "$NS" apply -f - >/dev/null 2>&1
         exit 1; }

echo "[314] == gen0 state"
n=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
[ "$n" = "1" ] || fail "gen0 ${STS} is ${n:-<none>}, not 1/1 before the scene starts"
rv_old=$(kc -n "$NS" get "$CRD" "$CR" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)
echo "[314] gen0 1/1 (cr rv=$rv_old)"

# ---------------------------------------------------------------------------
# Freeze the ONE-replica CR. /capture is a LIST of the scoped kind that REPLACES
# that kind's snapshot entry, so it has to land while the CR still says
# replicas=1 -- and it has to land BEFORE the scale-up, because the snapshot is
# the only thing that makes the later write stale.
# ---------------------------------------------------------------------------
echo "[314] == freeze the one-replica CR"
ctl /capture >/dev/null
d=$(ctl /dump)
# capture MERGES on error -- a failed capture leaves the previous entry in place
# -- so a matching /dump alone would not prove the capture worked; but a
# matching /dump right after a capture that had the object in hand does.
case "$d" in
  *"$NS/$CR rv="*)
    echo "[314] snapshot frozen: $NS/$CR (rv=$rv_old)" ;;
  *)
    fail "capture did not store the CR: $(printf '%s' "$d" | head -c 300)" ;;
esac

echo "[314] == scale the cluster up for real (patch replicas -> 2)"
kc -n "$NS" patch "$CRD" "$CR" --type=merge -p='{"spec":{"replicas":2}}' >/dev/null \
  || fail "could not patch the CR's replicas"
up=0
for _ in $(seq 1 450); do
  n=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [ "$n" = "2" ]; then up=1; break; fi
  sleep 2
done
[ "$up" = 1 ] || fail "gen1 ${STS} never reached 2/2 after the scale-up"
rv_new=$(kc -n "$NS" get "$CRD" "$CR" -o jsonpath='{.metadata.resourceVersion}' 2>/dev/null)
owner_rv=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.metadata.labels.owner-rv}' 2>/dev/null || true)
echo "[314] scaled up: sts 2/2, cr rv=$rv_new, sts owner-rv=${owner_rv:-<unset>}"

# [needle-swap 2026-09-24] wait until the CR ITSELF has published status.replicas=2
# before flipping stale. The poll observable now reads
# {.spec.replicas}/{.status.replicas}; this guard makes the phase readings
# monotone -- 1/1 -> 2/2 -> (flip) 2/1 -- so no mid-scale-up "2/1" transient can
# anchor onset early. Failure here means the scale-up leg never fully published,
# the same precondition the 2/2 wait above already asserts on the sts.
pub=0
for _ in $(seq 1 150); do
  s=$(kc -n "$NS" get "$CRD" "$CR" -o jsonpath='{.status.replicas}' 2>/dev/null)
  [ "$s" = "2" ] && pub=1 && break
  sleep 2
done
[ "$pub" = 1 ] || fail "CR status.replicas never published 2 after the scale-up"
echo "[314] CR status published replicas=2 (rv=$rv_new)"

echo "[314] == stale ON + operator restart"
ctl /stale/on >/dev/null
kc -n "$NS" rollout restart "deploy/$OP" >/dev/null
kc -n "$NS" rollout status "deploy/$OP" --timeout=600s >/dev/null 2>&1 || true
for _ in $(seq 1 60); do
  r=$(kc -n "$NS" get deploy "$OP" -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [ "$r" = "1" ] && break
  sleep 5
done

# Two observation windows: the stale reconcile fires on the first pass after the
# restart, but the scale-down path first has to connect to the ZK client service
# and rewrite the CLUSTER_SIZE znode, so give it a second window before
# concluding.
sleep 60
spec_mid=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
sleep 60

spec=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.spec.replicas}' 2>/dev/null || true)
ready=$(kc -n "$NS" get sts "$STS" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true)
if kc -n "$NS" get pod "$POD1" >/dev/null 2>&1; then pod1=present; else pod1=gone; fi
echo "[314] after the flip: sts spec=${spec:-?} ready=${ready:-?} ${POD1}=${pod1} (mid spec=${spec_mid:-?})"
echo "[314] --- operator stale-path lines ---"
kc -n "$NS" logs "deploy/$OP" --tail=400 2>/dev/null \
  | grep -iE 'Staleness|Updating Cluster Size|Connected to ZK' | tail -5 || true

# The fault is the sts being driven back down to ONE replica while the CR in the
# world says two. Read BOTH halves: spec.replicas is what the stale reconcile
# wrote, and the pod is the thing a human would actually notice. `ready` alone
# is not usable as the verdict -- a sts sitting at 1/1 with spec 1 looks
# "fully ready" to any probe that compares ready against spec (the same trap the
# bridge header warns about for sts_ready).
fault=absent
if [ "$spec" = "1" ] || [ "$pod1" = "gone" ]; then fault=present; fi

# The marker is what seed.py's post-trigger slot asserts on. Absence of a pod is
# not expressible as a probe there (`kubectl get` on a missing object exits
# non-zero and reads as a MISS), and "spec went back to 1" is not a substring
# test either -- so the trigger records the observation and a single-valued
# summary of it, and the seed asserts the summary. gen1=up is the positive
# control: the scale-up itself definitely happened.
kc -n "$NS" create configmap "$MARK" \
  --from-literal=sts="${spec:-unknown}" \
  --from-literal=pod1="$pod1" \
  --from-literal=fault="$fault" \
  --from-literal=gen1=up --dry-run=client -o yaml \
  | kc -n "$NS" apply -f - >/dev/null

if [ "$fault" = "absent" ]; then
  if [ "$SCENE_EXPECT" = "none" ]; then
    # host bridge, candidate leg: the sts surviving the stale flip IS the fixed
    # behaviour. The recovery predicate (object_present + min_hold_sec) judges
    # it; exiting non-zero here would abort the seed before it ever got to poll.
    echo "[314] ${STS} intact after the stale flip -- expected on the candidate leg; leaving the verdict to recovery"
  else
    fail "the stale reconcile did not scale ${STS} back down (spec=${spec:-?} ${POD1}=${pod1})"
  fi
fi
echo "=== zkop-314 stale scene done (sts spec=${spec:-?} ${POD1}=${pod1}) ==="
exit 0
