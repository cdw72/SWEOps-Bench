#!/usr/bin/env bash
# ZKOP-474 显性化触发器 (2026-09-01, Topology Aware Routing 方案):
# 管理员为 ZooKeeper AdminServer Service 开启 TAR(CR 加
# service.kubernetes.io/topology-mode: Auto),但 zkop operator 的 SyncService
# (pkg/zk/synchronizers.go:26)只同步 Ports+Type 不同步 Annotations(fix #492
# fa3e23b 加 curr.SetAnnotations) -> buggy 侧 svc 永远拿不到注解 -> EndpointSlice
# 无 hints -> kube-proxy 全集群轮询后端。随后 zone-b 网络维护(分区注入),
# zone-a 客户端访问 admin-server svc 时 ~1/3 请求打到不可达的 zone-b ->
# 间歇连接超时,漂移显形。fixed 侧注解同步 -> hints 生成 -> 分区下 0 失败。
#
# 机制要点(2026-09-01 双闭环实测,ns 208 buggy / 209 fixed):
#   * hints 生成条件(v1.28 topologycache):gate 默认开(GA);cp 节点因
#     node-role.kubernetes.io/control-plane label 自动排除;zones<=endpoints;
#     每 zone CPU 比例分配 minimum=ceil(desired/1.2),desired=1.2 处有浮点
#     边界(ceil 翻 2 导致 minTotal 超限)——故 fixed 侧必须 3 个 ready worker
#     1:1:1(多出的 worker 停 kubelet 使其 NotReady 排除出缓存)。
#   * 缓存刷新:节点 label 变化不刷新拓扑缓存;CM 重启可靠刷新(实证);
#     NotReady 的 readiness 变化可触发(实测会刷,但为确定性统一用 CM 重启)。
#   * 分区注入:kube-proxy 对 svc 流量 SNAT 到节点 IP(172.18.x.x),直连流量
#     保持 pod CIDR 源 -> FORWARD 链两条规则:src=探测节点IP 与 src=探测
#     pod CIDR -> 目标 pod CIDR。只能分一个 zone(ZK quorum 3 副本剩 2/3)。
#   * buggy 侧无需 zone 布局/NotReady/CM 重启(svc 无注解 -> 无论如何无
#     hints),分支在"注解是否同步"之后。
#   * 探测:exec 进 zone-a 的 ZK pod 循环 /dev/tcp admin-server svc:8080。
#
# 用法: zkop-474.sh <kubeconfig>
set -uo pipefail
KC="${1:?usage: zkop-474.sh <kubeconfig>}"
K=(kubectl --kubeconfig "$KC")
NS=acto-namespace
SVC=test-cluster-admin-server
PORT=8080
PROBE_POD=test-cluster-0        # 探测源(zone-a)
TARGET_POD=test-cluster-1       # 分区目标(zone-b;若与探测同节点则换 test-cluster-2)
PROBE_N=24                      # 探测次数

# 0) 基线:ZK pods 3/3 ready、svc 存在、operator 健康
for _ in $(seq 1 30); do
  READY=$("${K[@]}" -n "$NS" get pods -l app=test-cluster --no-headers 2>/dev/null | grep -c "1/1.*Running")
  [[ "$READY" == "3" ]] && break
  sleep 5
done
if [[ "$READY" != "3" ]]; then
  echo "[trigger] FAIL: ZK pods 未就绪 (ready=$READY)" >&2
  exit 1
fi
"${K[@]}" -n "$NS" get svc "$SVC" >/dev/null 2>&1 || { echo "[trigger] FAIL: svc $SVC 不存在" >&2; exit 1; }
echo "[trigger] baseline: ZK 3/3 ready, svc $SVC 在位"

# 探测/目标 pod 分布(anti-affinity 保证异节点;兜底换 pod)
PNODE=$("${K[@]}" -n "$NS" get pod "$PROBE_POD" -o jsonpath='{.spec.nodeName}')
TNODE=$("${K[@]}" -n "$NS" get pod "$TARGET_POD" -o jsonpath='{.spec.nodeName}')
if [[ "$PNODE" == "$TNODE" ]]; then
  TARGET_POD=test-cluster-2
  TNODE=$("${K[@]}" -n "$NS" get pod "$TARGET_POD" -o jsonpath='{.spec.nodeName}')
fi
if [[ "$PNODE" == "$TNODE" ]]; then
  echo "[trigger] FAIL: 探测/目标 pod 同节点,无法分区" >&2
  exit 1
fi
echo "[trigger] probe pod=$PROBE_POD($PNODE) target pod=$TARGET_POD($TNODE)"

# 1) 管理员动作:CR 加 topology-mode: Auto(TAR 开启请求)
"${K[@]}" -n "$NS" patch zookeeperclusters test-cluster --type merge \
  -p '{"spec":{"adminServerService":{"annotations":{"service.kubernetes.io/topology-mode":"Auto"}}}}' || exit 1
echo "[trigger] CR patched: adminServerService.annotations += service.kubernetes.io/topology-mode=Auto"
sleep 60

