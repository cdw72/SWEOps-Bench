#!/usr/bin/env bash
# logop-2172 显性化触发器 (kube-logging/logging-operator #2172 / PR #2173)
#
# bug: 6.3.1 pkg/resources/fluentbit/prometheusrules.go:33 --
#   maps.Copy(obj.Labels, r.fluentbitSpec.Metrics.PrometheusRulesLabels)
#   在 nil 判断**之前**无条件执行,而 nil 判断
#   (`r.fluentbitSpec.Metrics != nil && ...`) 在它之后。fluentd / syslogng 的
#   prometheusrules.go 同一处顺序错。helm chart 默认渲染的 FluentbitAgent 是
#   `spec: {}`(没有 metrics 段),只要 PrometheusRule CRD 在
#   (IsSupported(PrometheusRuleKey), logging_controller.go:118-131 的 List 成功),
#   fluentbit reconciler 就会把 r.prometheusRules 加进 objects 并 panic。
#   controller-runtime 会 recover 并 requeue -> 无限 panic 循环。
# fix: #2173 (f529c622, 6.3.2) 把 maps.Copy 移进 Metrics != nil 的守卫里。
#
# 前置(seed 已落,trigger 只断言"输入在位",不做故障判定):
#   - operator Deployment logop-logging-operator 已 Available(panic 是
#     reconcile 内 recover 的,进程不死,所以这个门槛在两侧都成立)
#   - FluentbitAgent logop-logging-operator 存在且 spec.metrics 为空(= nil 输入)
#   - PrometheusRule CRD 存在(= 上面 IsSupported 的必要条件)
#
# 判别(两侧都必须 exit 0,否则 fixed 侧会被自己的触发器判死):
#   buggy -> 日志里出现 "Observed a panic"(>=2 次)+ prometheusrules.go 的
#            nil pointer 栈 = FAULT VERIFIED
#   fixed -> 不出现 panic = 无故障(兼容)
# 判定纪律:smoke reward=1 不算过,要回看这一行是不是 FAULT VERIFIED。
#
# 用法: logop-2172.sh <kubeconfig>
set -uo pipefail
KC="${1:?usage: logop-2172.sh <kubeconfig>}"
K=(kubectl --kubeconfig "$KC")
NS="${SWEOPS_TRIGGER_NS:-default}"
DEPLOY=logop-logging-operator
FBA=logop-logging-operator
PROMCRD=prometheusrules.monitoring.coreos.com
DEADLINE_SECS=420

# 0) 前置
if ! "${K[@]}" -n "$NS" get deploy "$DEPLOY" >/dev/null 2>&1; then
  echo "[trigger] FAIL: deploy/$DEPLOY 不在 ns=$NS" >&2
  exit 1
fi
AVAIL=$("${K[@]}" -n "$NS" get deploy "$DEPLOY" \
  -o jsonpath='{.status.availableReplicas}' 2>/dev/null)
if [[ "${AVAIL:-0}" -lt 1 ]]; then
  echo "[trigger] FAIL: deploy/$DEPLOY 不可用 (availableReplicas=${AVAIL:-0})" >&2
  exit 1
fi
if ! "${K[@]}" -n "$NS" get fluentbitagent "$FBA" >/dev/null 2>&1; then
  echo "[trigger] FAIL: FluentbitAgent/$FBA 不在 ns=$NS" >&2
  exit 1
fi
METRICS=$("${K[@]}" -n "$NS" get fluentbitagent "$FBA" \
  -o jsonpath='{.spec.metrics}' 2>/dev/null)
if [[ -n "$METRICS" ]]; then
  echo "[trigger] FAIL: FluentbitAgent.spec.metrics 非空('$METRICS'),nil 输入不在位" >&2
  exit 1
fi
if ! "${K[@]}" get crd "$PROMCRD" >/dev/null 2>&1; then
  echo "[trigger] FAIL: $PROMCRD 不存在 -> IsSupported 为假,reconciler 不会走到 prometheusRules" >&2
  exit 1
fi
echo "[trigger] baseline: deploy/$DEPLOY available, FluentbitAgent.spec.metrics=<nil>, $PROMCRD present"

# 1) 等 panic 循环成形
DEADLINE=$((SECONDS + DEADLINE_SECS))
LOGS=""
PANICS=0
while (( SECONDS < DEADLINE )); do
  LOGS=$("${K[@]}" -n "$NS" logs "deploy/$DEPLOY" --tail=800 2>/dev/null)
  PANICS=$(grep -c "Observed a panic" <<<"$LOGS")
  (( PANICS >= 2 )) && break
  sleep 10
done

RESTARTS=$("${K[@]}" -n "$NS" get pods -l app.kubernetes.io/name=logging-operator \
  -o jsonpath='{.items[0].status.containerStatuses[0].restartCount}' 2>/dev/null)

if (( PANICS >= 2 )); then
  echo "[trigger] FAULT VERIFIED: operator panic 循环 (Observed a panic x$PANICS, restarts=${RESTARTS:-?})"
  grep -E "prometheusrules\.go|invalid memory address|nil pointer" <<<"$LOGS" | tail -3 | sed 's/^/[trigger]   /'
  echo "[trigger]   -- 根因: prometheusrules.go 的 maps.Copy(obj.Labels, Metrics.PrometheusRulesLabels) 在 Metrics nil 判断之前执行"
  exit 0
fi
if (( PANICS >= 1 )); then
  echo "[trigger] FAULT VERIFIED: operator panic (Observed a panic x$PANICS, restarts=${RESTARTS:-?})"
  grep -E "prometheusrules\.go|invalid memory address|nil pointer" <<<"$LOGS" | tail -3 | sed 's/^/[trigger]   /'
  exit 0
fi

echo "[trigger] no panic after ${DEADLINE_SECS}s -> fixed-compatible (无故障;buggy 侧若出现这行即为未复现)"
echo "[trigger]   last operator log lines:"
tail -15 <<<"$LOGS" | sed 's/^/[trigger]   /'
exit 0
