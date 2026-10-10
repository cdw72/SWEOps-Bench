#!/bin/sh
# round k=1 (incident): re-run the full seed (fault injection) + install the
# SWEOps specialist subagent definitions for every supported agent backend.
set -e
HERE="$(dirname "$0")"

# --- Claude Code -----------------------------------------------------------
# Under harbor's claude-code agent, CLAUDE_CONFIG_DIR is redirected (to
# /logs/agent/sessions) and $HOME/.claude/agents is no longer scanned, so
# install into the config dir as well as the classic user-scope dir.
for D in "${CLAUDE_CONFIG_DIR:-}" /logs/agent/sessions "$HOME/.claude"; do
  [ -n "$D" ] || continue
  mkdir -p "$D/agents"
  cp "$HERE/agents/"*.md "$D/agents/"
done

# --- Codex -----------------------------------------------------------------
# Codex reads custom agent roles as TOML from $CODEX_HOME/agents/.
CX="${CODEX_HOME:-$HOME/.codex}"
mkdir -p "$CX/agents"
python3 "$HERE/agents/md2codex.py" "$HERE/agents" "$CX/agents"

# compose starts the container with SWEOPS_SEED_PHASE=pre (healthy baseline).
# Overriding it to 'full' here makes seed.py replay the complete sequence,
# including the fault-injection CR steps, fault_verify and the trigger.
SWEOPS_SEED_PHASE=full python3 /opt/seed.py
[ "$(cat /tmp/seed-done 2>/dev/null)" = "done" ] || { echo "[k1 setup] seed did not complete"; exit 1; }
echo "[k1 setup] fault injected; subagents installed (codex: $CX/agents)"
ls "$CX/agents"
