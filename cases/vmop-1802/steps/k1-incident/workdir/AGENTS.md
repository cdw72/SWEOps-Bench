# Specialist subagents

Detection, diagnosis and repair are each handled by a specialist subagent.
`setup.sh` installs the three role cards for both supported agent backends
(`agents/*.md` for Claude Code, `$CODEX_HOME/agents/*.toml` for Codex):

- `sweops-detection` — step 1, Detection: decide whether a material runtime
  fault currently exists, from runtime evidence only (read-only, no source
  access).
- `sweops-rca` — step 2, Diagnosis: establish the failure mechanism of the
  detected anomaly in the source tree (read source, edit nothing).
- `sweops-repair` — step 3, Repair: edit `/operator-src` against the confirmed
  diagnosis and submit the fix. It is the only agent that edits source.

Delegate each step to its specialist instead of doing the work inline: run
step 1 with `sweops-detection`, and if it reports a material fault, run step 2
with `sweops-rca`, then step 3 with `sweops-repair`. After each feedback round,
re-dispatch the relevant specialist. The steps, their time budgets and their
required output artifacts are defined by the task instruction; the role cards
carry the role-specific rules.
