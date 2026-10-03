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
    "file": "internal/controller/operator/factory/vmagent/vmagent.go",
    "function": "CreateOrUpdate",
    "mechanism": "VMAgent ingestOnlyMode:true 时 CreateOrUpdate 只在 `!cr.Spec.IngestOnlyMode` 下调用 createK8sAPIAccess(建 Role/RoleBinding 授予 vmagent SA 读 secrets/configmaps)。但 config-reloader sidecar 的挂载条件是 `!IngestOnlyMode || HasAnyRelabellingConfigs() || HasAnyStreamAggrRule()`——本 CR ingestOnlyMode:true 且带 remoteWrite[0].inlineUrlRelabelConfig(丢 internal_.*),故 HasAnyRelabellingConfigs()=true → 仍挂 reloader。reloader 以 vmagent SA(default:vmagent-vmagent)初始化 GET 配置 secret vmagent-vmagent,却无任何 RBAC → `secrets \"vmagent-vmagent\" is forbidden` fatal → config-reloader 崩溃循环,vmagent pod 永不 2/2。Fix(#1830+#1926):RBAC 条件加 ||HasAnyRelabellingConfigs()||HasAnyStreamAggrRule();纯 ingestOnly 时 reloader 不挂 config secret(ss=nil)。fixed:RBAC 就位/config-reloader 不再 fatal,pod 2/2 Running。"
  }
}
DIAG_EOF

# Emit the clean->fixed source diff: graded in-sandbox by the
# source-fix floor judge (no_reg fix_assert) and consumed by the
# off-platform host recovery bridge in full runs.
if [ -d /operator-src-clean ] && [ -d /operator-src ]; then
  diff -ruN /operator-src-clean /operator-src > /sweops_out/fix.diff 2>/dev/null || true
fi
