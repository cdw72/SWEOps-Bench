#!/usr/bin/env bash
# Suite regression judge (PASS_TO_PASS). Runs INSIDE the environment
# (shared verifier mode) against the agent's /operator-src workspace.
# Offline: module cache + toolchain are baked at env build; GOPROXY=off so
# nothing is fetched. go test -json REALLY compiles the agent's patched tree
# and executes every test; suite_check.py then asserts the baseline-green
# set (recorded on the unpatched pin) is still entirely green.
# 2026-09-12b: prefixed with a COMPILE gate over every package that built
# at the pin (go test only compiles test-bearing packages; a broken package
# with no tests would otherwise pass unnoticed).
set -uo pipefail
SRC=/operator-src
HID=/tests/hidden
PY=/opt/sweops-venv/bin/python
[ -x "$PY" ] || PY=python3
if [ ! -f "$SRC/go.mod" ]; then
  echo "[regression] no source workspace at $SRC" >&2
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

echo "[regression] go test -json ./pkg/clusterd/... ./pkg/daemon/ceph/cleanup/... ./pkg/daemon/ceph/client/... ./pkg/daemon/ceph/osd/... ./pkg/daemon/ceph/osd/kms/... ./pkg/daemon/discover/... ./pkg/daemon/multus/... ./pkg/daemon/util/... ./pkg/operator/ceph/... ./pkg/operator/ceph/client/... ./pkg/operator/ceph/cluster/... ./pkg/operator/ceph/cluster/mgr/... ./pkg/operator/ceph/cluster/mon/... ./pkg/operator/ceph/cluster/nodedaemon/... ./pkg/operator/ceph/cluster/osd/... ./pkg/operator/ceph/cluster/osd/topology/... ./pkg/operator/ceph/cluster/rbd/... ./pkg/operator/ceph/config/... ./pkg/operator/ceph/config/keyring/... ./pkg/operator/ceph/controller/... ./pkg/operator/ceph/csi/... ./pkg/operator/ceph/csi/peermap/... ./pkg/operator/ceph/disruption/clusterdisruption/... ./pkg/operator/ceph/disruption/controllerconfig/... ./pkg/operator/ceph/file/... ./pkg/operator/ceph/file/mds/... ./pkg/operator/ceph/file/mirror/... ./pkg/operator/ceph/file/subvolumegroup/... ./pkg/operator/ceph/nfs/... ./pkg/operator/ceph/nvmeof/... ./pkg/operator/ceph/object/... ./pkg/operator/ceph/object/bucket/... ./pkg/operator/ceph/object/cosi/... ./pkg/operator/ceph/object/notification/... ./pkg/operator/ceph/object/realm/... ./pkg/operator/ceph/object/topic/... ./pkg/operator/ceph/object/user/... ./pkg/operator/ceph/object/user/opmask/... ./pkg/operator/ceph/object/zone/... ./pkg/operator/ceph/object/zonegroup/... ./pkg/operator/ceph/pool/... ./pkg/operator/ceph/pool/radosnamespace/... ./pkg/operator/ceph/reporting/... ./pkg/operator/ceph/version/... ./pkg/operator/discover/... ./pkg/operator/k8sutil/... ./pkg/operator/test/... ./pkg/util/... ./pkg/util/dependents/... ./pkg/util/display/... ./pkg/util/exec/... ./pkg/util/flags/... ./pkg/util/sys/... (offline, PASS_TO_PASS)" >&2
go test -vet=off -count=1 -json ./pkg/clusterd/... ./pkg/daemon/ceph/cleanup/... ./pkg/daemon/ceph/client/... ./pkg/daemon/ceph/osd/... ./pkg/daemon/ceph/osd/kms/... ./pkg/daemon/discover/... ./pkg/daemon/multus/... ./pkg/daemon/util/... ./pkg/operator/ceph/... ./pkg/operator/ceph/client/... ./pkg/operator/ceph/cluster/... ./pkg/operator/ceph/cluster/mgr/... ./pkg/operator/ceph/cluster/mon/... ./pkg/operator/ceph/cluster/nodedaemon/... ./pkg/operator/ceph/cluster/osd/... ./pkg/operator/ceph/cluster/osd/topology/... ./pkg/operator/ceph/cluster/rbd/... ./pkg/operator/ceph/config/... ./pkg/operator/ceph/config/keyring/... ./pkg/operator/ceph/controller/... ./pkg/operator/ceph/csi/... ./pkg/operator/ceph/csi/peermap/... ./pkg/operator/ceph/disruption/clusterdisruption/... ./pkg/operator/ceph/disruption/controllerconfig/... ./pkg/operator/ceph/file/... ./pkg/operator/ceph/file/mds/... ./pkg/operator/ceph/file/mirror/... ./pkg/operator/ceph/file/subvolumegroup/... ./pkg/operator/ceph/nfs/... ./pkg/operator/ceph/nvmeof/... ./pkg/operator/ceph/object/... ./pkg/operator/ceph/object/bucket/... ./pkg/operator/ceph/object/cosi/... ./pkg/operator/ceph/object/notification/... ./pkg/operator/ceph/object/realm/... ./pkg/operator/ceph/object/topic/... ./pkg/operator/ceph/object/user/... ./pkg/operator/ceph/object/user/opmask/... ./pkg/operator/ceph/object/zone/... ./pkg/operator/ceph/object/zonegroup/... ./pkg/operator/ceph/pool/... ./pkg/operator/ceph/pool/radosnamespace/... ./pkg/operator/ceph/reporting/... ./pkg/operator/ceph/version/... ./pkg/operator/discover/... ./pkg/operator/k8sutil/... ./pkg/operator/test/... ./pkg/util/... ./pkg/util/dependents/... ./pkg/util/display/... ./pkg/util/exec/... ./pkg/util/flags/... ./pkg/util/sys/... > /tmp/regress.json 2>/tmp/regress.err
rc=${PIPESTATUS[0]}
if [ $rc -ne 0 ] && [ ! -s /tmp/regress.json ]; then
  echo "[regression] go test failed to run (rc=$rc)" >&2
  tail -20 /tmp/regress.err >&2
  exit 1
fi
"$PY" "$HID/suite_check.py" /tmp/regress.json "$HID/green.json"
