#!/bin/bash
# otelop-5275 poll 注入:apply 假 Route CRD + 重启算子 pod。
# NP 只在 manager 启动期创建 —— 不重启则注入不生效(判定表 ⚠ 条款)。
set -euo pipefail
KC="$1"
kubectl --kubeconfig "$KC" apply -f /seed-data/route-openshift-io-dummy.yaml
kubectl --kubeconfig "$KC" -n opentelemetry-operator-system rollout restart \
  deployment -l app.kubernetes.io/name=opentelemetry-operator
