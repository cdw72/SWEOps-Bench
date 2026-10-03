#!/usr/bin/env bash
# K8SPSMDB-578 deterministic drift injection (2026-09-11). The psmdb twin of
# k8spxc-896-drift.sh -- same PR-shaped bug (reconsileSSL GETs only the EXTERNAL
# ssl secret and returns early), same deterministic recipe.
#
# Story: the operator had already written BOTH TLS secrets (createSSLManualy
# issues them together) when it was restarted at a bad moment. After the
# restart reconsileSSL (pkg/controller/perconaservermongodb/ssl.go) finds
# mongodb-cluster-ssl, returns immediately, and never notices that
# mongodb-cluster-ssl-internal is gone -- the internal secret is never
# recreated. The cluster stays HEALTHY (the ssl-internal volume is Optional,
# psmdb_controller.go:929, and the running mongods keep the files they already
# mounted), so there is no crash, no restart and no error log: the drift IS the
# missing object.
#
# Why this is deterministic (no timing race): the sieve recipe (seed_k8spsmdb_578
# in seed_sieve_case.py) polls from inside the control-plane container and
# force-kills the operator in the window BETWEEN the two createSSLManualy
# writes, where a single tls.Issue() is the whole window. That poll cannot be
# reproduced here (the harness only hands a trigger its kubeconfig), and it
# need not be: letting the operator finish both writes, deleting the internal
# secret and then force-killing the operator lands the restart in exactly the
# same state -- external present, internal absent -- with no dependence on
# timing. Two-sided telemetry backs the end state: buggy `ssl-internal
# missing=True, ssl present=True, rs0 healthy=True`, fixed `missing=False`
# (telemetry/k8spsmdb-578/{buggy,fixed}-seed.log).
#
# buggy  -> operator restarts, sees mongodb-cluster-ssl, returns early,
#           ssl-internal never reappears, and the marker below gets stamped.
# fixed  -> reconsileSSL checks BOTH names, recreates the missing one, so the
#           marker is NOT stamped (expected -- the bridge's object_present
#           predicate is what judges this side; it does not read the marker).
#
# Usage: k8spsmdb-578-drift.sh <kubeconfig>
set -uo pipefail
KC="${1:?usage: k8spsmdb-578-drift.sh <kubeconfig>}"
K=(kubectl --kubeconfig "$KC")
NS=default
DEPLOY=percona-server-mongodb-operator
# the psmdb Deployment's selector is the BARE `name=` key (not
# app.kubernetes.io/name) -- see the family notes; app.kubernetes.io/instance
# matches nothing here and the kill would silently no-op.
SEL=name=percona-server-mongodb-operator
EXT=mongodb-cluster-ssl
INT=mongodb-cluster-ssl-internal
MARKER=k8spsmdb-578-drift-injected

# 0) Wait until the buggy operator's first pass has created BOTH secrets. The
#    pair is written together, so this is the normal case -- we are not racing
#    anything, just waiting for the first reconcile to finish.
BOTH=0
for _ in $(seq 1 120); do
  if "${K[@]}" -n "$NS" get secret "$EXT" >/dev/null 2>&1 \
     && "${K[@]}" -n "$NS" get secret "$INT" >/dev/null 2>&1; then
    BOTH=1
    break
  fi
  sleep 5
done
if [[ "$BOTH" != "1" ]]; then
  echo "[drift] FAIL: ssl secret pair never appeared (external+internal)" >&2
  "${K[@]}" -n "$NS" get secrets >&2
  exit 1
fi
echo "[drift] both TLS secrets present (operator's first pass completed)"