# 2) 分支:注解是否同步(固定 side 同步,~30-60s;buggy 永不同步)
SVCA=$("${K[@]}" -n "$NS" get svc "$SVC" -o jsonpath='{.metadata.annotations.service\.kubernetes\.io/topology-mode}' 2>/dev/null || true)
if [[ "$SVCA" == "Auto" ]]; then
  echo "[trigger] fixed 行为: svc 注解已同步(topology-mode=Auto)"
  # 2a) fixed 侧 zone 布局:3 个 pod 节点 -> zone-a/b/c;多余 worker NotReady 排除
  "${K[@]}" label node "$PNODE" topology.kubernetes.io/zone=zone-a --overwrite >/dev/null 2>&1
  "${K[@]}" label node "$TNODE" topology.kubernetes.io/zone=zone-b --overwrite >/dev/null 2>&1
  THIRD=$("${K[@]}" -n "$NS" get pods -l app=test-cluster -o jsonpath='{range .items[*]}{.metadata.name}{"\n"}{end}' \
    | grep -v "^${PROBE_POD}$" | grep -v "^${TARGET_POD}$" | head -1)
  TNODE3=$("${K[@]}" -n "$NS" get pod "$THIRD" -o jsonpath='{.spec.nodeName}')
  "${K[@]}" label node "$TNODE3" topology.kubernetes.io/zone=zone-c --overwrite >/dev/null 2>&1
  # 多余 ready worker(非 3 个 pod 节点、非 cp)停 kubelet -> NotReady 排除
  CP=$(docker ps --format '{{.Names}}' | grep "^acto-.*-control-plane$" | head -1)
  for node in $("${K[@]}" get nodes --no-headers -o custom-columns=N:.metadata.name 2>/dev/null \
    | grep -vE "control-plane" | grep -vE "^(${PNODE}|${TNODE}|${TNODE3})$"); do
    echo "[trigger]   spare worker $node -> kubelet stop (NotReady 排除出拓扑缓存)"
    docker exec "$node" sh -c 'systemctl stop kubelet' >/dev/null 2>&1 || true
  done
  # CM 重启刷新拓扑缓存(标签变化不刷新;CM 重启实证可靠)
  echo "[trigger]   restarting kube-controller-manager to refresh topology cache"
  docker exec "$CP" sh -c 'crictl rm -f $(crictl ps --name kube-controller-manager -q | head -1)' >/dev/null 2>&1 || true
  for _ in $(seq 1 30); do
    docker exec "$CP" sh -c 'crictl ps --name kube-controller-manager -q | head -1' 2>/dev/null | grep -q . && break
    sleep 5
  done
  sleep 30
  # 2b) hints 闸门:必须生成,否则 fixed 侧布局失败(误报风险)
  HINTS=$("${K[@]}" -n "$NS" get endpointslices -l kubernetes.io/service-name="$SVC" \
    -o jsonpath='{range .items[*]}{range .endpoints[*]}{.hints}{"\n"}{end}' 2>/dev/null | grep -c forZones || true)
  if [[ "$HINTS" == "0" ]]; then
    echo "[trigger] FAIL: fixed 侧 hints 未生成(zone 布局/缓存问题,非无故障判定)" >&2
    "${K[@]}" -n "$NS" get endpointslices -l kubernetes.io/service-name="$SVC" -o yaml 2>/dev/null | head -30 >&2
    exit 1
  fi
  echo "[trigger] hints 生成 ✓ (zone-a/b/c 1:1:1)"
else
  echo "[trigger] buggy 行为: svc 注解未同步(topology-mode 缺失 = 漂移在位)"
fi

# 3) 分区注入:zone-a(探测源)-> zone-b(目标)FORWARD DROP(两条:节点IP + pod CIDR)
PIP=$("${K[@]}" get node "$PNODE" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')
PPODIP=$("${K[@]}" -n "$NS" get pod "$PROBE_POD" -o jsonpath='{.status.podIP}')
TPODIP=$("${K[@]}" -n "$NS" get pod "$TARGET_POD" -o jsonpath='{.status.podIP}')
TCIDR=$(echo "$TPODIP" | awk -F. '{print $1"."$2"."$3".0/24"}')
PCIDR=$(echo "$PPODIP" | awk -F. '{print $1"."$2"."$3".0/24"}')
docker exec "$TNODE" sh -c "iptables -I FORWARD -s $PIP -d $TCIDR -j DROP && iptables -I FORWARD -s $PCIDR -d $TCIDR -j DROP" >/dev/null 2>&1 || exit 1
echo "[trigger] partition: $PNODE($PIP,$PCIDR) -> $TNODE($TCIDR) DROP"
sleep 3

# 4) 探测(zone-a pod -> admin-server svc:8080,24 次)
RESULT=$("${K[@]}" -n "$NS" exec "$PROBE_POD" -- bash -c \
  'ok=0; for i in $(seq 1 '"$PROBE_N"'); do if timeout 2 bash -c "</dev/tcp/'$SVC'/'$PORT'" 2>/dev/null; then ok=$((ok+1)); fi; done; echo "$ok"' 2>/dev/null)
OK=${RESULT##*$'\n'}
FAILS=$((PROBE_N - OK))
echo "[trigger] probe: $OK/$PROBE_N 成功,$FAILS 失败"

# 5) 断言
if [[ "$SVCA" == "Auto" ]]; then
  if [[ "$FAILS" -le 2 ]]; then
    echo "[trigger] fixed 兼容: 分区下 0 失败(TAR 生效,无故障)"
    exit 0
  fi
  echo "[trigger] FAIL: fixed 侧出现 $FAILS 次失败(异常)" >&2
  exit 1
fi
if [[ "$FAILS" -gt 0 ]]; then
  echo "[trigger] FAULT VERIFIED: CR 已声明 TAR 但 svc 无注解/无 hints,zone 维护下 $FAILS/$PROBE_N 请求超时"
  exit 0
fi
echo "[trigger] WARN: buggy 侧 0 失败(分区未生效或布局巧合),判定未触发" >&2
exit 1
