#!/bin/bash
# vmop-1802 poll 注入:把整块 remoteWrite 灌回去。
# 必须 --type=merge —— kubectl apply 会把 431KB 对象塞进
# kubectl.kubernetes.io/last-applied-configuration,撞 apiserver 的 262144B
# 注解上限,连 patch 都发不出去(关1 seed.py 的 step["create"] 同理绕开)。
set -euo pipefail
KC="$1"
kubectl --kubeconfig "$KC" -n default patch vmagent vmagent \
  --type=merge --patch-file /seed-data/poll-fault-patch.json
