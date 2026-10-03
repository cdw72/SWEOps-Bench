#!/usr/bin/env bash
# xtop-1067 显性化触发器 (K8SPXC-1067 / PR #1743)
#
# bug: updatePod (pkg/controller/pxc/upgrade.go) 重建期望 StatefulSet 时只手抄了
#   一份**部分字段表**(UpdateStrategy/annotations/replicas/securityContext/
#   imagePullSecrets/labels/SA/TLS hash...),**没有 nodeSelector**。于是
#   spec.haproxy.nodeSelector 只在 CREATE 路径(pkg/pxc/statefulset.go)生效,
#   之后改 CR 永远落不到 sts template -> 静默漂移。
# fix: #1743 把 updatePod 换成整份 pxc.StatefulSet() 重建 -> nodeSelector 随
#   CR 传播。
#
# 前置(seed 已落):
#   gen0 mutated-0: haproxy.nodeSelector {haproxy-role: old},节点在 gen0 之前就
#     带了该 label(n3 侧由 seed-materials/node-haproxy-role.yaml 作为
#     pre-manifest 打上;Acto 侧是 seed_case.py 的 PRE_SEED_NODE_LABELS)。
#   gen1 mutated-1: CR 改成 {haproxy-role: new}。
#     -> buggy: updatePod 不传播,sts template 仍是 old(= 漂移在位)
#     -> fixed: template 变成 new
#
# 触发动作(Acto 场景本体 = 管理员把旧节点下线):
#   1) 节点 relabel old -> new(等价于 drain:旧 selector 从此没有任何节点匹配)
#   2) 删掉 haproxy Pod 让 sts 按 template 重建
#   -> buggy: 新 Pod 带 selector old + 无匹配节点 -> Pending = FAULT VERIFIED
#   -> fixed: 新 Pod 带 selector new -> 落回同一节点 Running = 无故障(兼容)
#
# 断言只做"前置在不在位"(两侧共享),故障判别走**结果分类**:两侧都必须 exit 0,
# 否则 oracle/fixed 侧的 seed 会被自己的触发器判成失败(Pending 与 Running 是
# 判别量,不是前置条件)。
#
# 用法: xtop-1067.sh <kubeconfig>
set -uo pipefail
KC="${1:?usage: xtop-1067.sh <kubeconfig>}"
K=(kubectl --kubeconfig "$KC")
# Namespace: auto-detect(各 env 不一致:Acto 时代 acto-namespace,n3 种子可能
# 落别的 ns)。硬编码会让下面每条查询返回空 -> 前置断言误报。
# $SWEOPS_TRIGGER_NS 可覆盖。
NS="${SWEOPS_TRIGGER_NS:-}"
if [[ -z "$NS" ]]; then
  NS=$("${K[@]}" get perconaxtradbclusters.pxc.percona.com -A \
    -o jsonpath='{.items[0].metadata.namespace}' 2>/dev/null)
fi
[[ -z "$NS" ]] && NS=acto-namespace

STS=test-cluster-haproxy
CR=test-cluster
DEADLINE_SECS=420

# 0) 前置:CR 已经指向 new(gen1 已落地)。这一条 buggy/fixed 两侧都成立。
CRSEL=$("${K[@]}" -n "$NS" get perconaxtradbclusters.pxc.percona.com "$CR" \
  -o jsonpath='{.spec.haproxy.nodeSelector.haproxy-role}' 2>/dev/null)
echo "[trigger] baseline: CR haproxy.nodeSelector.haproxy-role='${CRSEL:-null}'"
if [[ "$CRSEL" != "new" ]]; then
  echo "[trigger] FAIL: CR haproxy nodeSelector != new(gen1 未落地)" >&2
  exit 1
fi

TMPL=$("${K[@]}" -n "$NS" get sts "$STS" \
  -o jsonpath='{.spec.template.spec.nodeSelector.haproxy-role}' 2>/dev/null)
echo "[trigger] drift check: sts template nodeSelector.haproxy-role='${TMPL:-null}' (old => buggy updatePod 未传播)"

