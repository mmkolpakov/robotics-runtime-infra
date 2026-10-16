"""Bind completed Nav2 capture facts to immutable pre-execution v2 inputs."""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

from robotics_acceptance_harness.evaluator_trust import read_once
from robotics_runtime_contracts import dumps_canonical, loads_mapping, validate_document
from robotics_runtime_contracts.writers import (
    add_evidence_artifact,
    create_evidence_index,
    finalize_evidence_index,
    write_document,
    write_bytes_atomically,
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
    validate_document(observation)
    final_sizes = [artifact["size_bytes"] for artifact in draft["index"]["artifacts"]]
    final_sizes.append(len(dumps_canonical(observation)))
    if (
        any(size > policy["max_artifact_size_bytes"] for size in final_sizes)
        or sum(final_sizes) > policy["max_archive_size_bytes"]
    ):
        raise ValueError("completed index exceeds its admitted evidence byte budget")
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


def complete_native(prepared: Path, capture: Path) -> dict:
    """Bind closed records without turning action acknowledgements into physical facts."""
    from shutil import copyfile

    def reference(path):
        raw = read_once(path, DOCUMENT_LIMIT)
        return {
            "uri": path.resolve().as_uri(),
            "sha256": sha256(raw).hexdigest(),
            "size_bytes": len(raw),
            "media_type": "application/json",
        }

    manifest = loads_mapping(
        read_once(prepared / "pre-execution-inputs.json", DOCUMENT_LIMIT)
    )
    scenario = loads_mapping(read_once(prepared / "scenario.json", DOCUMENT_LIMIT))
    case = scenario["extensions"][NAMESPACE]["case"]
    workload_path = capture / case / "workload.json"
    report = loads_mapping(read_once(workload_path, DOCUMENT_LIMIT))
    if (report["run_id"], report["domain_id"], report["case"]) != (
        manifest["run_id"],
        "nav2",
        case,
    ):
        raise ValueError("native workload belongs to another execution")
    timing = loads_mapping(read_once(capture / "native-run.json", DOCUMENT_LIMIT))
    cleanup_path = capture / "cleanup.json"
    cleanup = loads_mapping(read_once(cleanup_path, DOCUMENT_LIMIT))
    recorder = loads_mapping(
        read_once(capture / "recorder-facts/capture-state.json", DOCUMENT_LIMIT)
    )
    if recorder["run_id"] != manifest["run_id"] or recorder["domain_id"] != "nav2":
        raise ValueError("native recorder belongs to another execution")
    unknown = {
        "state": "unobserved",
        "reason": "the native producer did not capture this fact",
    }
    observations = {
        name: dict(unknown) for name in ("command", "terminal", "condition", "cleanup")
    }
    evidence = reference(workload_path)
    if type(report.get("goal_accepted")) is bool:
        observations["command"] = {
            "state": "measured",
            "value": report["goal_accepted"],
            "evidence": evidence,
        }
    response = report.get("result_observation")
    cdr = capture / case / "get-result-response.cdr"
    response_bound = False
    if isinstance(response, dict) and cdr.is_file():
        raw_cdr = read_once(cdr, DOCUMENT_LIMIT)
        response_bound = response.get("sha256") == sha256(
            raw_cdr
        ).hexdigest() and response.get("size_bytes") == len(raw_cdr)
    if response_bound and type(report.get("action_status")) is int:
        observations["terminal"] = {
            "state": "measured",
            "value": report["action_status"],
            "evidence": evidence,
        }
    pose = report.get("final_amcl_pose", {})
    result_time = report.get("result_observed_monotonic_ns")
    if (
        case == "success"
        and response_bound
        and report.get("observation_status") == "complete"
        and type(result_time) is int
        and pose.get("observed_monotonic_ns", -1) >= result_time
    ):
        observations["condition"] = {
            "state": "measured",
            "value": pose,
            "evidence": evidence,
        }
    if (
        cleanup.get("remaining") == []
        and cleanup.get("worker_settled") is True
        and cleanup.get("recorder_settled") is True
    ):
        observations["cleanup"] = {
            "state": "measured",
            "value": [],
            "evidence": reference(cleanup_path),
        }
    for name in (
        "native-model.sdf",
        "native-world.sdf",
        "native-preflight.json",
    ):
        copyfile(prepared / name, capture / name)
    artifacts = []
    for index, path in enumerate(sorted(capture.rglob("*"))):
        if path.is_symlink():
            raise ValueError("symlink in native capture")
        if path.is_file() and path.name != "completed-facts.json":
            artifacts.append(
                {
                    "source": str(path.relative_to(capture)),
                    "artifact_id": "native-" + str(index),
                    "kind": "other_evidence",
                    "media_type": "application/json"
                    if path.suffix == ".json"
                    else "application/octet-stream",
                }
            )
    policy_observation = dict(recorder["policy_observation"])
    if (
        policy_observation["retention_class"]
        != scenario["evidence_policy"]["retention_class"]
        or policy_observation["upload_mode"] != "local_only"
    ):
        raise ValueError("observed recorder policy differs")
    acquired = loads_mapping(
        read_once(capture / "native-acquired.json", DOCUMENT_LIMIT)
    )
    if acquired["HostConfig"]["NetworkMode"] != "none":
        raise ValueError("remote-free recorder isolation was not observed")
    facts = {
        "started_at": timing["started_at"],
        "finished_at": timing["finished_at"],
        "observations": observations,
        "artifacts": artifacts,
        "policy_observation": policy_observation,
    }
    if (
        recorder.get("capture_status") != "complete"
        or recorder.get("closure_confirmed") is not True
    ):
        raise ValueError("native recorder closure is not established")
    write_bytes_atomically(dumps_canonical(facts), capture / "completed-facts.json")
    return facts


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--prepared", type=Path, required=True)
    parser.add_argument("--capture", type=Path, required=True)
    parser.add_argument("--from-native", action="store_true")
    arguments = parser.parse_args()
    if arguments.from_native:
        complete_native(arguments.prepared, arguments.capture)
    print(json.dumps(complete(arguments.prepared, arguments.capture), sort_keys=True))


if __name__ == "__main__":
    main()
