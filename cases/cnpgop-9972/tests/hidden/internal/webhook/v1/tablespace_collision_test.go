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

package v1

import (
	"testing"

	. "github.com/onsi/gomega"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/util/validation/field"

	apiv1 "github.com/cloudnative-pg/cloudnative-pg/api/v1"
)

// TestTablespaceNamesCollideAfterSanitization —— 隐藏考题的**独立顶层入口**。
//
// 为什么不是 Ginkgo:旧考题是 `Describe("Tablespaces validation")` 里的一条 It,
// 与包内 376 条 upstream spec 合起来只报**一个** Go test 名
// `internal/webhook/v1::TestAPIs`,而 P2P 底账 green.json 里就有它 ⇒ 考题挂一次
// 判官记两笔:REG=1(F2P,该记)+ P2P=1(假回归,实测 `[suite] 1 baseline-green
// test(s) no longer pass: FAIL .../internal/webhook/v1::TestAPIs`)。
// 换成普通 go test 之后它有自己的名字
// (`internal/webhook/v1::TestTablespaceNamesCollideAfterSanitization`),
// 不在 P2P 底账里 ⇒ 挂了自己挂。
//
// 断言与原 spec 逐条对应:两个 sanitize 之后同名的 tablespace(`foo_bar` 与
// `foo$bar`)必须恰好报**一条** invalid 错,detail 里点名 `duplicate volume name`。
// 原 spec 的 `v` 来自 Describe 的 BeforeEach(`&ClusterCustomValidator{}`),
// `createFakeTemporaryTbsConf` 是 Describe 内的闭包 —— 这里各自在函数体内就地展开,
// 免得依赖别的 spec 的作用域。
func TestTablespaceNamesCollideAfterSanitization(t *testing.T) {
	RegisterFailHandler(func(message string, _ ...int) { t.Fatal(message) })

	v := &ClusterCustomValidator{}
	tbs := func(name string) apiv1.TablespaceConfiguration {
		return apiv1.TablespaceConfiguration{
			Name: name,
			Storage: apiv1.StorageConfiguration{
				Size: "10Gi",
			},
		}
	}

	cluster := &apiv1.Cluster{
		ObjectMeta: metav1.ObjectMeta{
			Name: "cluster1",
		},
		Spec: apiv1.ClusterSpec{
			Instances: 3,
			StorageConfiguration: apiv1.StorageConfiguration{
				Size: "10Gi",
			},
			Tablespaces: []apiv1.TablespaceConfiguration{
				tbs("foo_bar"),
				tbs("foo$bar"),
			},
		},
	}
	errors := v.validate(cluster)
	Expect(errors).To(HaveLen(1))
	Expect(errors[0].Type).To(Equal(field.ErrorTypeInvalid))
	Expect(errors[0].Detail).To(ContainSubstring("duplicate volume name"))
}
