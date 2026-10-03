#!/usr/bin/env bash
# cassop-705 trigger (2026-09-13). The seed applies the two CR
# generations, but the fault needs a THIRD object that no
# generator step creates, so it is made here (step 7) and its
# effect is asserted immediately after.
#
# The bug -- pkg/reconciliation/reconcile_configsecret.go:93 --
#     secret.Annotations[api.DatacenterAnnotation] = dc.Name
# writes a NIL map. controller-runtime runs controllers without
# RecoverPanic, so the panic takes the process down and the
# manager enters CrashLoopBackOff. Fix #706 (19ed2819) swaps in
# metav1.SetMetaDataAnnotation.
#
# PRECONDITION: step 5 has applied mutated-000 (bare datacenter)
# and mutated-001 (same datacenter + spec.configSecret:
# test-config).
#
# The two branches of CheckConfigSecret must not be confused: a
# MISSING Secret crashes nothing. rc.retrieveSecret() failing is
# the GRACEFUL path -- it logs "failed to get config secret" and
# returns result.Error -> requeue, no panic, no restart. The
# panic needs the Secret to EXIST with a nil Annotations map
# (reading a nil map is fine, the WRITE is not). With no
# test-config in the env at all, both probes read the fixed side
# from the first capture and the judge could only return
# VACUOUS -- live, 2026-09-13 22:48.
#
# Non-fatal by design: on timeout it warns and exits 0, leaving
# the judge's own PRE_WAIT/VACUOUS guard to grade the env.
# Hard-failing here would burn a slot on any slow machine.
set -uo pipefail
KC=${1:-/kube/config}
[ -r "$KC" ] || KC=/tmp/kc.yaml
K="kubectl --kubeconfig $KC -n cass-operator"

rc_of() {
  $K get pods --no-headers 2>/dev/null \
    | awk '/^cass-operator-controller-manager-/ {print $4; exit}'
}

echo "[trigger-705] kubectl create -f /seed-data/config-secret-705.yaml"
# create, never apply: client-side apply stamps the
# last-applied-configuration annotation onto the object,
# Annotations stops being nil, and the write lands on a real
# map -- the bug is disarmed.
$K create -f /seed-data/config-secret-705.yaml || {
  echo "[trigger-705] could not create the config Secret"; exit 1; }
echo "[trigger-705] secret created; restartCount=$(rc_of)"

# The requeue that carries the crash is NOT the next one: the
# buggy operator is already failing on this datacenter every
# pass (the NotFound branch), so the attempt that panics lands
# on controller-runtime's 5ms*2^n backoff -- ~82 s out by the
# time the Secret appears. Poll generously.
deadline=$(( $(date +%s) + 300 ))
while :; do
  prev=$($K logs deploy/cass-operator-controller-manager \
    --previous --tail=80 2>/dev/null)
  if printf '%s' "$prev" | grep -qE 'panic:.*nil map'; then
    echo "[trigger-705] FAULT VERIFIED -- manager panicked; restartCount=$(rc_of)"
    printf '%s\n' "$prev" | grep -m2 -E 'panic|nil map' || true
    exit 0
  fi
  if [ "$(date +%s)" -ge "$deadline" ]; then
    echo "[trigger-705] WARNING: no panic within 300s, restartCount=$(rc_of)"
    echo "[trigger-705] the judge's VACUOUS guard is now the only"
    echo "[trigger-705] thing between this env and a silent pass"
    exit 0
  fi
  sleep 10
done
