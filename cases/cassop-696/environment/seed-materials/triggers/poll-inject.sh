#!/bin/bash
# cassop-696 poll 注入(v2 —— 修 v1 的**自死锁**,2026-09-17):
#
# 意图(不变):sts 按**名字**收养 PVC —— 把 rack1 的 data PVC 换成同名、
# 钉在永不绑定的 gp2 SC(2026-09-19 改名:旧名把评测身份写进了集群) 的那份,再让 pod 重建 → Pending forever。
#
# v1 的错:`kubectl delete pvc`(无 --wait=false)会被 `kubernetes.io/pvc-protection`
# finalizer 挂住 —— 该 finalizer 要求"没有 pod 在用这个 PVC"才放行,而唯一的持有者
# rack1-sts-0 正是下一步才要删的对象,且删 pod 那行在最后、被 `set -e` 挡在阻塞调用
# **之后** ⇒ 脚本必然挂到 trigger 超时。2026-09-17 两场 poll 实证:唯一失败真因就是
# `subprocess.TimeoutExpired ... poll-inject.sh ... after 1500 seconds`(16:43 起
# 现场进程表可见同一条 delete 挂了 12 分钟以上)。**不是**内存、不是算子。
#
# v2 的三处改动:
#   1. 先 `delete --wait=false` 打上 deletionTimestamp(**不阻塞**,这是关键);
#   2. 再 `patch finalizers=null` —— API server 在"已标记删除 + finalizer 清空"的
#      同一事务里立即真删。必须"先 delete 后 patch":反过来的话保护控制器会在两步
#      之间把 finalizer 加回去(它按 pod 引用持续 reconcile),就白摘了。
#   3. 删 pod 改 `--wait=false`:sts 会立刻重建它,我们不等它 —— 重建出来的 pod
#      认领的是第 3 步 apply 进去的 blocked PVC,于是在那里 Pending forever。
# 另加 `--request-timeout=60s`:任何一步 API 调用都不允许再无限期挂着。
set -euo pipefail
KC="$1"
NS=cass-operator
PVC=server-data-development-test-cluster-rack1-sts-0
POD=development-test-cluster-rack1-sts-0
K=(kubectl --kubeconfig "$KC" --request-timeout=60s -n "$NS")

# 1) 标记删除(不等待 —— 等就是 v1 的死法)
"${K[@]}" delete pvc "$PVC" --ignore-not-found --wait=false

# 2) 原子摘 finalizer → 立即真删。失败不致命:下面 apply 会顶出来报错。
"${K[@]}" patch pvc "$PVC" --type=merge -p '{"metadata":{"finalizers":null}}' || true

# 3) 同名 PVC 钉在永不绑定的 gp2 SC(2026-09-19 改名:旧名把评测身份写进了集群)(这一步同时兼作第 2 步的校验:
#    旧 PVC 若还在,apply 必报错,不会静默变成空操作)
kubectl --kubeconfig "$KC" --request-timeout=60s apply -f /seed-data/block-rack1.yaml

# 4) 删 pod 强制重建 → 新 pod 认领 blocked PVC → Pending forever
"${K[@]}" delete pod "$POD" --ignore-not-found --wait=false

# 5) 删 rack2/rack3 的 pod —— 恢复本场判据的**可判别性**(2026-09-23 加):
#    本案 GT(#777)动的是 `startOneNodePerRack`:buggy 版在**第一个起不来的 rack** 上直接
#    return,只有在"还有别的 rack 需要启动"时才与 fixed 分叉。而 poll 配方是**健康相位先
#    把三个 rack 全拉起来**再注入 ⇒ rack2/rack3 早已 Running,算子根本不需要再启任何节点
#    ⇒ buggy 与 fixed 行为同形 ⇒ 判官 precheck 两个探针都读到修复侧 ⇒ VACUOUS,REC 无从判起
#    (09-23 那场实证;archive 里 gold 修复的 oracle 场同样 VACUOUS ⇒ 与 agent 无关)。
#    删掉 rack2/rack3 的 pod 后,算子必须在"rack1 永不可启"的前提下重新启动这两个 rack:
#    buggy 在 rack1 处 return ⇒ rack2/rack3 起不回来(rack3 sts 0/1、DC 不 Healthy);
#    fixed 继续 RackLoop ⇒ 起回来(1/1、Healthy=True)⇒ 与 signals.json 的 grounding 同形。
#    本步只在注入时执行,k=0 健康相位不受影响。
for _r in rack2 rack3; do
  "${K[@]}" delete pod "development-test-cluster-${_r}-sts-0" --ignore-not-found --wait=false
done
