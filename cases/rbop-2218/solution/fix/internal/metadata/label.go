// RabbitMQ Cluster Operator
//
// Copyright 2020 VMware, Inc. All Rights Reserved.
//
// This product is licensed to you under the Mozilla Public license, Version 2.0 (the "License").  You may not use this product except in compliance with the Mozilla Public License.
//
// This product may include a number of subcomponents with separate copyright notices and license terms. Your use of these subcomponents is subject to the terms and conditions of the subcomponent's license, as noted in the LICENSE file.
//

package metadata

import (
	"fmt"
	"strings"

	metav1 "k8s.io/apimachinery/pkg/apis/meta/v1"
	"k8s.io/apimachinery/pkg/labels"
)

type label map[string]string

func Label(instanceName string) label {
	return label{
		"app.kubernetes.io/name":      instanceName,
		"app.kubernetes.io/component": "rabbitmq",
		"app.kubernetes.io/part-of":   "rabbitmq",
	}
}

func GetLabels(instanceName string, instanceLabels map[string]string) label {
	allLabels := Label(instanceName)

	for label, value := range instanceLabels {
		if !strings.HasPrefix(label, "app.kubernetes.io") {
			allLabels[label] = value
		}
	}

	return allLabels
}

func LabelSelector(instanceName string) label {
	return label{
		"app.kubernetes.io/name": instanceName,
	}
}

// ValidateStatefulSetSelector ensures the given selector matches the instance's
// pod template labels; translated from upstream #2220 (2026-08-11) for the 0.8-era
// tree (maps.Copy -> manual loop, Go < 1.21).
func ValidateStatefulSetSelector(selector *metav1.LabelSelector, instanceName string, templateLabelOverrides map[string]string) error {
	if selector == nil {
		selector = &metav1.LabelSelector{MatchLabels: LabelSelector(instanceName)}
	}
	if len(selector.MatchLabels) == 0 && len(selector.MatchExpressions) == 0 {
		return fmt.Errorf("selector must not be empty")
	}
	s, err := metav1.LabelSelectorAsSelector(selector)
	if err != nil {
		return fmt.Errorf("invalid selector: %w", err)
	}
	templateLabels := map[string]string(Label(instanceName))
	for k, v := range templateLabelOverrides {
		templateLabels[k] = v
	}
	if !s.Matches(labels.Set(templateLabels)) {
		return fmt.Errorf("selector does not match the StatefulSet pod template labels %v; "+
			"add the missing labels via spec.override.statefulSet.spec.template.metadata.labels", templateLabels)
	}
	return nil
}
