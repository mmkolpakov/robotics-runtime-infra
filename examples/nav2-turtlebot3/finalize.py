"""Bind completed Nav2 capture facts to immutable pre-execution v2 inputs."""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

from robotics_acceptance_harness.evaluator_trust import read_once
from robotics_runtime_contracts import loads_mapping, validate_document
from robotics_runtime_contracts.writers import (
    add_evidence_artifact,
    create_evidence_index,
    finalize_evidence_index,
    write_document,
)

NAMESPACE = "org.example.nav2-turtlebot3"
DOCUMENT_LIMIT = 1024 * 1024


def captured(path: Path) -> tuple[bytes, dict]:
    raw = read_once(path, DOCUMENT_LIMIT)
    return raw, loads_mapping(raw, source_name=str(path))


def complete(prepared: Path, capture: Path) -> dict:
    """Project native producer facts; do not execute or infer missing observations."""
    prepared, capture = prepared.resolve(), capture.resolve()
    archive = prepared.parent
    if not capture.is_relative_to(archive) or capture == archive:
        raise ValueError("the retained capture must be inside the original archive")
    _raw_manifest, manifest = captured(prepared / "pre-execution-inputs.json")
    documents = {}
    for name, key in (
        ("scenario.json", "scenario"),
        ("runtime.json", "runtime"),
        ("run.json", "run_context"),
    ):
        raw, document = captured(prepared / name)
        if (
            sha256(raw).hexdigest() != manifest[key]["sha256"]
            or len(raw) != manifest[key]["size_bytes"]
        ):
            raise ValueError("pre-execution input bytes changed")
        documents[key] = document
    for name, key in (
        ("nav2-configuration.json", "configuration"),
        ("native-profile.json", "native_profile"),
        ("nav2.schema.json", "extension_schema"),
    ):
        raw = read_once(prepared / name, DOCUMENT_LIMIT)
        if (
            sha256(raw).hexdigest() != manifest[key]["sha256"]
            or len(raw) != manifest[key]["size_bytes"]
        ):
            raise ValueError("pre-execution input bytes changed")
    schema = read_once(prepared / "nav2.schema.json", DOCUMENT_LIMIT)
    validate_document(
        documents["scenario"],
        extension_schemas={"urn:nav2-turtlebot3:scenario:v1": schema},
    )
    validate_document(documents["runtime"])
    validate_document(documents["run_context"])
    scenario, runtime, run = (
        documents[name] for name in ("scenario", "runtime", "run_context")
    )
    if (
        scenario["profile"]["profile_id"] != NAMESPACE
        or run["run_id"] != manifest["run_id"]
    ):
        raise ValueError("foreign pre-execution Nav2 inputs")
    if runtime["scenario_sha256"] != manifest["scenario"]["sha256"]:
        raise ValueError("runtime differs from the pre-execution scenario")
    _raw_facts, facts = captured(capture / "completed-facts.json")
    required = {
        "started_at",
        "finished_at",
        "observations",
        "artifacts",
        "policy_observation",
    }
    if not required <= set(facts) or set(facts) - required - {
        "measurement_window",
        "native_model",
    }:
        raise ValueError("closed completed Nav2 capture facts are required")
    paths = []
    records = []
    for artifact in facts["artifacts"]:
        if set(artifact) != {"source", "artifact_id", "kind", "media_type"}:
            raise ValueError("closed native artifact metadata is required")
        source = capture / artifact["source"]
        resolved = source.resolve()
        if (
            source.is_symlink()
            or not resolved.is_relative_to(capture)
            or not resolved.is_file()
        ):
            raise ValueError("native artifact must be a confined regular capture file")
        records.append(
            (
                resolved,
                {key: artifact[key] for key in ("artifact_id", "kind", "media_type")},
            )
        )
        paths.append(resolved)
    if len(set(paths)) != len(paths):
        raise ValueError("duplicate native capture artifact")
    output = archive / "observation.json"
    index = archive / "evidence-index.json"
    if output.exists() or index.exists():
        raise ValueError("completed Nav2 documents already exist")
    policy = scenario["evidence_policy"]
    sizes = [source.stat().st_size for source in paths]
    if (
        any(size > policy["max_artifact_size_bytes"] for size in sizes)
        or sum(sizes) > policy["max_archive_size_bytes"]
    ):
        raise ValueError("native capture exceeds its admitted evidence byte budget")
    draft = create_evidence_index(
        {
            "schema_version": "evidence-index.v1",
            "run_id": run["run_id"],
            "generated_at": datetime.now(UTC).isoformat(),
            "policy_observation": facts["policy_observation"],
        }
    )
    records.insert(
        0,
        (
            prepared / "nav2-configuration.json",
            {
                "artifact_id": "nav2-configuration",
                "kind": "other_evidence",
                "media_type": "application/json",
            },
        ),
    )
    for source, metadata in records:
        draft = add_evidence_artifact(
            draft,
            source=source,
            metadata={
                **metadata,
                "retention_class": policy["retention_class"],
                "storage_state": "local",
            },
        )
    observation = {
        "schema_version": "acceptance-observation.v2",
        "observation_id": "nav2-completed-native-observations",
        "run_id": run["run_id"],
        "scenario_id": scenario["scenario_id"],
        "domain_id": manifest["domain_id"],
        "scenario_sha256": manifest["scenario"]["sha256"],
        "runtime_manifest_sha256": manifest["runtime"]["sha256"],
        **{key: facts[key] for key in ("started_at", "finished_at", "observations")},
        "evidence": [
            {
                key: artifact[key]
                for key in ("uri", "sha256", "size_bytes", "media_type")
            }
            for artifact in draft["index"]["artifacts"]
        ],
    }
    for field in ("measurement_window", "native_model"):
        if field in facts:
            observation[field] = facts[field]
    write_document(observation, output)
    draft = add_evidence_artifact(
        draft,
        source=output,
        metadata={
            "artifact_id": "native-observation",
            "kind": "acceptance_observation",
            "media_type": "application/json",
            "retention_class": policy["retention_class"],
            "storage_state": "local",
        },
    )
    write_document(finalize_evidence_index(draft), index)
    return {
        "run_id": run["run_id"],
        "domain_id": manifest["domain_id"],
        "scenario": str(prepared / "scenario.json"),
        "runtime": str(prepared / "runtime.json"),
        "run_context": str(prepared / "run.json"),
        "evidence_index": str(index),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", type=Path, required=True)
    parser.add_argument("--capture", type=Path, required=True)
    arguments = parser.parse_args()
    print(json.dumps(complete(arguments.prepared, arguments.capture), sort_keys=True))


if __name__ == "__main__":
    main()
