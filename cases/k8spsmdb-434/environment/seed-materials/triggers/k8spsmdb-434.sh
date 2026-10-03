#!/usr/bin/env bash
# k8spsmdb-434 -- induce the sharding-disable/enable nil-pointer SIGSEGV.
#
# GT: `pkg/controller/perconaservermongodb/mgo.go:78` dereferences
# `cr.Status.Mongos.Status` with no nil guard. Toggling `spec.sharding.enabled`
# false->true while `Status.Mongos` is nil (persisted by status.go:158 on the
# clean disabled-phase reconcile) panics the operator. Fix (#638, 4c8ee710) is
# the `cr.Status.Mongos != nil &&` guard.
#
# The crash is TRANSIENT and the window is NARROW (measured by the original
# sieve seeder, seed_sieve_case.py:51): the re-enable must land AFTER the
# disable's status update persists Status.Mongos=nil (~5-10s) but BEFORE the
# rs0 rolling restart from the config change makes rs0 not-ready (~30-60s) --
# outside that, the mgo.go deref is short-circuited and nothing crashes. So the
# wait is on the OBSERVED precondition (status.mongos empty), never a sleep.
# Up to 3 cycles, then give up.
#
# Like triggers/cnpg11005-interrupt.sh this script does NOT assert the fault:
# the bridge also runs it against the FIXED candidate, where the operator must
# NOT crash, so a non-zero exit here would fail the oracle side. The judgement
# belongs to the env's fault_verify_after (always-buggy) and the bridge's
# recovery predicate (operator restartCount stays 0 on fixed).
#
# argv[1] = kubeconfig, argv[2] = namespace (default psmdb),
# argv[3] = CR name (default mongodb-cluster).
set -u
KC="${1:?usage: k8spsmdb-434.sh <kubeconfig> [ns] [cr]}"
NS="${2:-psmdb}"
CR="${3:-mongodb-cluster}"
K="kubectl --kubeconfig $KC -n $NS"
OP=deploy/percona-server-mongodb-operator
log() { echo "[434] $*"; }

restarts() {
  local n
  # the 1.7.0 bundle labels the operator pod with the bare `name` key
  # (bundle.yaml: selector/matchLabels `name: percona-server-mongodb-operator`),
  # not the newer app.kubernetes.io/name
  n=$($K get pods -l name=percona-server-mongodb-operator \
        -o jsonpath='{.items[*].status.containerStatuses[*].restartCount}' 2>/dev/null \
      | tr -dc '0-9')
  [ -z "$n" ] && n=0
  printf '%s' "$n"
}

shard_state() {
  $K get psmdb "$CR" -o jsonpath='{.spec.sharding.enabled}' 2>/dev/null
}

case "$(shard_state)" in
  true) log "gen0 has sharding enabled -- good (the bug needs a true->false->true cycle)" ;;
  "")   log "FATAL: CR $CR not found in ns $NS"; exit 1 ;;
  *)    log "NOTE: sharding not enabled at entry (state='$(shard_state)'); enabling first"
        $K patch psmdb "$CR" --type merge -p '{"spec":{"sharding":{"enabled":true}}}' >/dev/null || exit 1 ;;
esac

BASE=$(restarts)
log "operator restartCount at entry: $BASE"

FIRED=""
for cycle in 1 2 3; do
  log "cycle $cycle/3: disabling sharding"
  $K patch psmdb "$CR" --type merge -p '{"spec":{"sharding":{"enabled":false}}}' >/dev/null \
    || { log "FATAL: disable patch failed"; exit 1; }

  nil=no
  for i in $(seq 1 36); do            # 36 x 5s = 180s
    if [ -z "$($K get psmdb "$CR" -o jsonpath='{.status.mongos}' 2>/dev/null)" ]; then
      nil=yes; log "cycle $cycle: status.mongos is nil (poison state) after $((i*5))s"; break
    fi
    sleep 5
  done
  if [ "$nil" = no ]; then
    log "cycle $cycle: status.mongos never went nil; aborting this cycle"
    continue
  fi

  log "cycle $cycle: re-enabling IMMEDIATELY (this is the window)"
  $K patch psmdb "$CR" --type merge -p '{"spec":{"sharding":{"enabled":true}}}' >/dev/null \
    || { log "FATAL: enable patch failed"; exit 1; }

  for i in $(seq 1 24); do            # 24 x 5s = 120s
    cur=$(restarts)
    if [ "$cur" -gt "$BASE" ] 2>/dev/null; then
      log "cycle $cycle: CRASH FIRED -- operator restartCount $BASE -> $cur after $((i*5))s"
      FIRED=yes; break
    fi
    sleep 5
  done
  [ -n "$FIRED" ] && break
  log "cycle $cycle: no operator crash within 120s (window missed)"
done

if [ -z "$FIRED" ]; then
  log "no crash after 3 cycles (window missed every time)"
  # ★ Marker convention (harbor-work/recovery_judge.sh step 5c): when this
  #   script is used as a RE-ARM, these two bare tokens are what the judge
  #   greps -- REARM-FIRED = the fault was re-established on the build that is
  #   deployed right now; REARM-MISSED = it was not. They must not change the
  #   exit code (see the header: a non-zero exit here would fail the oracle
  #   side, where a correct candidate must NOT crash).
  echo "REARM-MISSED"
else
  # The evidence the task is about lives in the PREVIOUS container's log; print
  # it here so the run log carries it either way.
  log "previous-log panic evidence:"
  $K logs "$OP" --previous --tail=400 2>&1 | grep -m3 -E "Observed a panic|nil pointer|mgo.go" \
    | sed 's/^/[434]   /' || log "  (none found)"
  echo "REARM-FIRED"
fi
exit 0
