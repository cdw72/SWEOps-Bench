#!/bin/bash
# vmop-1828 poll 注入:把「RBAC 缺席」**重建**出来。
#
# ## 为什么不能只 apply 一份 CR
#
# 故障本体(录制语料坐实,2026-09-02):VMAgent 带 `spec.ingestOnlyMode: true` 时,
# 算子**跳过**建那套给 config-reloader 用的 API-access RBAC ——
# 录制里就是一个 ClusterRole + 一个 ClusterRoleBinding,都叫
#   monitoring:default:vmagent-vmagent
#   buggy/rbac/{clusterroles,clusterrolebindings}.yaml : **没有**这两个对象
#   fixed/rbac/{clusterroles,clusterrolebindings}.yaml : 有(名字 diff 各多一行)
# 后果(buggy/container_logs/…-config-reloader.log:12-13 原文):
#   ... "Failed to watch" err="failed to list *v1.Secret: ... secrets
#   \"vmagent-vmagent\" is forbidden: User \"system:serviceaccount:
#   default:vmagent-vmagent\" cannot list resource \"secrets\" ..."
#   fatal … cannot get secret during init … is forbidden
# ⇒ config-reloader 起来就 fatal ⇒ CrashLoopBackOff ⇒ restartCount=2
#   (buggy/pods.json: ctr config-reloader restarts=2 ready=False)
#
# ## 老注入链为什么恒假(这案 `_status=mirror_failed` 的真因)
#
# poll 的健康相位先 apply `poll-healthy.yaml`(那份 CR **不带** ingestOnlyMode),
# 于是算子**正常建出**了那套 RBAC。故障步再 apply 带 ingestOnlyMode 的 CR 时,
# 算子只是「此后不再建」—— **它不会去删已经建出来的**。RBAC 还在 ⇒ reloader
# 读得到 secret ⇒ 一切正常 ⇒ restartCount 恒 0 ⇒ 探针(nonzero)永不开火。
# 这是**缺席型故障不可重入**(同族定性见 [[sweops-probe-authority-is-judge-not-signals]])。
# 探针本身是**对的** —— 读数是真 0 不是空读,恒假的从来是注入链。
#
# ## v2(2026-09-19 23:0x):v1 挂死在 finalizer 自锁,实测于 oracle 验证场
#
# v1 的 `kubectl delete clusterrolebinding`(没带 --wait=false)挂了 **19 分钟**,
# 集群侧证据:CRB 带 `apps.victoriametrics.com/finalizer` 进 Terminating
# (deletionTimestamp=14:23:27Z)后再也不动 —— 算子进了 ingestOnlyMode 就不再
# reconcile 这套 RBAC,**没人去摘它自己挂的 finalizer** ⇒ 对象永久 Terminating
# ⇒ kubectl 的客户端等待循环无限轮询。`--request-timeout=60s` 救不了:
# 它只管单次 HTTP 请求,不管等待循环。
# 这是 cassop-696 v1 的同族死法(那边是 pvc-protection finalizer),修法照搬
# 它 v2 的两步:**先 `delete --wait=false` 打上 deletionTimestamp(不阻塞),
# 再 `patch finalizers=null` 原子摘除** —— API server 在「已标记删除 + finalizer
# 清空」的同一事务里立即真删。必须先删后摘:反过来的话算子会在两步之间把
# finalizer 加回去。
#
# ## 步骤顺序的讲究
#
#   1. 先 apply(打开 ingestOnlyMode)—— 必须在摘 RBAC **之前**,否则算子下一次
#      reconcile 会把刚删的 RBAC 建回来。打开之后这套 RBAC 就成了「算子不会再
#      补」的东西,删掉才留得住。
#   2. 摘 RBAC(两步原子法,见上)。删之前**先查在不在**:不在说明健康相位没建出
#      来(注入前提没满足),报出来而不是静默当成功 —— 否则就是「删了个不存在的
#      对象」的空操作([[sweops-shell-guard-vacuous-grep-json]] 同族的空真)。
#   3. 删 pod(`--wait=false`)。**必须删** —— reloader 只在**启动时**读一次
#      secret,运行中的容器不会因为权限被摘就自杀。ReplicaSet 重建的新容器在
#      init 阶段撞 forbidden ⇒ fatal ⇒ CrashLoop ⇒ restartCount 开始爬。
set -euo pipefail

KC="${1:?usage: poll-inject.sh <kubeconfig>}"
NS=default
# 对象名由算子按 `monitoring:<ns>:<cr-name>` 生成,录制里就是这个字面量。
RBAC_NAME="monitoring:${NS}:vmagent-vmagent"
K=(kubectl --kubeconfig "$KC" --request-timeout=60s)

echo "[poll-inject] 1/3 打开 ingestOnlyMode(算子此后不会再补 RBAC)"
"${K[@]}" apply -f /seed-data/mutated-000.yaml

echo "[poll-inject] 2/3 摘掉健康相位建出来的那套 API-access RBAC(两步原子法)"
if "${K[@]}" get clusterrolebinding "$RBAC_NAME" >/dev/null 2>&1; then
  # 2a. 标记删除(不等待 —— 等,就是 v1 的死法:finalizer 无人摘,永久 Terminating)
  "${K[@]}" delete clusterrolebinding "$RBAC_NAME" --wait=false
  # 2b. 原子摘 finalizer → 已标记删除 + finalizer 清空 = 同一事务立即真删。
  #     失败不致命:留 Terminating 也挡不住 reloader 的 forbidden(权限已失效),
  #     下面的 pod 重建照样把故障做出来。
  "${K[@]}" patch clusterrolebinding "$RBAC_NAME" --type=merge \
    -p '{"metadata":{"finalizers":null}}' || true
else
  echo "[poll-inject] **警告**:$RBAC_NAME 本来就不存在 —— 健康相位没把它建出来," \
       "本步是空操作。注入前提没满足(要么健康相位没跑,要么算子版本变了)。" >&2
fi
# ClusterRole 同款两步(它带同一个 finalizer)。
"${K[@]}" delete clusterrole "$RBAC_NAME" --ignore-not-found --wait=false
"${K[@]}" patch clusterrole "$RBAC_NAME" --type=merge \
  -p '{"metadata":{"finalizers":null}}' || true

echo "[poll-inject] 3/3 删 pod 强制重建 → 新 config-reloader 读 secret 被拒 → CrashLoop"
"${K[@]}" -n "$NS" delete pod -l app.kubernetes.io/instance=vmagent --wait=false

echo "[poll-inject] 完成。预期:新 pod 的 config-reloader 反复重启,restartCount 由 0 开始爬。"
