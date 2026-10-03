#!/usr/bin/env bash
# cnpgop-11005 -- interrupt the pg_basebackup bootstrap AFTER it has begun
# writing into the target PGDATA, then confirm the replica can never recover.
#
# Why this is a script and not a one-line `delete pod -l ...` trigger:
# the fault only appears if the interrupt lands inside a window -- after
# pg_basebackup has created files under pgdata/ and before the Job Pod exits.
# A fixed sleep races that window and loses it in both directions. Observed on
# 2026-09-11 against a live env:
#   * probe = "the pgbasebackup Pod object exists" + settle 10s -> the delete
#     landed while the container was not yet writing; the retry started from an
#     empty directory and the replica bootstrapped HEALTHILY (the exact failure
#     this file exists to prevent).
#   * measured timeline: Pod Pending at +2s, Running with 27 files under
#     pgdata/ at +6s, Job still retrying at +25s.
# So instead of guessing, observe the precondition: poll the Pod until
# `ls -A pgdata` is non-empty, and only then delete it. Deleting any time in
# [first byte, Pod exit] leaves a PGDATA the unguarded retry cannot use; the
# gate fires at the earliest end of that window, far from the exit.
#
# argv[1] = kubeconfig of the env cluster (seed.py passes AGENT_KC).
set -u
KC="${1:?usage: cnpgop-11005.sh <kubeconfig>}"
K="kubectl --kubeconfig $KC -n default"
CLUSTER=repl
log() { echo "[11005-trigger] $*"; }

# the bootstrap Job is named <cluster>-1-pgbasebackup
resolve_pod() {
  $K get pods -l cnpg.io/jobRole=pgbasebackup --no-headers -o name 2>/dev/null \
    | grep "/${CLUSTER}-1-pgbasebackup" | head -1
}

# 1. the bootstrap Job's Pod
POD=""
for _ in $(seq 1 240); do
  POD=$(resolve_pod)
  [ -n "$POD" ] && break
  sleep 1
done
[ -z "$POD" ] && { log "FATAL: no pgbasebackup pod for $CLUSTER"; exit 1; }
log "bootstrap pod: ${POD#pod/}"

# 2. interrupt only once pgdata/ holds something
FIRED=""
for _ in $(seq 1 400); do
  POD=$(resolve_pod)
  if [ -z "$POD" ]; then
    log "bootstrap pod gone before we could interrupt it"
    break
  fi
  POD=${POD#pod/}
  PH=$($K get pod "$POD" -o jsonpath='{.status.phase}' 2>/dev/null)
  if [ "$PH" = "Running" ]; then
    N=$($K exec "$POD" -c pgbasebackup -- \
          sh -c 'ls -A /var/lib/postgresql/data/pgdata 2>/dev/null | wc -l' \
          2>/dev/null)
    case "${N:-}" in ''|*[!0-9]*) N=0 ;; esac
    if [ "$N" -ge 1 ]; then
      log "pgdata holds $N entries -- deleting $POD mid-bootstrap"
      $K delete pod "$POD" --wait=false >/dev/null 2>&1
      FIRED=yes
      break
    fi
  fi
  sleep 0.5
done
[ -z "$FIRED" ] && { log "FATAL: never caught the bootstrap mid-write"; exit 1; }

# 3. every retry must now refuse the left-over PGDATA. Wait for the literal
#    upstream error -- this is the fault's own signature (the telemetry
#    clog_sig), not a proxy for it.
for _ in $(seq 1 180); do
  OUT=$($K logs -l cnpg.io/jobRole=pgbasebackup --tail=-1 2>/dev/null)
  case "$OUT" in
    *"exists but is not empty"*)
      log "FAULT VERIFIED: pg_basebackup refuses the pre-existing PGDATA"
      exit 0 ;;
  esac
  sleep 2
done
log "FATAL: no retry reported a non-empty PGDATA"
$K get pods -o wide
exit 1
