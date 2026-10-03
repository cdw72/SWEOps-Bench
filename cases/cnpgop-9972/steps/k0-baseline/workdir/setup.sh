#!/bin/sh
# round k=0 (baseline): install the SWEOps specialist subagent definitions
set -e
mkdir -p "$HOME/.claude/agents"
cp "$(dirname "$0")/agents/"*.md "$HOME/.claude/agents/"
echo "[k0 setup] subagents installed:"; ls "$HOME/.claude/agents/"
