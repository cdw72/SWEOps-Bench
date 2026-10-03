// RabbitMQ Cluster Operator
//
// Copyright 2020 VMware, Inc. All Rights Reserved.
//
// This product is licensed to you under the Mozilla Public license, Version 2.0 (the "License").  You may not use this product except in compliance with the Mozilla Public License.
//
// This product may include a number of subcomponents with separate copyright notices and license terms. Your use of these subcomponents is subject to the terms and conditions of the subcomponent's license, as noted in the LICENSE file.
//

package resource_test

import (
	"testing"

	"github.com/onsi/ginkgo"
	. "github.com/onsi/gomega"

	rabbitmqv1beta1 "github.com/rabbitmq/cluster-operator/api/v1beta1"
	"github.com/rabbitmq/cluster-operator/internal/resource"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/runtime"
	defaultscheme "k8s.io/client-go/kubernetes/scheme"
)

// TestStatefulSetRejectsMismatchedSelectorOverride —— 隐藏考题的**独立顶层入口**。
//
// 为什么不是 Ginkgo:旧考题是 `StatefulSet Build Override` 里的一条 It,与包内
// upstream spec 合起来只报**一个** Go test 名 —— `internal/resource::TestResource`
// (同包 suite 的 RunSpecs),而 P2P 底账 `green.json` 里就有它 ⇒ 考题挂一次判官
// 记两笔:REG=1(F2P,该记)+ P2P=1(假回归)。挪成普通 go test 之后它有自己的名字
// (`internal/resource::TestStatefulSetRejectsMismatchedSelectorOverride`),不在
// P2P 底账里 ⇒ 挂了自己挂。
//
// ★ 手写而非"另起一个 RunSpecs":同包内 RunSpecs 只许调用一次(`TestResource`
//   已占),第二次调用整包 `go test` 会炸。断言逐条抄自原 spec:
//   Override 给的 selector 与 pod template 标签对不上时,`StatefulSet.Build()`
//   必须报错且错误里点名 `selector does not match`(修复落在
//   `internal/metadata/label.go`,`internal/resource/statefulset.go` 是调用方)。
//   本文件在被测 pin 上必须**失败**(buggy),打了 fix 之后必须**通过**。
func TestStatefulSetRejectsMismatchedSelectorOverride(t *testing.T) {
	RegisterFailHandler(ginkgo.Fail)

	// 原 spec 的 BeforeEach 就地展开(instance / scheme / builder / stsBuilder)。
	instance := generateRabbitmqCluster()
	scheme := runtime.NewScheme()
	Expect(rabbitmqv1beta1.AddToScheme(scheme)).To(Succeed())
	Expect(defaultscheme.AddToScheme(scheme)).To(Succeed())
	builder := &resource.RabbitmqResourceBuilder{
		Instance: &instance,
		Scheme:   scheme,
	}
	stsBuilder := builder.StatefulSet()

	builder.Instance.Spec.Override.StatefulSet = &rabbitmqv1beta1.StatefulSet{
		Spec: &rabbitmqv1beta1.StatefulSetSpec{
			Selector: &metav1.LabelSelector{
				MatchLabels: map[string]string{
					"my-label": "my-label",
				},
			},
		},
	}

	_, err := stsBuilder.Build()
	Expect(err).To(HaveOccurred())
	Expect(err.Error()).To(ContainSubstring("selector does not match"))
}
