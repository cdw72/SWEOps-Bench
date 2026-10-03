#!/bin/bash
# k8ssand-1023 poll 注入:复刻关1 的“先有 CA keystore、再建 CDC”顺序。
# 预建 CA keystore 存在 -> retrieveInternodeCredentialSecretOrCreateDefault
# 不再生成 <dc>-keystore,而 sts 的 encryption-cred-storage 卷引用的正是它
# -> FailedMount/Pending。pre 相位跳过了这个 pre-manifest(见 poll_skip_pre)。
set -euo pipefail
KC="$1"
kubectl --kubeconfig "$KC" -n default apply -f /seed-data/cassandra-datacenter-ca-keystore.yaml
kubectl --kubeconfig "$KC" -n default apply -f /seed-data/cdc-1.yaml