# 1) 节点 relabel:旧的 haproxy-role 值被覆盖,旧 selector 从此无节点可匹配
NODE=$("${K[@]}" get nodes -o jsonpath='{.items[0].metadata.name}' 2>/dev/null)
if [[ -z "$NODE" ]]; then
  echo "[trigger] FAIL: 集群里没有节点" >&2
  exit 1
fi
echo "[trigger] relabelling node $NODE: haproxy-role=old -> new (drain 的等价物)"
if ! "${K[@]}" label node "$NODE" haproxy-role=new --overwrite >/dev/null 2>&1; then
  echo "[trigger] FAIL: kubectl label node rc!=0" >&2
  exit 1
fi

# 2) 删 haproxy Pod,让 sts 按自己的 template 重建
mapfile -t PODS < <("${K[@]}" -n "$NS" get pods -o name 2>/dev/null \
  | grep -E "^pod/${STS}-[0-9]+$")
if [[ ${#PODS[@]} -eq 0 ]]; then
  echo "[trigger] FAIL: 没找到 ${STS}-* Pod(触发输入不在位)" >&2
  exit 1
fi
echo "[trigger] deleting ${#PODS[@]} ${STS} pod(s): ${PODS[*]}"
"${K[@]}" -n "$NS" delete "${PODS[@]}" --wait=false >/dev/null 2>&1

# 3) 分类:等 readyReplicas 回到 3(fixed/无故障) vs 卡 Pending(buggy/有故障)
REPLICAS=$("${K[@]}" -n "$NS" get sts "$STS" \
  -o jsonpath='{.spec.replicas}' 2>/dev/null)
REPLICAS=${REPLICAS:-3}
DEADLINE=$((SECONDS + DEADLINE_SECS))
PHASES=""
while (( SECONDS < DEADLINE )); do
  READY=$("${K[@]}" -n "$NS" get sts "$STS" \
    -o jsonpath='{.status.readyReplicas}' 2>/dev/null)
  if [[ "${READY:-0}" == "$REPLICAS" ]]; then
    echo "[trigger] haproxy ${READY}/${REPLICAS} Ready -> fixed-compatible"
    echo "[trigger]   -- #1743 的 updatePod 把 nodeSelector 传到了 sts template,重建 Pod 落回新 label 节点,无故障"
    exit 0
  fi
  PHASES=$("${K[@]}" -n "$NS" get pods -o \
    jsonpath='{range .items[*]}{.metadata.name}={.status.phase} {end}' 2>/dev/null \
    | tr ' ' '\n' | grep -E "^${STS}-[0-9]+=" | tr '\n' ' ')
  sleep 5
done

# 4) 超时未 Ready:看是不是卡在 Pending(= stale selector 无节点匹配)
PENDING=$(grep -oE "${STS}-[0-9]+=Pending" <<<"$PHASES" | tr '\n' ' ')
MESSAGE=$("${K[@]}" -n "$NS" get pods -o \
  jsonpath='{range .items[*]}{.metadata.name}{"|"}{.status.conditions[?(@.type=="PodScheduled")].message}{"\n"}{end}' 2>/dev/null \
  | grep -E "^${STS}-[0-9]+\|" | head -3)
if [[ -n "$PENDING" ]]; then
  echo "[trigger] FAULT VERIFIED: ${PENDING}卡 Pending ${DEADLINE_SECS}s+"
  echo "[trigger]   sts template nodeSelector.haproxy-role='${TMPL:-null}', 节点现带 haproxy-role=new"
  echo "[trigger]   scheduling: ${MESSAGE//$'\n'/ | }"
  echo "[trigger]   -- 根因: updatePod(upgrade.go) 只抄部分 podSpec 字段,nodeSelector 不传播 -> CR 改了 sts 不变"
  exit 0
fi
echo "[trigger] INCONCLUSIVE: ${DEADLINE_SECS}s 内未 Ready 且无 Pending Pod; phases='${PHASES}'" >&2
echo "[trigger]   scheduling: ${MESSAGE//$'\n'/ | }" >&2
exit 1
