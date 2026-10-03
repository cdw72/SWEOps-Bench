#!/usr/bin/env bash
# grafanaop-2389 显性化触发器 (grafana/grafana-operator #2389 / PR #2417)
#
# bug: v5.21.1 controllers/autodetect/main.go:58 HasGatewayAPI() 只做
#   hasAPIGroup("gateway.networking.k8s.io") —— 组级探测。main.go:257 拿这个
#   布尔量给 controllers.GrafanaReconciler{HasGatewayAPI: ...},控制器随即注册
#   HTTPRoute watch;集群里这个组存在、但 HTTPRoute kind 不在(部分 CRD 集)时,
#   manager 创建期解析 RESTMapping 失败:
#     "unable to create new manager ... failed to determine if
#      *v1.HTTPRoute is namespaced" -> os.Exit(1) -> CrashLoopBackOff。
# fix #2417 (01b7d55d, v5.22.0+): 新增 pkg/autodetect/cluster.go 的
#   ClusterDiscovery.HasHTTPRouteCRD() = hasKind("gateway.networking.k8s.io/v1",
#   "HTTPRoute")(ServerResourcesForGroupVersion 后扫 APIResources 的 kind,
#   NotFound -> false),组级 -> kind 级,缺 kind 就跳过 HTTPRoute 控制器。
#
# 本 env 的"部分 CRD 集"由一个 dummy CRD(dummyroutes.gateway.networking.k8s.io,
# 带 api-approved 注解)造出来 —— 组在、HTTPRoute 不在。与 otelop-5357 同款配方,
# 区别是 5357 的修复也停在组级所以对本场景无效(这正是 5357 被排除、2389 可上架
# 的根因)。
#
# 前置(seed 已落 —— trigger 只断言"输入在位",不做故障判定):
#   1. dummy CRD 存在(否则组不在,两侧都不崩 -> 空判别)
#   2. HTTPRoute CRD **不存在**(否则真 kind 在,两侧都能起来 -> 空判别)
#   3. operator Deployment 存在
# 这三条是 buggy/fixed 共享的输入,任何一条不成立就是 env 搭错了,直接 exit 1。
#
# 判别(两侧都必须 exit 0,否则 fixed 侧会被自己的触发器判死):
#   buggy -> Pod restart 增长 且/或 日志出现
#            "failed to determine if *v1.HTTPRoute is namespaced" = FAULT VERIFIED
#   fixed -> Pod Running 0 restart                           = 无故障(兼容)
# 判定纪律:smoke reward=1 不算过,要回看这一行是不是 FAULT VERIFIED。
#
# 用法: grafanaop-2389.sh <kubeconfig>
set -uo pipefail
KC="${1:?usage: grafanaop-2389.sh <kubeconfig>}"
K=(kubectl --kubeconfig "$KC")
NS="${SWEOPS_TRIGGER_NS:-grafana}"
DEPLOY=grafana-operator-controller-manager
DUMMY=dummyroutes.gateway.networking.k8s.io
HTTPROUTE=httproutes.gateway.networking.k8s.io
DEADLINE_SECS=300

# 0) 前置 —— 部分 CRD 集必须在位
if ! "${K[@]}" get crd "$DUMMY" >/dev/null 2>&1; then
  echo "[trigger] FAIL: $DUMMY 不在 -> gateway 组不存在,两侧都不会崩(空判别)" >&2
  exit 1
fi
if "${K[@]}" get crd "$HTTPROUTE" >/dev/null 2>&1; then
  echo "[trigger] FAIL: $HTTPROUTE 存在 -> 不是部分 CRD 集场景,两侧都能起来" >&2
  exit 1
fi
if ! "${K[@]}" -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1; then
  echo "[trigger] FAIL: deploy/$DEPLOY 不在 ns=$NS" >&2
  exit 1
fi
echo "[trigger] baseline: $DUMMY present, $HTTPROUTE absent, deploy/$DEPLOY exists"

# 1) 等 buggy 的 crashloop 成形(最多 DEADLINE_SECS)
DEADLINE=$((SECONDS + DEADLINE_SECS))
RESTARTS=0
LOGS=""
CRASHED=0
while (( SECONDS < DEADLINE )); do
  RESTARTS=$("${K[@]}" -n "$NS" get pods -l app.kubernetes.io/name=grafana-operator \
    -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)
  [[ -z "$RESTARTS" ]] && RESTARTS=0
  LOGS=$("${K[@]}" -n "$NS" logs "deploy/$DEPLOY" --tail=400 --all-containers 2>/dev/null)
  if grep -q "failed to determine if \*v1.HTTPRoute is namespaced" <<<"$LOGS"; then
    CRASHED=1; break
  fi
  (( RESTARTS >= 2 )) && { CRASHED=1; break; }
  sleep 10
done

if (( CRASHED == 1 )); then
  echo "[trigger] FAULT VERIFIED: operator 起不来 (restarts=$RESTARTS)"
  echo "$LOGS" | grep -E "unable to create new manager|failed to determine if \*v1.HTTPRoute|no matches for kind" \
    | tail -3 | sed 's/^/[trigger]   /'
  echo "[trigger]   -- 根因: HasGatewayAPI() 是组级探测,组在但 HTTPRoute kind 缺 -> 注册 watch 时解析 RESTMapping 失败"
  exit 0
fi

# 没崩:要么是 fixed 变体,要么 env 有问题 —— 用 Pod 状态区分
PHASE=$("${K[@]}" -n "$NS" get pods -l app.kubernetes.io/name=grafana-operator \
  -o jsonpath='{.items[0].status.phase}' 2>/dev/null)
READY=$("${K[@]}" -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
if [[ "$PHASE" == "Running" && "${READY:-0}" -ge 1 ]]; then
  echo "[trigger] no crash -> fixed-compatible (Running, restarts=$RESTARTS;buggy 侧出现这行即为未复现)"
  exit 0
fi
echo "[trigger] INCONCLUSIVE: 未崩溃但也未就绪 (phase=${PHASE:-?}, available=${READY:-0}, restarts=$RESTARTS)" >&2
tail -15 <<<"$LOGS" | sed 's/^/[trigger]   /' >&2
exit 1