# 0a/0b) PLATFORM HYGIENE + convergence wait. Same k8s >= 1.27 trap as
#    k8spxc-896: the 1.7.0 operator publishes unready pod IPs only through the
#    DEPRECATED `service.alpha.kubernetes.io/tolerate-unready-endpoints`
#    annotation, which the EndpointSlice controller no longer honours, so the
#    headless per-pod Services (mongodb-cluster-rs0/cfg) have no DNS entry until
#    a pod is Ready -- while the operator needs those names to run rs.initiate,
#    i.e. to make the pod Ready. Setting the modern field is exactly what the
#    annotation used to mean and is idempotent.
patch_unready_svcs() {
  local s ann cip cur
  for s in $("${K[@]}" -n "$NS" get svc -o jsonpath='{.items[*].metadata.name}' 2>/dev/null); do
    ann=$("${K[@]}" -n "$NS" get svc "$s" -o jsonpath='{.metadata.annotations.service\.alpha\.kubernetes\.io/tolerate-unready-endpoints}' 2>/dev/null)
    cip=$("${K[@]}" -n "$NS" get svc "$s" -o jsonpath='{.spec.clusterIP}' 2>/dev/null)
    [[ "$ann" == "true" || "$cip" == "None" ]] || continue
    cur=$("${K[@]}" -n "$NS" get svc "$s" -o jsonpath='{.spec.publishNotReadyAddresses}' 2>/dev/null)
    [[ "$cur" == "true" ]] && continue
    "${K[@]}" -n "$NS" patch svc "$s" \
      -p '{"spec":{"publishNotReadyAddresses":true}}' >/dev/null 2>&1 \
      && echo "[drift] hygiene: svc/$s publishNotReadyAddresses=true"
  done
}

#    Let the replsets come up before touching anything. Non-fatal on purpose:
#    the injected fault is the missing object, not a broken workload, and the
#    seed's own fault_verify_after asserts rs0=3/3 -- if the cluster is not
#    healthy that probe should be the one to say so, not a trigger timeout.
READY=""
for _ in $(seq 1 180); do
  patch_unready_svcs
  READY=$("${K[@]}" -n "$NS" get sts mongodb-cluster-rs0 \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ "$READY" == "3" ]] && break
  sleep 5
done
echo "[drift] rs0 readyReplicas=${READY:-?} (continuing regardless)"

# 1) Remove the internal secret -- the object the buggy operator will never
#    recreate.
sleep 2
"${K[@]}" -n "$NS" delete secret "$INT" || exit 1
echo "[drift] deleted secret $INT"

# 2) Force-kill the operator so the next reconcile starts from the intermediate
#    state. --grace-period=0 so the restart is immediate and the old process
#    cannot win a final write.
sleep 2
"${K[@]}" -n "$NS" delete pod -l "$SEL" --force --grace-period=0 || exit 1
echo "[drift] force-killed the operator pod (restart lands in the intermediate state)"

# 3) Wait for the replacement pod to be Running so the observation below (and
#    the seed's settle window) covers the post-restart reconcile, not the pod
#    start.
for _ in $(seq 1 60); do
  READY=$("${K[@]}" -n "$NS" get deploy "$DEPLOY" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  [[ "$READY" == "1" ]] && break
  sleep 5
done
echo "[drift] operator back up (readyReplicas=${READY:-?})"

# 4) Observe the drift and stamp a marker. seed.py's verify() only matches
#    SUBSTRINGS of a probe's stdout, so it cannot assert that an object is
#    ABSENT (every `--ignore-not-found` probe prints the empty string, and the
#    empty string is a substring of everything). The marker carries the
#    observation instead: it is written ONLY if the internal secret is still
#    gone after the restarted operator has had 120s to reconcile, so the seed's
#    `get configmap <MARKER>` probe is a real assertion rather than a formality.
#    If the secret comes back (the fixed operator's behaviour) nothing is
#    stamped, and the seed aborts with "the env did not reach the fault state".
for _ in $(seq 1 24); do
  if "${K[@]}" -n "$NS" get secret "$INT" >/dev/null 2>&1; then
    echo "[drift] $INT reappeared -- drift did NOT take (no marker stamped)"
    exit 0
  fi
  sleep 5
done
"${K[@]}" -n "$NS" create configmap "$MARKER" \
  --from-literal=ssl_internal=absent \
  --from-literal=injected_at="$(date -u '+%Y-%m-%dT%H:%M:%SZ')" >/dev/null 2>&1 \
  || "${K[@]}" -n "$NS" label configmap "$MARKER" drift=taken --overwrite >/dev/null
echo "[drift] drift confirmed: $INT still absent after operator restart (marker stamped)"
exit 0
