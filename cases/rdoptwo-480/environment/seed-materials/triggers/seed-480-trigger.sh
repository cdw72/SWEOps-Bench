#!/usr/bin/env bash
# rdoptwo-480 (N3 seed trigger) -- 2026-09-11 re-derived from the live seeder
# recipe; supersedes an earlier out-of-tree trigger, which targets
# ns=redis-operator (the current CR lives in `default`) and is missing Phase A.
#
# Why the two phases: the CR's spec.redisLeader.affinity is folded into the
# StatefulSet pod template, so editing it alone is an ordinary legal update --
# the operator would just converge and nothing would be observable. Phase A
# therefore only exists to build the *input* state (a leader pod that cannot
# schedule, so ready<3). Phase B then reverts the affinity together with the
# two fields that actually break the update:
#
#   * metadata.labels.rotate=true      -> getRedisLabels (redis-cluster.go:147)
#     merges the CR's labels into the STS labels, and
#     generateStatefulSetsDef sets Selector = LabelSelectors(labels) -> the
#     desired selector differs from the immutable live one -> the apiserver
#     rejects the update (422 Invalid, 403 Forbidden on newer releases).
#   * metadata.annotations.redis.opstreelabs.in/recreate-statefulset=true
#     is the escape hatch fix #411 reads: it makes the operator delete and
#     rebuild the StatefulSet when the update is rejected. The buggy operator
#     never reads it, so on the buggy side the reconcile just logs
#     "Redis stateful update failed" and returns -- CR and STS diverge
#     permanently (issue #363/#480).
#
# Reverting affinity in the SAME patch as the label/annotation is load-bearing:
# on its own it is a legal update and the operator would converge.
#
# Exit 0 in every non-infrastructure case: the seed engine treats a non-zero
# exit as a build failure, and the fault-present/fault-absent verdict is the
# verifier's job, not the seeder's.
#
# Usage: seed-480-trigger.sh <kubeconfig>
set -uo pipefail
KC="${1:?usage: seed-480-trigger.sh <kubeconfig>}"
K=(kubectl --kubeconfig "$KC")
NS=default
LEADER=test-cluster-leader

# 0) CR present
for _ in $(seq 1 30); do
  "${K[@]}" get rediscluster -n "$NS" test-cluster >/dev/null 2>&1 && break
  sleep 5
done

# 1) baseline: leader AND follower both 3/3 (deadline 420s)
ready_of() {
  "${K[@]}" -n "$NS" get sts "$1" -o jsonpath='{.status.readyReplicas}' 2>/dev/null || true
}
LR=""; FR=""
for _ in $(seq 1 84); do
  LR=$(ready_of "$LEADER"); FR=$(ready_of test-cluster-follower)
  [[ "$LR" == "3" && "$FR" == "3" ]] && break
  sleep 5
done
if [[ "$LR" != "3" || "$FR" != "3" ]]; then
  echo "[trigger] FAIL: baseline not converged (leader=${LR:-} follower=${FR:-})" >&2
  exit 1
fi
# the CR must carry its resources blocks or BOTH variants nil-deref at
# statefulset.go:220 -- if it did, we would never have got here. Settle so the
# baseline is quiet before injecting.
sleep 45

ORIG_UID=$("${K[@]}" -n "$NS" get sts "$LEADER" -o jsonpath='{.metadata.uid}' 2>/dev/null)
echo "[trigger] baseline leader 3/3 follower 3/3 (leader uid=${ORIG_UID:0:8})"

# 2) Phase A -- make the leader unschedulable (input state only, legal update)
"${K[@]}" -n "$NS" patch rediscluster test-cluster --type merge -p \
'{"spec":{"redisLeader":{"affinity":{"nodeAffinity":{"requiredDuringSchedulingIgnoredDuringExecution":{"nodeSelectorTerms":[{"matchExpressions":[{"key":"kubernetes.io/hostname","operator":"In","values":["NONE"]}]}]}}}}}}' \
  || { echo "[trigger] FAIL: phase A patch rejected" >&2; exit 1; }
echo "[trigger] phase A applied (affinity -> hostname In [NONE])"

PENDING=""
for _ in $(seq 1 60); do
  LR=$(ready_of "$LEADER")
  PENDING=$("${K[@]}" -n "$NS" get pods -l app=test-cluster-leader \
    -o jsonpath='{.items[?(@.status.phase=="Pending")].metadata.name}' 2>/dev/null || true)
  [[ "$LR" != "3" && -n "$PENDING" ]] && break
  sleep 5
done
if [[ "$LR" == "3" || -z "$PENDING" ]]; then
  echo "[trigger] FAIL: leader never went unschedulable (ready=${LR:-})" >&2
  exit 1
fi
echo "[trigger] phase A took effect: leader ready=${LR:-}, pending=${PENDING}"
sleep 20

# 3) Phase B -- revert affinity *and* change the immutable selector in one shot
"${K[@]}" -n "$NS" patch rediscluster test-cluster --type merge -p \
'{"metadata":{"labels":{"rotate":"true"},"annotations":{"redis.opstreelabs.in/recreate-statefulset":"true"}},"spec":{"redisLeader":{"affinity":null}}}' \
  || { echo "[trigger] FAIL: phase B patch rejected" >&2; exit 1; }
echo "[trigger] phase B applied (affinity reverted + rotate label + recreate annotation)"

RECREATED=""
for _ in $(seq 1 48); do
  NEW_UID=$("${K[@]}" -n "$NS" get sts "$LEADER" -o jsonpath='{.metadata.uid}' 2>/dev/null || true)
  HAS_LABEL=$("${K[@]}" -n "$NS" get sts "$LEADER" -o jsonpath='{.metadata.labels.rotate}' 2>/dev/null || true)
  if [[ -n "$NEW_UID" && "$NEW_UID" != "$ORIG_UID" ]]; then RECREATED="uid"; break; fi
  if [[ "$HAS_LABEL" == "true" ]]; then RECREATED="label"; break; fi
  sleep 5
done

if [[ -n "$RECREATED" ]]; then
  echo "[trigger] sts recreated ($RECREATED) -- #411 recreate path is live"
  for _ in $(seq 1 60); do
    [[ "$(ready_of "$LEADER")" == "3" ]] && break
    sleep 5
  done
  echo "[trigger] leader ready=$(ready_of "$LEADER") after recreate"
else
  echo "[trigger] FAULT PRESENT: sts uid/label unchanged after 240s" \
       "(uid=${ORIG_UID:0:8}) -- operator stuck on the rejected update"
  echo "[trigger] recent 'Redis stateful update failed' lines:"
  "${K[@]}" -n redis-operator logs deploy/redis-operator --tail=400 2>/dev/null \
    | grep -c "Redis stateful update failed" || true
fi
exit 0
