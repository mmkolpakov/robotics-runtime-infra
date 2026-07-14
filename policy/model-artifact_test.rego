package model_artifact_test

import data.model_artifact
import rego.v1

test_valid_rknn_artifact_is_allowed if {
	violations := model_artifact.deny with input as data.model_artifact_valid
	count(violations) == 0
}

test_valid_tensorrt_artifact_is_allowed if {
	violations := model_artifact.deny with input as data.model_artifact_tensorrt
	count(violations) == 0
}

test_tampered_target_is_denied if {
	candidate := object.union(data.model_artifact_valid, data.model_artifact_tampered_target)
	violations := model_artifact.deny with input as candidate
	"observed target digest does not match manifest" in violations
}

test_tampered_report_is_denied if {
	candidate := object.union(data.model_artifact_valid, data.model_artifact_tampered_report)
	violations := model_artifact.deny with input as candidate
	"observed conformance report digest does not match manifest" in violations
}

test_wrong_hardware_is_denied if {
	candidate := object.union(data.model_artifact_valid, data.model_artifact_wrong_hardware)
	violations := model_artifact.deny with input as candidate
	"non-portable artifact has no exact hardware match" in violations
	"RKNN artifact requires an observed RK3588" in violations
}

test_failed_parity_is_denied if {
	candidate := object.union(data.model_artifact_valid, data.model_artifact_failed_parity)
	violations := model_artifact.deny with input as candidate
	"numerical conformance did not pass" in violations
}

test_wrong_tensorrt_compute_capability_is_denied if {
	candidate := object.union(data.model_artifact_tensorrt, data.model_artifact_wrong_compute_capability)
	violations := model_artifact.deny with input as candidate
	"non-portable artifact has no exact hardware match" in violations
	"TensorRT engine requires an exact device family and compute capability" in violations
}

test_quantized_artifact_without_calibration_is_denied if {
	candidate := object.union(data.model_artifact_valid, {"manifest": {"build": {"calibration_dataset_sha256": ""}}})
	violations := model_artifact.deny with input as candidate
	"quantized artifact has no calibration dataset digest" in violations
}
