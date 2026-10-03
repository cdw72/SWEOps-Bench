#!/usr/bin/env bash
# Reference solution (resolution task): apply the real fix to the
# in-container /operator-src workspace, then emit the canonical
# diagnosis. The shared-mode verifier sees the fixed tree, so the RCA
# judge AND (full mode) the hidden-test regression judge pass.
set -uo pipefail
# [poll-observe] poll driver observe-only trigger: emit the
# diagnosis (and a fix.diff of the UNTOUCHED workspace) without applying the
# fix, so a pre-phase / post-repair trigger does not roll a fixed operator
# into the cluster and destroy the poll timeline. Full-fix triggers run this
# script plainly, exactly as the single-trigger harbor run does.
if [ "${SWEOPS_ORACLE_OBSERVE:-0}" = 1 ]; then
  mkdir -p /sweops_out
  sed -n '/^cat > \/sweops_out\/diagnosis.json/,/^DIAG_EOF$/p' "$0" | bash
  [ -d /operator-src-clean ] && diff -ruN /operator-src-clean /operator-src \
      > /sweops_out/fix.diff 2>/dev/null || true
  exit 0
fi

HERE="$(cd "$(dirname "$0")" && pwd)"
while IFS= read -r f; do
  [ -n "$f" ] || continue
  mkdir -p "/operator-src/$(dirname "$f")"
  cp "$HERE/fix/$f" "/operator-src/$f"
done < "$HERE/fix/manifest"
# Oracle solution synthesized from ground_truth.json (fix.key_change).
# Writes the canonical diagnosis so the verifier grades 1.
mkdir -p /sweops_out
cat > /sweops_out/diagnosis.json <<'DIAG_EOF'
{
  "fault_detected": true,
  "evidence": "oracle reference solution (GT key_change)",
  "component": "operator",
  "root_cause": {
    "file": "api/operator/v1beta1/vmagent_types.go",
    "function": "IsSharded",
    "mechanism": "VMAgent.IsSharded() gates sharded rendering on ShardCount > 1. The CR has shardCount: 1 with statefulMode: true, so IsSharded() returns false: the operator builds a single non-sharded StatefulSet named vmagent-vmagent (no per-shard suffix) and never renders the %SHARD_NUM% placeholder, which the CR still references in podAntiAffinity matchExpressions values. The literal %SHARD_NUM% is an invalid label value, so the StatefulSet controller's pod vmagent-vmagent-0 fails admission (Warning FailedCreate 'create Pod vmagent-vmagent-0 in StatefulSet vmagent-vmagent failed') and the sts stays 0/1. Fix #2002 (e05474cd) changes the gate to ShardCount > 0 so shardCount: 1 is treated as sharded: the operator renders the shard 0 StatefulSet vmagent-vmagent-0, %SHARD_NUM% becomes '0' in the anti-affinity, and the pod comes up 1/1."
  }
}
DIAG_EOF

# Emit the clean->fixed source diff: graded in-sandbox by the
# source-fix floor judge (no_reg fix_assert) and consumed by the
# off-platform host recovery bridge in full runs.
if [ -d /operator-src-clean ] && [ -d /operator-src ]; then
  diff -ruN /operator-src-clean /operator-src > /sweops_out/fix.diff 2>/dev/null || true
fi
