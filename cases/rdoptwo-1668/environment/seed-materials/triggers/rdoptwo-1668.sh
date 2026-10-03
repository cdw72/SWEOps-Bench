#!/usr/bin/env bash
# RDOPTWO-1668 会话触发器 v4 (2026-08-29): 保真版 —— 真扩再缩 + 限流不传播
# + OOMKilled。
#
# 机制(issue #1668): HandlePVCResizing 对任何 PVC request 变更无条件 Update;
# apiserver 拒绝缩容(field can not be less than status.capacity)
# -> updateFailed -> 提前 return -> reconcile 全阻塞 -> 后续 CR 变更(如
# memory limit)永不传播。
#
# 保真要点(2026-08-29 实测,与 preseed v3 的差别):
#   * seed 已把 CR storageClassName 改为 standard(kind 自带 local-path),
#     SC 已加 allowVolumeExpansion -> 扩容 512Mi->1024Mi 的 Update 被
#     apiserver 放行 -> operator 成功、注解 storageCapacity=1073741824
#     由 operator 自己写入(非预置) -> PVC req 真到 1024Mi。
#   * 缩容 ->256Mi 时拒绝消息是 issue 原版 "field can not be less than
#     status.capacity";fix(PR #1669) desired < 注解 -> skip 恢复。
#   * 方向特异性还原:扩容成功、缩容失败 —— agent 可见 operator 处理扩容
#     正常、唯独缩容缺 guard 死循环(不再有"静态 PV 环境"误归因风险)。
#
# 配方:
#   A) CR storage 512Mi -> 1024Mi(真扩容):等 PVC req==1024Mi ×6 + 注解
#      1073741824 由 operator 写入(轮询成功才继续)
#   B) CR storage -> 256Mi:循环激活("resize pvc ... failed" +
#      "Cannot create statefulset"),buggy 循环 / fix skip
#   C) memory limit 512Mi -> 1Gi:buggy 不传播(pod 仍 512Mi);fix 传播
#   D) 写数据(redis-cli -x) -> buggy: heap 破 512Mi -> OOMKilled
#   E) 终态证据: OOMKilled/restarts + limit 漂移 + storage 漂移
#      (CR 256Mi vs PVC 1024Mi) + 循环日志
#
# 写入手法: redis-cli -x 值从 stdin 读(200KB+ argv 触发 "Argument list too
#   long");-c 跟随 MOVED;勿信 SET 返回,以 restarts 轮询为准。OOM 阈值
#   ~512Mi heap(节点盘 local-path,无 shmem 计费)。
#
# 用法: rdoptwo-1668.sh <kubeconfig>   (NS=CR 所在 ns / OP_NS=operator 所在 ns,
#   默认均 redis-operator;mini 手工集群可覆盖)
set -uo pipefail
KC="${1:?usage: rdoptwo-1668.sh <kubeconfig>}"
K=(kubectl --kubeconfig "$KC")
NS="${NS:-redis-operator}"
OP_NS="${OP_NS:-redis-operator}"
VAL_BYTES=1048576       # 1MiB value/key
BATCH=100               # 每批 key 数 (~100MiB/批,leader 得 ~1/3)
MAX_BATCHES=20          # 安全上限(~660Mi/leader,超 512Mi 必 OOM 早停)
ANNO=1073741824         # 预置注解值: "storage 曾扩到 1024Mi"

# ── 0) 连接性 + 等 CR Ready ─────────────────────────────────────────────
if ! "${K[@]}" get nodes --request-timeout=10s >/dev/null 2>&1; then
  echo "[trigger] FATAL: cluster unreachable via $KC" >&2; exit 1
fi
ST=""
for _ in $(seq 1 40); do
  ST=$("${K[@]}" -n "$NS" get rediscluster test-cluster -o jsonpath='{.status.state}' --request-timeout=10s 2>/dev/null || true)
  [ "$ST" = "Ready" ] && break
  sleep 15
