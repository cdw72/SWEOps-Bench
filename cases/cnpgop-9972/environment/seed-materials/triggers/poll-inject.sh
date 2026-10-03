#!/bin/bash
# cnpgop-9972 poll 注入:删 Cluster 后重 apply 故障版(extension 卷名与内置
# pgdata 重名 -> Duplicate value,只在 podspec 重建时暴露)。
set -euo pipefail
KC="$1"
kubectl --kubeconfig "$KC" -n default delete cluster c --ignore-not-found
kubectl --kubeconfig "$KC" -n default wait --for=delete cluster/c --timeout=300s || true
kubectl --kubeconfig "$KC" -n default apply -f /seed-data/cr-9972.yaml
