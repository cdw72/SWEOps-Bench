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
    "file": "internal/controller/operator/factory/vmanomaly/config/models.go",
    "function": "prophetModel",
    "mechanism": "v0.72.0 的 prophetModel struct 用单数 yaml tag(seasonality/tz_seasonality)+单对象类型(*prophetModelSeasonality),而 vmanomaly v1.29.7 的配置 schema 用复数(seasonalities/tz_seasonalities)+list。VMAnomaly CR vmanomaly 的 spec.configRawYaml 按官方文档写复数 list -> createOrUpdateConfig -> config.NewParsedObjects/Load 用 yaml.UnmarshalStrict 解析 -> 'field seasonalities not found in type config.prophetModel' + 'field tz_seasonalities not found' -> VMAnomaly Reconciler error 循环,reconcile 在 createOrUpdateApp(建 STS vmanomaly-vmanomaly)步前 return -> STS 永不创建,CR 永不就绪(只有 headless Service 先建出来)。Fix(#2357,eca210e4):struct 改复数 yaml tag + []yaml.MapSlice/[]tzSeasonality(含 tzSeasonality 双形态 UnmarshalYAML)。fixed:复数解析通过 -> STS 创建。"
  }
}
DIAG_EOF

# Emit the clean->fixed source diff: graded in-sandbox by the
# source-fix floor judge (no_reg fix_assert) and consumed by the
# off-platform host recovery bridge in full runs.
if [ -d /operator-src-clean ] && [ -d /operator-src ]; then
  diff -ruN /operator-src-clean /operator-src > /sweops_out/fix.diff 2>/dev/null || true
fi