done
[ "$ST" = "Ready" ] || { echo "[trigger] cluster not Ready (state=$ST)" >&2; exit 1; }

# ── A) CR storage 512Mi -> 1024Mi: 真扩容(注解由 operator 写入)──────────
echo "[trigger] A) storage 512Mi -> 1024Mi (real expand; operator writes annotation)"
"${K[@]}" -n "$NS" patch rediscluster test-cluster --type merge -p \
  '{"spec":{"storage":{"volumeClaimTemplate":{"spec":{"resources":{"requests":{"storage":"1024Mi"}}}}}}}' || exit 1
CNT=0
for i in $(seq 1 40); do
  REQS=$("${K[@]}" -n "$NS" get pvc -o jsonpath='{range .items[*]}{.spec.resources.requests.storage}{" "}{end}' 2>/dev/null)
  # apiserver 把 1024Mi 规范化存为 1Gi,两种写法都认(2026-08-29 实测)
  CNT=$(echo "$REQS" | tr ' ' '\n' | grep -cE '^(1024Mi|1Gi)$' || true)
  A1=$("${K[@]}" -n "$NS" get sts test-cluster-leader -o jsonpath='{.metadata.annotations.storageCapacity}' 2>/dev/null)
  [ "${CNT:-0}" -ge 6 ] && [ "$A1" = "$ANNO" ] && break
  sleep 10
done
echo "[trigger] after expand: PVC reqs=$REQS (count 1024Mi=$CNT); leader anno=${A1:-<missing>}"
[ "${CNT:-0}" -ge 6 ] || { echo "[trigger] expand did not complete (requests not 1024Mi; SC expandable?)" >&2; exit 1; }
[ "$A1" = "$ANNO" ] || { echo "[trigger] annotation not written by operator (expand failed?)" >&2; exit 1; }

# ── B) CR storage -> 256Mi: 错误循环激活(fix: desired<注解 -> skip)──────
echo "[trigger] B) storage 1024Mi -> 256Mi (activates HandlePVCResizing error loop)"
"${K[@]}" -n "$NS" patch rediscluster test-cluster --type merge -p \
  '{"spec":{"storage":{"volumeClaimTemplate":{"spec":{"resources":{"requests":{"storage":"256Mi"}}}}}}}' || exit 1
LOOP_OK=0
for i in $(seq 1 15); do
  HITS=$("${K[@]}" -n "$OP_NS" logs deploy/redis-operator --tail=300 --request-timeout=30s 2>/dev/null | grep -cE "resize pvc.*failed|Cannot create statefulset" || true)
  [ "${HITS:-0}" -ge 2 ] && { LOOP_OK=1; echo "[trigger] loop active (${HITS} hits)"; break; }
  sleep 10
done
[ "$LOOP_OK" = 1 ] || { echo "[trigger] no resize-pvc loop in operator log (fix image? skip active?)" >&2; exit 1; }

# ── C) memory limit 512Mi -> 1Gi;断言不传播(reconcile 被阻塞)───────────
echo "[trigger] C) memory limit 512Mi -> 1Gi (must NOT propagate while loop active)"
"${K[@]}" -n "$NS" patch rediscluster test-cluster --type merge -p \
  '{"spec":{"kubernetesConfig":{"resources":{"limits":{"memory":"1Gi"}}}}}' || exit 1
sleep 45
CR_LIM=$("${K[@]}" -n "$NS" get rediscluster test-cluster -o jsonpath='{.spec.kubernetesConfig.resources.limits.memory}')
POD_LIM=$("${K[@]}" -n "$NS" get pod test-cluster-leader-0 -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null)
echo "[trigger] CR limit=${CR_LIM} vs pod limit=${POD_LIM:-<none>}"
[ "$CR_LIM" = "1Gi" ] && [ "${POD_LIM:-}" = "512Mi" ] || {
  echo "[trigger] limit propagated (pod=$POD_LIM) -- loop not blocking reconcile, abort" >&2; exit 1; }

