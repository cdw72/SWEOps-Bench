#!/bin/sh
# round k=1 (incident): re-run the full seed (fault injection) + install subagents
set -e
mkdir -p "$HOME/.claude/agents"
cp "$(dirname "$0")/agents/"*.md "$HOME/.claude/agents/"
# compose starts the container with SWEOPS_SEED_PHASE=pre (healthy baseline).
# Overriding it to 'full' here makes seed.py replay the complete sequence,
# including the fault-injection CR steps, fault_verify and the trigger.
SWEOPS_SEED_PHASE=full python3 /opt/seed.py
[ "$(cat /tmp/seed-done 2>/dev/null)" = "done" ] || { echo "[k1 setup] seed did not complete"; exit 1; }
echo "[k1 setup] fault injected; subagents installed."
