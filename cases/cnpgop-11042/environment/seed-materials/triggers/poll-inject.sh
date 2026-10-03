#!/bin/bash
# cnpgop-11042 poll 注入:删 Cluster 后重 apply 故障版。
# initdb Job 只在 bootstrap 创建(cluster_create.go:1206),对已 bootstrap 成功的
# 集群 patch options 不会重跑 -> 必须整个重建。
set -euo pipefail
KC="$1"
kubectl --kubeconfig "$KC" -n default delete cluster cluster --ignore-not-found
kubectl --kubeconfig "$KC" -n default wait --for=delete cluster/cluster --timeout=300s || true
kubectl --kubeconfig "$KC" -n default apply -f /seed-data/cr-11042.yaml