# ── D) 写数据直到 OOMKilled(redis-cli -x 避免 argv 超限)────────────────
echo "[trigger] D) writing data until heap > 512Mi -> OOMKilled (max ${MAX_BATCHES} batches)"
for B in $(seq 1 "$MAX_BATCHES"); do
  "${K[@]}" -n "$NS" exec test-cluster-leader-0 -- sh -c \
    'i=0; while [ $i -lt '"$BATCH"' ]; do head -c '"$VAL_BYTES"' /dev/zero | tr "\0" x | redis-cli -c -p 6379 -x SET "oom:'"$B"'-$i" >/dev/null 2>&1; i=$((i+1)); done' \
    >/dev/null 2>&1 || true
  RC=$("${K[@]}" -n "$NS" get pod test-cluster-leader-0 -o jsonpath='{.status.containerStatuses[0].restartCount}' 2>/dev/null || true)
  UM=$("${K[@]}" -n "$NS" exec test-cluster-leader-0 -- redis-cli -p 6379 INFO memory 2>/dev/null | grep '^used_memory:' | cut -d: -f2 | tr -d '\r')
  echo "[trigger] batch $B: restarts=${RC:-?} used=$(( ${UM:-0} / 1024 / 1024 ))Mi"
  [ "${RC:-0}" -ge 1 ] && { echo "[trigger] restart observed"; break; }
  # pod 已挂(exec 失败 used=0Mi)且曾接近阈值 -> 正在 OOM 重启,不再写
  if [ "${UM:-0}" -eq 0 ] 2>/dev/null && [ "$B" -ge 8 ]; then
    echo "[trigger] pod unreachable (OOM restart in progress); stopping writes"
    break
  fi
done

# ── E) 等 OOMKilled 签名 + 终态证据 ────────────────────────────────────
OK=0
for i in $(seq 1 30); do
  STATES=$("${K[@]}" -n "$NS" get pods -o \
    jsonpath='{range .items[*]}{.metadata.name}{": restarts="}{.status.containerStatuses[*].restartCount}{" lastTerm="}{.status.containerStatuses[*].lastState.terminated.reason}{"\n"}{end}' 2>/dev/null | grep test-cluster)
  echo "$STATES" | grep -qE "restarts=[1-9]" || { sleep 10; continue; }
  echo "$STATES" | grep -q "OOMKilled" && OK=1
  [ "$OK" = 1 ] && break
  sleep 10
done
echo "[trigger] pod states at verdict:"; echo "$STATES"
POD_LIM=$("${K[@]}" -n "$NS" get pod test-cluster-leader-0 -o jsonpath='{.spec.containers[0].resources.limits.memory}' 2>/dev/null)
CR_STOR=$("${K[@]}" -n "$NS" get rediscluster test-cluster -o jsonpath='{.spec.storage.volumeClaimTemplate.spec.resources.requests.storage}')
PVC_REQ=$("${K[@]}" -n "$NS" get pvc -o jsonpath='{.items[0].spec.resources.requests.storage}' 2>/dev/null)
LOOPS=$("${K[@]}" -n "$OP_NS" logs deploy/redis-operator --tail=500 --request-timeout=30s 2>/dev/null | grep -cE "resize pvc.*failed|Cannot create statefulset" || true)
echo "[trigger] evidence: CR limit=1Gi pod limit=${POD_LIM}; CR storage=${CR_STOR} PVC req=${PVC_REQ}; loop hits=${LOOPS}"
if [ "$OK" = 1 ]; then
  echo "[trigger] FAULT VERIFIED: OOMKilled + limit drift (CR 1Gi, pod ${POD_LIM})"
  exit 0
fi
echo "[trigger] WARN: no OOMKilled in 300s (write volume insufficient?)" >&2
exit 1
