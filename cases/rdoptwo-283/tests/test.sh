#!/usr/bin/env bash
# Resolution verifier (reward=1 iff RCA diagnosis AND source-fix floor (fix_assert) pass (no_reg: no upstream *_test.go; deep recovery on host) AND in-sandbox recovery (deployed tree heals the fault AND every test this case has stays green)).
set -uo pipefail
export TEST_DIR="${TEST_DIR:-/tests}"
PY=/opt/sweops-venv/bin/python
[ -x "$PY" ] || PY=python3

# env/connectivity probe (verifier runs in the same container as the agent)
echo "==== env probe ===="
kubectl get nodes -o wide 2>&1 || true
kubectl get redisclusters -A -o wide 2>&1 || true
echo "==== probe end ===="

"$PY" -m pytest "$TEST_DIR/test_noop.py" -rA
_RCA=$?
"$PY" -m pytest "$TEST_DIR/test_fixassert.py" -rA
_FIX=$?

bash "$TEST_DIR/test_recovery_stages.sh"
_RC=$?
[ "$_RC" -le 1 ] && _DEP=0 || _DEP=1
if [ "${_FIX:-1}" != "0" ] && [ "$_RC" -eq 0 ]
then
  SWEOPS_FIX_RELAX=anyfile "$PY" -m pytest "$TEST_DIR/test_fixassert.py" -rA
  _R2=$?
  if [ "$_R2" -eq 0 ]
  then
    _FIX=0
    echo "[fixassert] relaxed: recovery verified this tree (RC=0); fix need not touch the GT file" >&2
  fi
fi
[ "$_RC" -eq 0 ] && _REC=0 || _REC=1
echo "==== judge: RCA=$_RCA FIX=$_FIX DEP=$_DEP REC=$_REC (no_reg) ===="
mkdir -p /logs/verifier 2>/dev/null || true
if [ "$_RCA" -eq 0 ] && [ "$_FIX" -eq 0 ] && [ "$_REC" -eq 0 ]; then
  echo 1 > /logs/verifier/reward.txt
else
  echo 0 > /logs/verifier/reward.txt
fi
