/*
Copyright 2024 The Kubeflow authors.

Licensed under the Apache License, Version 2.0 (the "License");
you may not use this file except in compliance with the License.
You may obtain a copy of the License at

    https://www.apache.org/licenses/LICENSE-2.0

Unless required by applicable law or agreed to in writing, software
distributed under the License is distributed on an "AS IS" BASIS,
WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
See the License for the specific language governing permissions and
limitations under the License.
*/

package util_test

import (
	"testing"

	. "github.com/onsi/gomega"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/utils/ptr"

	"github.com/kubeflow/spark-operator/v2/api/v1beta2"
	"github.com/kubeflow/spark-operator/v2/pkg/util"
)

// TestGetExecutorRequestResourceInitialExecutorCount —— 隐藏考题的**独立顶层入口**。
//
// 为什么不是 Ginkgo:旧考题在这条 Context 里
//   `Context("when Executor.Instances is nil (dynamic allocation enabled)")`
// 与包内 104 条 upstream spec 合起来只报**一个** Go test 名 —— `pkg/util::TestUtil`,
// 而 P2P 底账 `green.json` 里就有它 ⇒ 考题挂一次判官记两笔:REG=1(F2P,该记)
// + P2P=1(假回归,实测 `[suite] 1 baseline-green test(s) no longer pass:
// FAIL .../pkg/util::TestUtil`)。挪成普通 go test 之后它有自己的名字
// (`pkg/util::TestGetExecutorRequestResourceInitialExecutorCount`),不在 P2P
// 底账里 ⇒ 挂了自己挂。
//
// 断言与原 spec 逐条对应(`SetSparkApplicationDefaults` 之后 Instances 仍为 nil
// ⇒ `GetExecutorRequestResource` 不许 panic、且仍要给出非空资源清单)。
// helper 侧用的是 Gomega 的**全局** Expect(本文件沿用 dot-import 的写法),
// 故先注册失败处理;同包 go test 顺序执行,覆盖全局 handler 不影响 `TestUtil`。
func TestGetExecutorRequestResourceInitialExecutorCount(t *testing.T) {
	RegisterFailHandler(func(message string, _ ...int) { t.Fatal(message) })

	app := &v1beta2.SparkApplication{
		ObjectMeta: metav1.ObjectMeta{
			Name:      "test-app",
			Namespace: "test-namespace",
		},
		Spec: v1beta2.SparkApplicationSpec{
			DynamicAllocation: &v1beta2.DynamicAllocation{
				Enabled:      true,
				MinExecutors: ptr.To[int32](1),
				MaxExecutors: ptr.To[int32](10),
			},
			Executor: v1beta2.ExecutorSpec{
				SparkPodSpec: v1beta2.SparkPodSpec{
					Cores:  ptr.To[int32](1),
					Memory: ptr.To("1g"),
				},
			},
		},
	}

	v1beta2.SetSparkApplicationDefaults(app)
	Expect(app.Spec.Executor.Instances).To(BeNil())
	Expect(func() { util.GetExecutorRequestResource(app) }).NotTo(Panic())
	resources := util.GetExecutorRequestResource(app)
	Expect(resources).NotTo(BeEmpty())
}
