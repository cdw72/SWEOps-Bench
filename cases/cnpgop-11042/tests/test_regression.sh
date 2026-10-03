#!/usr/bin/env bash
# Upstream regression judge (SWE-bench style). Runs INSIDE the environment
# (shared verifier mode) against the agent's /operator-src workspace.
# Hidden set = the *_test.go files the fix commit touched. The list lives in
# hidden/f2p_files.txt and is staged just-in-time with the answers, so this
# script names no test and no package.
# 1 of them is a STANDALONE F2P exam: rewritten from a
# Ginkgo spec into its own top-level go test so a F2P failure is not also
# reported as a P2P regression of the suite's own test name (green.json).
# Each is copied over the agent's copy, then the target package is tested
# OFFLINE (module cache baked): hidden tests pass only if the agent's fix is
# behaviorally correct; tests the fix did NOT touch must stay green.
set -uo pipefail
SRC=/operator-src
HID=/tests/hidden
if [ ! -f "$SRC/go.mod" ]; then
  echo "[regression] no source workspace at $SRC" >&2
  exit 1
fi
# 名单没就位 ⇒ 拒跑(99),**绝不**退化成"没拷测试、go test 空跑绿" —— 那是空真判分。
if [ ! -s "$HID/f2p_files.txt" ] || [ ! -s "$HID/f2p_pkgs.txt" ]; then
  echo "[regression] hidden test list not staged" >&2
  exit 99
fi
while IFS= read -r f; do
  [ -n "$f" ] || continue
  mkdir -p "$SRC/$(dirname "$f")"
  cp "$HID/$f" "$SRC/$f"
done < "$HID/f2p_files.txt"
if [ -s "$HID/f2p_excluded.txt" ]; then
  # These call a symbol ONLY the reference fix defines, and the agent never
  # sees them. Keeping them would make REG a naming lottery rather than a
  # behaviour check: any correct-but-differently-shaped fix gets
  # `undefined: <symbol>` and [build failed]. Behaviour is graded by REC.
  echo "[regression] EXCLUDED (gold-symbol-coupled, not a valid pass/fail" >&2
  echo "[regression]   criterion for an unseen-symbol test):" >&2
  while IFS= read -r f; do [ -n "$f" ] && echo "[regression]   - $f" >&2; done < "$HID/f2p_excluded.txt"
fi
export GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local
cd "$SRC"
mapfile -t PKGS < "$HID/f2p_pkgs.txt"
echo "[regression] go test (offline, hidden set)" >&2
# 产物写 mktemp、跑完即删。旧版 `tee /tmp/regress.out` 是**绝对路径又没人清**,
# 隐藏测试名与失败原文会常驻容器 /tmp 给 agent 随便读(2026-09-26 实查 18 案)。
OUT="$(mktemp -t regress.XXXXXX)"
go test -vet=off -count=1 "${PKGS[@]}" 2>&1 | tee "$OUT"
rc=${PIPESTATUS[0]}
echo "[regression] rc=$rc" >&2
rm -f "$OUT"
exit $rc
