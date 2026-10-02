#!/usr/bin/env python3
"""Bind an observed OpenVINO execution to the installed model's contract."""

from __future__ import annotations

import argparse
import json
from hashlib import sha256
from pathlib import Path, PurePosixPath

from robotics_runtime_contracts.writers import protect_inputs, write_document


def write_manifest(report_dir: Path, fixture_path: Path, runtime_digest: str) -> Path:
    report_path = report_dir / "sensor-inference.json"
    report = json.loads(report_path.read_bytes())
    fixture = json.loads(fixture_path.read_bytes())
    model_path = report_dir / "model/model.onnx"
    configuration_path = report_dir / "configuration/inference-provider.json"
    dataset_path = report_dir / PurePosixPath(report["sample_dataset_path"]).name
    model_bytes = model_path.read_bytes()
    model_sha256 = sha256(model_bytes).hexdigest()
    configuration_sha256 = sha256(configuration_path.read_bytes()).hexdigest()
    dataset_sha256 = sha256(dataset_path.read_bytes()).hexdigest()
    if (
        report["status"] != "passed"
        or report["numerical_parity"] is not True
        or report["fallback_count"] != 0
        or report["executed_providers"] != ["OpenVINOExecutionProvider"]
        or report["runtime_version"] != fixture["runtime_version"]
        or model_sha256 != fixture["source"]["sha256"]
        or model_sha256 != report["model_artifact_sha256"]
        or configuration_sha256 != report["provider_options_sha256"]
        or dataset_sha256 != report["sample_dataset_sha256"]
    ):
        raise ValueError("model evidence differs from the successful probe or fixture")
    source = {
        key: fixture["source"][key]
        for key in ("uri", "sha256", "media_type", "inputs", "outputs")
    }
    source.update(
        size_bytes=len(model_bytes),
        format="onnx",
        runtime_family="onnx",
        execution_provider="reference",
    )
    document = {
        "schema_version": "model-artifact-manifest.v1",
        "model_id": "org.example.onnxruntime.sigmoid.openvino",
        "source": source,
        "target": {
            **source,
            "runtime_family": "onnxruntime_openvino",
            "execution_provider": "OpenVINOExecutionProvider",
        },
        "build": {
            "tool": "onnxruntime-wheel",
            "version": report["runtime_version"],
            "configuration_sha256": configuration_sha256,
            "source_artifact_sha256": model_sha256,
        },
        "numerical_conformance": {
            "report_sha256": sha256(report_path.read_bytes()).hexdigest(),
            "reference_artifact_sha256": model_sha256,
            "sample_dataset_sha256": dataset_sha256,
            "absolute_tolerance": report["tolerances"]["absolute"],
            "relative_tolerance": report["tolerances"]["relative"],
            "passed": True,
        },
        "compatibility": {"portable": True, "hardware": []},
        "extensions": {
            "org.robotics-runtime.build": {
                "source_opset": fixture["source"]["opset"],
                "tool_source_revision": fixture["source_revision"],
                "builder_image_digest": runtime_digest,
                "transformation": "identity",
            }
        },
    }
    output = report_dir / "model/model-manifest.json"
    protect_inputs(
        output,
        [report_path, fixture_path, model_path, configuration_path, dataset_path],
    )
    return write_document(document, output)


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--report-directory", type=Path, required=True)
    parser.add_argument("--fixture", type=Path, required=True)
    parser.add_argument("--runtime-digest", required=True)
    args = parser.parse_args()
    try:
        write_manifest(args.report_directory, args.fixture, args.runtime_digest)
    except (OSError, ValueError, KeyError) as exc:
        parser.exit(1, f"model manifest: {exc}\n")
