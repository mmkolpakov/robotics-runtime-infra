package model_artifact

import rego.v1

manifest := object.get(input, "manifest", {})
observations := object.get(input, "observations", {})
source := object.get(manifest, "source", {})
target := object.get(manifest, "target", {})
build := object.get(manifest, "build", {})
conformance := object.get(manifest, "numerical_conformance", {})
compatibility := object.get(manifest, "compatibility", {})
report := object.get(observations, "conformance_report", {})
runtime := object.get(observations, "runtime", {})
hardware := object.get(observations, "hardware", {})

deny contains "manifest must use model-artifact-manifest.v1" if {
	object.get(manifest, "schema_version", "") != "model-artifact-manifest.v1"
}

deny contains "observed source digest does not match manifest" if {
	object.get(observations, "source_artifact_sha256", "") != object.get(source, "sha256", "")
}

deny contains "observed target digest does not match manifest" if {
	object.get(observations, "target_artifact_sha256", "") != object.get(target, "sha256", "")
}

deny contains "observed conformance report digest does not match manifest" if {
	object.get(report, "sha256", "") != object.get(conformance, "report_sha256", "")
}

deny contains "observed reference artifact digest does not match manifest" if {
	object.get(report, "reference_artifact_sha256", "") != object.get(conformance, "reference_artifact_sha256", "")
}

deny contains "numerical conformance did not pass" if {
	object.get(report, "status", "") != "passed"
}

deny contains "numerical conformance manifest is not passed" if {
	object.get(conformance, "passed", false) != true
}

deny contains "provider fallback was observed" if {
	object.get(report, "fallback_count", -1) != 0
}

deny contains "executed provider does not match target provider" if {
	expected := object.get(target, "execution_provider", "")
	object.get(report, "executed_providers", []) != [expected]
}

deny contains "observed runtime family does not match target" if {
	object.get(runtime, "family", "") != object.get(target, "runtime_family", "")
}

deny contains "observed runtime version does not match target" if {
	object.get(runtime, "version", "") != object.get(target, "runtime_version", "")
}

deny contains "observed architecture does not match target" if {
	object.get(runtime, "architecture", "") != object.get(target, "target_architecture", "")
}

deny contains "portable artifacts must not declare hardware compatibility" if {
	object.get(compatibility, "portable", false) == true
	count(object.get(compatibility, "hardware", [])) != 0
}

deny contains "non-portable artifact has no exact hardware match" if {
	object.get(compatibility, "portable", true) == false
	not compatible_hardware
}

deny contains "quantized artifact has no calibration dataset digest" if {
	quantized
	object.get(build, "calibration_dataset_sha256", "") == ""
}

deny contains "RKNN artifact must target the RKNN 2.3.2 runtime" if {
	object.get(target, "format", "") == "rknn"
	object.get(target, "runtime_family", "") != "rknn_runtime"
}

deny contains "RKNN artifact must target the RKNN 2.3.2 runtime" if {
	object.get(target, "format", "") == "rknn"
	object.get(target, "runtime_version", "") != "2.3.2"
}

deny contains "RKNN artifact must execute on RKNPU2" if {
	object.get(target, "format", "") == "rknn"
	object.get(target, "execution_provider", "") != "RKNPU2"
}

deny contains "RKNN artifact must target aarch64" if {
	object.get(target, "format", "") == "rknn"
	object.get(target, "target_architecture", "") != "aarch64"
}

deny contains "RKNN artifact requires an observed RK3588" if {
	object.get(target, "format", "") == "rknn"
	object.get(hardware, "vendor", "") != "rockchip"
}

deny contains "RKNN artifact requires an observed RK3588" if {
	object.get(target, "format", "") == "rknn"
	object.get(hardware, "soc", "") != "rk3588"
}

deny contains "TensorRT engine requires an exact device family and compute capability" if {
	object.get(target, "format", "") == "tensorrt_engine"
	not tensorrt_hardware_match
}

compatible_hardware if {
	some expected in object.get(compatibility, "hardware", [])
	hardware_matches(expected, hardware)
}

tensorrt_hardware_match if {
	some expected in object.get(compatibility, "hardware", [])
	object.get(expected, "vendor", "") == "nvidia"
	object.get(expected, "device_family", "") == object.get(hardware, "device_family", "")
	object.get(expected, "compute_capability", "") != ""
	object.get(expected, "compute_capability", "") == object.get(hardware, "compute_capability", "")
	hardware_matches(expected, hardware)
}

hardware_matches(expected, actual) if {
	object.get(expected, "vendor", "") == object.get(actual, "vendor", "")
	object.get(expected, "device_family", "") == object.get(actual, "device_family", "")
	optional_field_matches(expected, actual, "soc")
	optional_field_matches(expected, actual, "compute_capability")
	optional_field_matches(expected, actual, "driver_version")
}

optional_field_matches(expected, _, field) if {
	object.get(expected, field, null) == null
}

optional_field_matches(expected, actual, field) if {
	expected_value := object.get(expected, field, null)
	expected_value != null
	expected_value == object.get(actual, field, null)
}

quantized if {
	object.get(target, "precision", "") == "int8"
}

quantized if {
	object.get(target, "precision", "") == "uint8"
}
