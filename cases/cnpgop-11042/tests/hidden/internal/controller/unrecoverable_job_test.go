/*
Copyright © contributors to CloudNativePG, established as
CloudNativePG a Series of LF Projects, LLC.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    http://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.

SPDX-License-Identifier: Apache-2.0
*/

package controller

import (
	"context"
	"strings"
	"testing"

	batchv1 "k8s.io/api/batch/v1"
	corev1 "k8s.io/api/core/v1"
	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"

	"github.com/onsi/gomega"

	apiv1 "github.com/cloudnative-pg/cloudnative-pg/api/v1"
	"github.com/cloudnative-pg/cloudnative-pg/pkg/postgres"
)

// TestReconcileResourcesUnrecoverableJob —— 隐藏考题的**独立顶层入口**。
//
// 为什么不是 Ginkgo:旧考题写成 `var _ = Describe(...)`,和包内既有 spec 合起来
// 只报**一个** Go test 名 —— `TestAPIs`。而 P2P 的底账 `green.json` 里就有
// `internal/controller::TestAPIs` ⇒ 考题挂一次,P2P 就同时被记一次"原本绿的测试
// 回归了":**F2P 与 P2P 连坐**,一个失败算两笔账,而且 P2P 那条是假的。
// 改成普通 go test 之后它有自己的名字
// (`internal/controller::TestReconcileResourcesUnrecoverableJob`),
// 不在 P2P 底账里 ⇒ 挂了自己挂,F2P/P2P 解耦。
//
// 断言与旧考题逐条对应:reconcileResources 不报错;RequeueAfter > 0;
// CR 的 Status.Phase 落到 PhaseUnrecoverable;Status.PhaseReason 含那个 Job 的名。
//
// 注意 helper(`buildTestEnvironment` / `newFakeCNPGCluster` / `newFakeNamespace`)
// 是包内既有的测试辅助,内部用的是 Gomega 的**全局** Expect ⇒ 这里必须先注册失败
// 处理(即便成功路径上它不会被触发)。同包内 go test 是**顺序**跑的,覆盖全局
// handler 不会影响 `TestAPIs`(它自己开头会再注册一次)。
func TestReconcileResourcesUnrecoverableJob(t *testing.T) {
	gomega.RegisterFailHandler(func(message string, _ ...int) { t.Fatal(message) })
	ctx := context.Background()

	env := buildTestEnvironment()
	namespace := newFakeNamespace(env.client)

	cluster := newFakeCNPGCluster(env.client, namespace)
	// 一个撞到 backoffLimit 的 recovery Job(operator 建的那种)
	failedJob := batchv1.Job{
		ObjectMeta: metav1.ObjectMeta{
			Name:      cluster.Name + "-1-full-recovery",
			Namespace: namespace,
		},
		Status: batchv1.JobStatus{
			Failed: 7,
			Conditions: []batchv1.JobCondition{
				{Type: batchv1.JobFailed, Status: corev1.ConditionTrue, Reason: "BackoffLimitExceeded"},
			},
		},
	}

	resources := &managedResources{jobs: batchv1.JobList{Items: []batchv1.Job{failedJob}}}

	res, err := env.clusterReconciler.reconcileResources(
		ctx, cluster, resources, postgres.PostgresqlStatusList{})
	if err != nil {
		t.Fatalf("reconcileResources 不该报错,实得 %v", err)
	}
	if res.RequeueAfter <= 0 {
		t.Fatalf("RequeueAfter 应 > 0,实得 %v", res.RequeueAfter)
	}

	var updated apiv1.Cluster
	if err := env.client.Get(ctx,
		types.NamespacedName{Name: cluster.Name, Namespace: namespace}, &updated); err != nil {
		t.Fatalf("读回 CR 失败: %v", err)
	}
	if updated.Status.Phase != apiv1.PhaseUnrecoverable {
		t.Fatalf("Status.Phase 应为 %q,实得 %q",
			apiv1.PhaseUnrecoverable, updated.Status.Phase)
	}
	if !strings.Contains(updated.Status.PhaseReason, failedJob.Name) {
		t.Fatalf("Status.PhaseReason 应含 %q,实得 %q",
			failedJob.Name, updated.Status.PhaseReason)
	}
}
