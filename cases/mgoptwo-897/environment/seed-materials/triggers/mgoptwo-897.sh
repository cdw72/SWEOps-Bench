#!/usr/bin/env bash
# mgoptwo-897 显性化触发器 (2026-09-08, a407 根因):
# bug = v1.12.0 Reconcile(psmdb_controller.go)先 cr.CheckNSetDefaults,失败即
#   return(err "wrong psmdb options"),DeletionTimestamp 分支(:264)在错误返回
#   之后 -> CR 带 finalizer(delete-psmdb-pods-in-order)删除时 finalizer 永
#   远清不掉 -> CR 卡 Terminating。fix #1630(commit 2c1da81b)在错误路径里判
#   DeletionTimestamp!=nil 时 SetFinalizers([])+Update -> CR 可正常删除。
# 前置(seed 已落,oat_tests/mgoptwo-897/mutated-1.yaml):gen1 把
#   spec.replsets[0].storage.engine 置为 mmapv1 —— psmdb_defaults.go:360
#   确定性拒(defaults 只认 wiredTiger/inMemory),CRD 的 engine 是裸 string
#   无 enum,apiserver 放行 -> 错误仅由 operator 层触发。CR 现处于
#   "spec 非法 + operator 拒收"态(带 finalizer、未删)。
# 触发动作(上游场景本体 = 管理员删除这个配置非法的集群):
#   kubectl delete PerconaServerMongoDB test-cluster --wait=false
#   -> buggy: Reconcile 仍被 defaults 错误短路,checkFinalizers 永不达,
#      deletionTimestamp 永久停留、CR 不消失 = FAULT VERIFIED
#   -> fixed: #1630 错误路径清 finalizer -> CR 被 k8s 回收 = 兼容(无故障)
# 断言:轮询 ~180s,CR 消失 -> fixed 兼容(exit 0);CR 仍在且带
#   deletionTimestamp+finalizers -> buggy FAULT VERIFIED(exit 0);
#   前置不符(engine!=mmapv1 或 CR 本就不在)才 rc=1。
#
# 用法: mgoptwo-897.sh <kubeconfig>
set -uo pipefail
KC="${1:?usage: mgoptwo-897.sh <kubeconfig>}"
K=(kubectl --kubeconfig "$KC")
# Namespace: auto-detect (the n3 k3s seeds apply the CR into `mongodb`, the
# Acto-era ones into `acto-namespace`). Hard-coding either makes the baseline
# read below come back empty and the trigger report a false "engine != mmapv1".
# $SWEOPS_TRIGGER_NS overrides for callers that need it.
NS="${SWEOPS_TRIGGER_NS:-}"
if [[ -z "$NS" ]]; then
  NS=$("${K[@]}" get PerconaServerMongoDB -A \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
fi
[[ -z "$NS" ]] && NS=acto-namespace

# 0) 基线验证:故障输入在位(CR spec.storage.engine=mmapv1,operator 拒收态)
ENGINE=$("${K[@]}" -n "$NS" get PerconaServerMongoDB test-cluster \
  -o jsonpath='{.spec.replsets[0].storage.engine}' 2>/dev/null)
echo "[trigger] baseline: CR storage.engine='${ENGINE:-null}'"
if [[ "$ENGINE" != "mmapv1" ]]; then
  echo "[trigger] FAIL: storage.engine != mmapv1 (故障输入不在位,seed 未把非法选项落进 CR)" >&2
  exit 1
fi

# 1) 管理员删除集群(k8s 同步设 deletionTimestamp;后续移除速度=fault 判别)
echo "[trigger] deleting PerconaServerMongoDB test-cluster (--wait=false)..."
if ! "${K[@]}" -n "$NS" delete PerconaServerMongoDB test-cluster --wait=false >/dev/null 2>&1; then
  echo "[trigger] FAIL: kubectl delete rc!=0" >&2
  exit 1
fi

# 2) 轮询:CR 消失(fixed) vs 带 deletionTimestamp 卡死(buggy)
DEADLINE=$((SECONDS + 180))
while (( SECONDS < DEADLINE )); do
  if ! "${K[@]}" -n "$NS" get PerconaServerMongoDB test-cluster >/dev/null 2>&1; then
    echo "[trigger] CR gone -> fixed-compatible (#1630 清 finalizer,删除完成,无故障)"
    exit 0
  fi
  sleep 3
done

# 3) 超时仍存在:确认是 deletionTimestamp+finalizer 卡住(fault),非删除没生效
DT=$("${K[@]}" -n "$NS" get PerconaServerMongoDB test-cluster \
  -o jsonpath='{.metadata.deletionTimestamp}' 2>/dev/null)
FIN=$("${K[@]}" -n "$NS" get PerconaServerMongoDB test-cluster \
  -o jsonpath='{.metadata.finalizers[*]}' 2>/dev/null)
if [[ -n "$DT" ]]; then
  echo "[trigger] FAULT VERIFIED: CR stuck Terminating 180s+ (deletionTimestamp=$DT, finalizers='${FIN}')"
  echo "[trigger]   -- 根因: CheckNSetDefaults 错误短路 Reconcile,checkFinalizers 永不达,finalizer 清不掉"
  exit 0
fi
echo "[trigger] FAIL: CR 仍在但无 deletionTimestamp(delete 未生效?),finalizers='${FIN:-none}'" >&2
exit 1
