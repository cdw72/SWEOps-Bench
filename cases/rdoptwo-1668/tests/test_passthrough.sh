#!/usr/bin/env bash
# PASS_TO_PASS judge (added 2026-09-12): every test that was green on the
# UNPATCHED pin must STILL be green on the agent's tree. Runs AFTER
# test_regression.sh, so the fix-era test files are already in place; tests
# the fix commit rewrote are excluded from the green set (FAIL_TO_PASS by
# construction). Offline: module cache baked, GOPROXY=off.
# 2026-09-12b: prefixed with a COMPILE gate -- go test only compiles
# packages that carry tests, so a package broken by the patch but with no
# tests would otherwise pass unnoticed. Baseline build-failures are exempt
# (broken before any patch existed, none of the agent's business).
set -uo pipefail
SRC=/operator-src
HID=/tests/hidden
PY=/opt/sweops-venv/bin/python
[ -x "$PY" ] || PY=python3
if [ ! -f "$SRC/go.mod" ]; then
  echo "[p2p] no source workspace at $SRC" >&2
  exit 1
fi
export GOFLAGS=-mod=mod GOPROXY=off GOTOOLCHAIN=local
cd "$SRC"
# 只取**有非测试 Go 文件**的包:`go build` 对纯测试目录是硬报错的
# ("no non-test Go files in ..."),而那是 pin 自带的属性,不是 agent 弄坏的。
# <case> 就因为这个白烧了一次 smoke(test/e2e 下的 childobjects / deploy /
# watchnamespace 三个纯测试包 → "[build] agent tree no longer compiles")。
# 注意 {...} 在这里必须写成 {{...}}:本片段是 .format() 的模板,单个花括号
# 会被吃掉,双写才渲染成 go list 需要的双花括号模板。
go list -f '{{if .GoFiles}}{{.ImportPath}}{{end}}' ./... 2>/dev/null > /tmp/p2p_all.pkgs
"$PY" - "$HID/build.json" /tmp/p2p_all.pkgs <<'BEOF' > /tmp/p2p_build.args
import json, sys
ex = set(json.load(open(sys.argv[1])).get('exclude_pkgs') or [])
keep = [l.strip() for l in open(sys.argv[2]) if l.strip() and l.strip() not in ex]
print(' '.join(keep))
BEOF
n=$(wc -w < /tmp/p2p_build.args)
if [ "$n" -eq 0 ]; then
  echo "[build] no packages to build?" >&2
  exit 1
fi
echo "[build] go build $n packages that compiled at the pin" >&2
go build $(cat /tmp/p2p_build.args) 2>&1 | tail -5
rc=${PIPESTATUS[0]}
if [ "$rc" -ne 0 ]; then
  echo "[build] agent tree no longer compiles (rc=$rc)" >&2
  exit 1
fi

echo "[p2p] go test -json ./api/common/v1beta2/... ./api/redis/v1beta2/... ./api/rediscluster/v1beta2/... ./api/redisreplication/v1beta2/... ./api/redissentinel/v1beta2/... ./internal/agent/bootstrap/redis/... ./internal/envs/... ./internal/k8sutils/... ./internal/util/... ./internal/util/maps/... ./internal/webhook/... (offline, PASS_TO_PASS)" >&2
go test -vet=off -count=1 -json ./api/common/v1beta2/... ./api/redis/v1beta2/... ./api/rediscluster/v1beta2/... ./api/redisreplication/v1beta2/... ./api/redissentinel/v1beta2/... ./internal/agent/bootstrap/redis/... ./internal/envs/... ./internal/k8sutils/... ./internal/util/... ./internal/util/maps/... ./internal/webhook/... > /tmp/p2p.json 2>/tmp/p2p.err
rc=${PIPESTATUS[0]}
if [ $rc -ne 0 ] && [ ! -s /tmp/p2p.json ]; then
  echo "[p2p] go test failed to run (rc=$rc)" >&2
  tail -20 /tmp/p2p.err >&2
  exit 1
fi
"$PY" "$HID/suite_check.py" /tmp/p2p.json "$HID/green.json"
