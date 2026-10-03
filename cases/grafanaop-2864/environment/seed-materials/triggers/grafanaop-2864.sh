#!/usr/bin/env bash
# grafanaop-2864 显性化触发器 (grafana/grafana-operator #2864 / PR #2865)
#
# bug: v5.24.0 controllers/client/dynamic_client.go:117 DynamicClient.Apply
#   先 Get 已有对象(判定 Create/Update),Update 时直接把**期望对象**原样送出去
#   —— 没有 obj.SetResourceVersion(existing.GetResourceVersion())。Grafana 的
#   App Platform API(*.grafana.app)带乐观并发校验,Update 不带 resourceVersion
#   一律被拒:
#     Provided version '' does not match current version: ...
#   -> reconcileWithInstance 报错 -> applyErrors 非空 ->
#      GrafanaManifest 条件 ManifestSynchronized=False reason=ApplyFailed,
#      controller 反复 requeue 但**永不恢复**(只有 Get 到对象后的 Update 路径会挂,
#      首次 Create 路径是好的,所以故障在"第二次起"才显形)。
# fix #2865 (4b43f730, v5.24.1+): Get 的返回值接进 existing,Update 前
#   obj.SetResourceVersion(existing.GetResourceVersion())。
#
# 触发器要做的是**把故障逼出来**并给出判决:
#   ① 建 GrafanaManifest(rt-2864, App Platform 资源 notifications.alerting
#      .grafana.app/v1beta1 RoutingTree)-> 首次 Create 必须成功
#      (ManifestSynchronized=True)。这一步失败说明 env 没搭到"故障前态",exit 1。
#   ② mutate 该 CR(spec.template.spec.routes 改 matcher 值)-> generation++ ->
#      reconciler 走 Apply 的 Update 分支。buggy 必挂,报 ApplyFailed。
#
# 前置(seed 已落 —— trigger 只断言"输入在位",不做故障判定):
#   1) operator Deployment 在 ns=grafana 且 availableReplicas>=1
#   2) grafana 实例 Deployment(grafana-deployment)在 ns=grafana 已 ready
#      —— 实例起不来时 App Platform API 不可达,两侧都会失败(空判别)
#   3) CRD grafanamanifests.grafana.integreatly.org 在位
#   这三条是 buggy/fixed 共享的输入,任何一条不成立就是 env 搭错了,直接 exit 1。
#
# 判别(两侧都必须 exit 0,否则 fixed 侧会被自己的触发器判死):
#   buggy -> 条件 reason=ApplyFailed 且/或 operator 日志
#            "does not match current version"                    = FAULT VERIFIED
#   fixed -> 条件回到 True 且 observedGeneration==generation     = 无故障(兼容)
# 判定纪律:smoke reward=1 不算过,要回看这一行是不是 FAULT VERIFIED。
#
# 用法: grafanaop-2864.sh <kubeconfig>
set -uo pipefail
KC="${1:?usage: grafanaop-2864.sh <kubeconfig>}"
K=(kubectl --kubeconfig "$KC")
OPNS=grafana
OPDEP=grafana-operator-controller-manager
NS="${SWEOPS_TRIGGER_NS:-grafana}"
INST=grafana-deployment
MAN=rt-2864
DEADLINE_INITIAL=420
DEADLINE_FAIL=300
MANIFEST_YAML="$(mktemp)"
trap 'rm -f "$MANIFEST_YAML"' EXIT

cat >"$MANIFEST_YAML" <<'YAML'
apiVersion: grafana.integreatly.org/v1beta1
kind: GrafanaManifest
metadata:
  name: rt-2864
spec:
  instanceSelector:
    matchLabels:
      instance: grafana
  template:
    apiVersion: notifications.alerting.grafana.app/v1beta1
    kind: RoutingTree
    metadata:
      name: rt-2864
    spec:
      defaults:
        receiver: empty
      routes:
        - matchers:
            - type: "="
              label: severity
              value: critical
          receiver: empty
YAML

# 0) 前置 —— 三条共享输入必须在位
if ! "${K[@]}" -n "$OPNS" get deploy "$OPDEP" >/dev/null 2>&1; then
  echo "[trigger] FAIL: deploy/$OPDEP 不在 ns=$OPNS" >&2
  exit 1
