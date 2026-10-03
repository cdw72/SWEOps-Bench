#!/usr/bin/env bash
# grafanaop-2389 poll **注入步** —— 造出"部分 CRD 集"(gateway 组在、HTTPRoute kind 不在)。
#
# 为什么需要这个脚本(2026-09-20):
#   本案的故障输入 `gateway-dummy-2389.yaml` 原来躺在种子的 `pre_manifests`(第 3 节)
#   里 ⇒ **每一轮**(含 pre)从 t=0 就崩 ⇒ poll harness 认不出"注入步"、把它记成
#   「种子自带故障」⇒ 拿 inject_after=0 + pre_health_cap=0 兜底,等于宣布本案没有
#   健康期。overlay 的 `poll_skip_pre` 把 pre 相位的这份 manifest 摘掉之后,故障就
#   得由**注入步**自己造出来 —— 就是本脚本。
#
# 还有一件**只加 CRD 不够**的事:bug 在 manager **创建期**(把 HasGatewayAPI 的布尔量
#   交给 GrafanaReconciler,控制器随即注册 HTTPRoute watch,这一步解析 RESTMapping
#   失败)。一个**已经跑起来**的算子不会因为集群里多了一个 CRD 就崩 —— 必须让它
#   重新走一遍启动。所以第 4 步删掉算子 pod,让 ReplicaSet 重建它。
#
# 前置(与 triggers/grafanaop-2389.sh 的口径一致):
#   - HTTPRoute CRD **必须不在**(在的话组和 kind 都有,两侧都能起来 = 空判别)
#   - 算子 Deployment 必须在(否则没有东西可重启)
#
# 判别不在这里做 —— 本脚本只负责**把故障输入摆到位并让算子重走启动**;
#   真正的 FAULT VERIFIED 判定交给 seed-config 的 `trigger_script`(grafanaop-2389.sh,
#   注入后由 inject() 紧接着 replay 它):它会等 crashloop 成形、看
#   "failed to determine if *v1.HTTPRoute is namespaced"。两侧分工明确。
#
# 用法: grafanaop-2389-inject.sh <kubeconfig>
set -euo pipefail
KC="${1:?usage: grafanaop-2389-inject.sh <kubeconfig>}"
NS="${SWEOPS_TRIGGER_NS:-grafana}"
DEPLOY=grafana-operator-controller-manager
DUMMY=dummyroutes.gateway.networking.k8s.io
HTTPROUTE=httproutes.gateway.networking.k8s.io
# 每个 API 调用都带 --request-timeout:任何一步都不许无限期挂着(本仓踩过的
# "pvc-protection finalizer 把 delete 挂到 trigger 超时"那一族的通用防线)。
K=(kubectl --kubeconfig "$KC" --request-timeout=60s)

# 1) 前置 —— 必须是"部分 CRD 集":HTTPRoute kind 不在
if "${K[@]}" get crd "$HTTPROUTE" >/dev/null 2>&1; then
  echo "[inject] FAIL: $HTTPROUTE 已存在 -> 组与 kind 都在,两侧都能起来(空判别)" >&2
  exit 1
fi
if ! "${K[@]}" -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1; then
  echo "[inject] FAIL: deploy/$DEPLOY 不在 ns=$NS(没有算子可重启)" >&2
  exit 1
fi

# 2) 摆上故障输入:让 gateway 组存在
"${K[@]}" apply -f /seed-data/gateway-dummy-2389.yaml

# 3) 等它 Established —— 算子靠 discovery 探组,**没 Established 就是空判别**
#    (这一条原来在 seed-config 的 pre_ready 里;搬到这儿 = 守真正要紧的相位)
"${K[@]}" wait --for=condition=Established "crd/$DUMMY" --timeout=180s

# 4) 让算子重走一遍 manager 创建 —— 这一步才是故障的引爆点
"${K[@]}" -n "$NS" delete pod -l app.kubernetes.io/name=grafana-operator \
  --ignore-not-found --wait=false

echo "[inject] $DUMMY 已 Established、deploy/$DEPLOY 已重启 —— 等 trigger 脚本验 crashloop"
