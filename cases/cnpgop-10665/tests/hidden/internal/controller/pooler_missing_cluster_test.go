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
	"testing"
	"time"

	. "github.com/onsi/gomega"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/types"
	ctrl "sigs.k8s.io/controller-runtime"

	apiv1 "github.com/cloudnative-pg/cloudnative-pg/api/v1"
)

// TestPoolerReconcileMissingClusterRequeues —— 隐藏考题的**独立顶层入口**。
//
// 为什么不是 Ginkgo:旧考题是 `pooler_controller unit tests` 里的一条 It,与包内
// 313 条 upstream spec 合起来只报**一个** Go test 名
// `internal/controller::TestAPIs`,而 P2P 底账 green.json 里就有它 ⇒ 考题挂一次
// 判官记两笔:REG=1(F2P,该记)+ P2P=1(假回归)。换成普通 go test 之后它有自己的
// 名字(`internal/controller::TestPoolerReconcileMissingClusterRequeues`),
// 不在 P2P 底账里 ⇒ 挂了自己挂。
//
// ★ 这条考题在 buggy 树上是**panic** 不是断言失败,所以必须自带 recover:
//   普通 go test 里一个没被 recover 的 panic 会**掀掉整个测试二进制**,
//   于是 P2P 那一场(在同一个 /operator-src 上后跑)里
//   `TestAPIs` 连"通过"都报不出来 ⇒ 假回归又从后门回来了。
//   Ginkgo 的 spec 是自带 recover 的(所以旧形态只报一只 PANICKED),普通 go test
//   没有。defer+recover 把它降级成"这条测试红",整包照跑完。
//
// 断言与原 spec 逐条对应:引用的 Cluster 没落库(= 已被删)时,Reconcile 不报错、
// 不 panic,并把 RequeueAfter 设为 30s。
func TestPoolerReconcileMissingClusterRequeues(t *testing.T) {
	RegisterFailHandler(func(message string, _ ...int) { t.Fatal(message) })

	defer func() {
		if r := recover(); r != nil {
			t.Errorf("Reconcile panicked on a Pooler whose Cluster is missing: %v", r)
		}
	}()

	env := buildTestEnvironment()
	ctx := context.Background()
	namespace := newFakeNamespace(env.client)

	// cluster is intentionally not persisted: the Pooler references
	// a Cluster that does not exist (e.g., it has been deleted while
	// the Pooler still existed).
	cluster := &apiv1.Cluster{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "missing-cluster",
			Namespace: namespace,
		},
	}
	pooler := newFakePooler(env.client, cluster)

	result, err := env.poolerReconciler.Reconcile(ctx, ctrl.Request{
		NamespacedName: types.NamespacedName{
			Name:      pooler.Name,
			Namespace: pooler.Namespace,
		},
	})
	Expect(err).ToNot(HaveOccurred())
	Expect(result.RequeueAfter).To(Equal(30 * time.Second))
}