fi
OPAVAIL=$("${K[@]}" -n "$OPNS" get deploy "$OPDEP" \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
if [[ "${OPAVAIL:-0}" -lt 1 ]]; then
  echo "[trigger] FAIL: operator 未就绪 (ns=$OPNS available=${OPAVAIL:-0})" >&2
  exit 1
fi
if ! "${K[@]}" get crd grafanamanifests.grafana.integreatly.org >/dev/null 2>&1; then
  echo "[trigger] FAIL: grafanamanifests.grafana.integreatly.org 不在 -> env 搭错" >&2
  exit 1
fi
INSTREADY=$("${K[@]}" -n "$NS" get deploy "$INST" \
  -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
if [[ "${INSTREADY:-0}" -lt 1 ]]; then
  echo "[trigger] FAIL: grafana 实例 deploy/$INST 未 ready (ns=$NS ready=${INSTREADY:-0})" >&2
  exit 1
fi
echo "[trigger] baseline: operator available=$OPAVAIL, $INST ready=$INSTREADY, GrafanaManifest CRD present"

cond() { # cond <field> -> status/reason/message 单值
  "${K[@]}" -n "$NS" get grafanamanifest "$MAN" \
    -o jsonpath="{.status.conditions[?(@.type==\"ManifestSynchronized\")].$1}" 2>/dev/null
}
gen() { "${K[@]}" -n "$NS" get grafanamanifest "$MAN" \
    -o jsonpath='{.metadata.generation}' 2>/dev/null; }

# 1) 建立"故障前态":首次 Create 必须成功
"${K[@]}" -n "$NS" apply -f "$MANIFEST_YAML" >/dev/null 2>&1 || {
  echo "[trigger] FAIL: GrafanaManifest 应用失败(env 搭错)" >&2; exit 1; }
DEADLINE=$((SECONDS + DEADLINE_INITIAL))
INIT_OK=0
while (( SECONDS < DEADLINE )); do
  [[ "$(cond status)" == "True" ]] && { INIT_OK=1; break; }
  sleep 10
done
if (( INIT_OK != 1 )); then
  echo "[trigger] INCONCLUSIVE: 首次同步未成功 (status=$(cond status) reason=$(cond reason) msg=$(cond message))" >&2
  echo "[trigger]   env 没到故障前态,无法判定 —— 不要当成 fixed-compatible" >&2
  exit 1
fi
G0=$(gen)
echo "[trigger] initial sync OK (generation=$G0, Create 路径正常)"

# 2) mutate -> generation++ -> 走 Update 路径
if ! "${K[@]}" -n "$NS" patch grafanamanifest "$MAN" --type merge \
     -p '{"spec":{"template":{"spec":{"routes":[{"matchers":[{"type":"=","label":"severity","value":"warning"}],"receiver":"empty"}]}}}}' \
     >/dev/null 2>&1; then
  echo "[trigger] FAIL: mutate GrafanaManifest 失败(env 搭错)" >&2
  exit 1
fi
G1=$(gen)
echo "[trigger] mutated -> generation=$G1; waiting for ApplyFailed ..."

DEADLINE=$((SECONDS + DEADLINE_FAIL))
LOGS=""
FAILED=0
while (( SECONDS < DEADLINE )); do
  RSN="$(cond reason)"
  if [[ "$RSN" == "ApplyFailed" ]]; then FAILED=1; break; fi
  if [[ "$RSN" == "ApplySuccessful" && "$(cond observedGeneration)" == "$G1" ]]; then
    break   # Update 成功且已追上新一代 -> fixed 侧
  fi
  LOGS=$("${K[@]}" -n "$OPNS" logs "deploy/$OPDEP" --tail=300 2>/dev/null)
  if grep -q "does not match current version" <<<"$LOGS"; then FAILED=1; break; fi
  sleep 10
done

if (( FAILED == 1 )); then
  MSG="$(cond message)"
  echo "[trigger] FAULT VERIFIED: GrafanaManifest 更新被拒 (reason=ApplyFailed, generation=$G1)"
  [[ -n "$MSG" ]] && echo "[trigger]   condition message: ${MSG:0:200}"
  echo "$LOGS" | grep -E "does not match current version|failed to sync CR to all Grafana instances" \
    | tail -3 | sed 's/^/[trigger]   /'
  echo "[trigger]   -- 根因: DynamicClient.Apply 的 Update 分支没带 existing.resourceVersion -> App Platform 乐观并发全拒"
  exit 0
fi

# 没挂:只有"mutate 后的新一代确实被成功 apply"才算 fixed-compatible;
# 状态没收敛(既不是 ApplyFailed 也不是追上新 generation)一律 INCONCLUSIVE,
# 否则一个坏 env 会在 buggy 侧空过。
ST="$(cond status)"; RSN="$(cond reason)"; OG="$(cond observedGeneration)"; GN="$(gen)"
if [[ "$ST" == "True" && "$RSN" == "ApplySuccessful" && "$OG" == "$GN" ]]; then
  echo "[trigger] no ApplyFailed -> fixed-compatible (ApplySuccessful, observedGeneration=$OG;buggy 侧出现这行即为未复现)"
  exit 0
fi
echo "[trigger] INCONCLUSIVE: 既未 ApplyFailed 也未追上新 generation (status=$ST reason=$RSN observedGeneration=$OG generation=$GN)" >&2
tail -15 <<<"$LOGS" | sed 's/^/[trigger]   /' >&2
exit 1
