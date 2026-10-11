"""Produce immutable PX4 X500 inputs and completed public SDK documents."""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from tempfile import NamedTemporaryFile
from uuid import uuid4

from px4_x500_evaluator import facts, validate_journal
from robotics_acceptance_harness.evaluator_trust import read_once
from robotics_acceptance_harness.evidence import load_evidence_index
from robotics_acceptance_harness.run_context import create_run_context
from robotics_runtime_contracts import dumps_canonical, loads_mapping, validate_document
from robotics_runtime_contracts.writers import (
    add_evidence_artifact,
    create_evidence_index,
    finalize_evidence_index,
    write_bytes_atomically,
    write_document,
)

PROFILE = "org.example.px4-x500"
CLOCK = {"kind": "external", "source_id": "controller-utc-ms"}
CASES = {"land", "unarmed-refusal", "application-deadline"}
LIMIT = 1024 * 1024


def mapping(path: Path) -> tuple[bytes, dict]:
    raw = read_once(path, LIMIT)
    return raw, loads_mapping(raw, source_name=str(path))


def reference(path: Path) -> dict:
    raw = read_once(path, LIMIT)
    return {
        "uri": path.resolve().as_uri(),
        "sha256": sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "media_type": "application/json",
    }


def prepare(
    profile_path: Path,
    case: str,
    output: Path,
    *,
    binding_path: Path,
    run_id: str | None = None,
) -> dict:
    raw, profile = mapping(profile_path)
    _, binding = mapping(binding_path)
    if binding.get("namespace") != PROFILE:
        raise ValueError("one exact PX4 evaluator requirement is required")
    if case not in CASES or profile["profile_id"] != PROFILE:
        raise ValueError("one exact PX4 X500 case/profile is required")
    if profile.get("clock") != CLOCK or set(profile.get("executor", {})) != {
        "implementation",
        "version",
    }:
        raise ValueError(
            "exact native executor and actual receiver-clock declarations are required"
        )
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    run_id = run_id or "run-" + str(uuid4())
    configuration = {
        "case": case,
        "run_id": run_id,
        "domain_id": "px4",
        "min_ascent_m": 1.2,
        "max_refusal_ascent_m": 0.2,
        "application_deadline_ms": 2000,
    }
    config = output / "configuration.json"
    write_bytes_atomically(dumps_canonical(configuration), config)
    profile_snapshot = output / "native-profile.json"
    write_bytes_atomically(raw, profile_snapshot)
    selected = {
        **profile,
        "executor": {**profile["executor"], "configuration": reference(config)},
    }
    execution = {
        "target_environment": "simulation",
        "data_source": "native-px4-x500",
        "plant_backend": "Gazebo-Jetty",
        "time_mode": "simulation_realtime",
    }
    scenario = {
        "schema_version": "acceptance-scenario.v2",
        "scenario_id": "px4-x500-" + case,
        "execution": execution,
        "profile": selected,
        "metric_definitions": [],
        "assertions": [],
        "evaluator_requirements": [binding],
        "evidence_policy": {
            "max_artifact_size_bytes": 64 * 1024**2,
            "max_archive_size_bytes": 128 * 1024**2,
            "max_upload_lag_sec": 0,
            "upload_mode": "local_only",
            "retention_class": "test-evidence",
            "remote_sink_allowed": False,
        },
    }
    scenario_path, runtime_path, run_path = (
        output / name for name in ("scenario.json", "runtime.json", "run.json")
    )
    write_document(scenario, scenario_path)
    runtime = {
        "schema_version": "runtime-manifest.v2",
        "runtime_id": "px4-x500-runtime",
        "generated_at": datetime.now(UTC).isoformat(),
        "scenario_sha256": reference(scenario_path)["sha256"],
        "execution": execution,
        "profile": selected,
        "evaluator_bindings": [binding],
    }
    write_document(runtime, runtime_path)
    issued = create_run_context(
        scenario_path,
        run_path,
        domains={"px4": "simulation"},
        time_authority=CLOCK["kind"],
        time_source=CLOCK["source_id"],
        run_id=run_id,
    )
    manifest = {
        "run_id": issued,
        "domain_id": "px4",
        "scenario": reference(scenario_path),
        "runtime": reference(runtime_path),
        "run_context": reference(run_path),
        "configuration": reference(config),
        "native_profile": reference(profile_snapshot),
    }
    write_bytes_atomically(dumps_canonical(manifest), output / "pre-run-inputs.json")
    return manifest


def state(value, evidence, *, reason=None):
    if value is None:
        return {
            "state": "unobserved",
            "reason": reason or "required source record was not captured",
        }
    return {"state": "measured", "value": value, "evidence": evidence}


def complete(prepared: Path, capture: Path) -> dict:
    prepared, capture = prepared.resolve(), capture.resolve()
    archive = prepared.parent
    if not capture.is_relative_to(archive) or capture == archive:
        raise ValueError("capture must stay inside this original archive")
    _, issued = mapping(prepared / "pre-run-inputs.json")
    documents = {}
    for key, name in (
        ("scenario", "scenario.json"),
        ("runtime", "runtime.json"),
        ("run_context", "run.json"),
        ("configuration", "configuration.json"),
        ("native_profile", "native-profile.json"),
    ):
        raw, document = mapping(prepared / name)
        if (
            sha256(raw).hexdigest() != issued[key]["sha256"]
            or len(raw) != issued[key]["size_bytes"]
        ):
            raise ValueError("immutable pre-run input bytes changed")
        documents[key] = document
    scenario = documents["scenario"]
    if documents["configuration"]["run_id"] != issued["run_id"]:
        raise ValueError("configuration has another issued run")
    manifest_bytes, manifest = mapping(capture / "controller-manifest.json")
    if (
        manifest.get("run_id"),
        manifest.get("domain_id"),
        manifest.get("clock_source"),
        manifest.get("complete"),
    ) != (issued["run_id"], "px4", CLOCK["source_id"], True) or manifest.get(
        "complete"
    ) is not True:
        raise ValueError(
            "closed manifest must bind this run/domain and actual receiver clock"
        )
    start_ns, end_ns = (
        int(manifest["started_unix_ns"]),
        int(manifest["finished_unix_ns"]),
    )
    if end_ns <= start_ns:
        raise ValueError("actual receiver window must have positive duration")
    entries = manifest["records"]
    if not isinstance(entries, list) or not 0 < len(entries) <= 2048:
        raise ValueError("controller manifest exceeds its count budget")
    snapshots = {
        "controller-manifest.json": manifest_bytes,
    }
    total = 0
    for entry in entries:
        name = entry["path"]
        if (
            not isinstance(name, str)
            or name in snapshots
            or Path(name).name != name
            or "\\" in name
        ):
            raise ValueError("record path is not a unique confined basename")
        raw = read_once(capture / name, LIMIT)
        if (sha256(raw).hexdigest(), len(raw)) != (
            entry["sha256"],
            entry["size_bytes"],
        ):
            raise ValueError("record bytes differ from the controller manifest")
        total += len(raw)
        if total > 8 * 1024**2:
            raise ValueError("controller capture exceeds its byte budget")
        snapshots[name] = raw
    if total != manifest.get("total_bytes"):
        raise ValueError("controller manifest total differs from captured bytes")
    cleanup_input = capture / "engine-cleanup.json"
    if cleanup_input.exists() or cleanup_input.is_symlink():
        raw = read_once(cleanup_input, LIMIT)
        cleanup_data = loads_mapping(raw, source_name=str(cleanup_input))
        if cleanup_data.get("owner_id") != issued["run_id"]:
            raise ValueError("cleanup belongs to another native owner")
        snapshots["engine-cleanup.json"] = raw
    observation_path, index_path = (
        archive / "observation.json",
        archive / "evidence-index.json",
    )
    if observation_path.exists() or index_path.exists():
        raise ValueError("completed output already exists")
    # Capture every original file before the streaming writer. Only producer-owned
    # frozen files are registered: a later mutation of the original is irrelevant.
    frozen = archive / "source-records"
    frozen.mkdir(mode=0o700, exist_ok=False)
    for name, raw in snapshots.items():
        write_bytes_atomically(raw, frozen / name)
    draft = create_evidence_index(
        {
            "schema_version": "evidence-index.v1",
            "run_id": issued["run_id"],
            "generated_at": datetime.now(UTC).isoformat(),
            "policy_observation": {
                "recording_mode": "native-sdk-json",
                "compression": "none",
                "retention_class": "test-evidence",
                "upload_mode": "local_only",
                "remote_sink_used": False,
                "spool_peak_size_bytes": manifest["total_bytes"],
                "upload_lag_max_sec": 0,
            },
        }
    )
    draft = add_evidence_artifact(
        draft,
        frozen / "controller-manifest.json",
        {
            "artifact_id": "controller-manifest",
            "kind": "other_evidence",
            "media_type": "application/json",
            "retention_class": "test-evidence",
            "storage_state": "local",
        },
    )
    paths = []
    for number, entry in enumerate(entries):
        path = frozen / entry["path"]
        paths.append(path)
        draft = add_evidence_artifact(
            draft,
            path,
            {
                "artifact_id": f"controller-{number}",
                "kind": "other_evidence",
                "media_type": "application/json",
                "retention_class": "test-evidence",
                "storage_state": "local",
                "sha256": entry["sha256"],
                "size_bytes": entry["size_bytes"],
            },
        )
    cleanup_path = frozen / "engine-cleanup.json"
    if "engine-cleanup.json" in snapshots:
        draft = add_evidence_artifact(
            draft,
            cleanup_path,
            {
                "artifact_id": "engine-cleanup",
                "kind": "other_evidence",
                "media_type": "application/json",
                "retention_class": "test-evidence",
                "storage_state": "local",
            },
        )
    draft = add_evidence_artifact(
        draft,
        prepared / "configuration.json",
        {
            "artifact_id": "configuration",
            "kind": "other_evidence",
            "media_type": "application/json",
            "retention_class": "test-evidence",
            "storage_state": "local",
            "sha256": issued["configuration"]["sha256"],
            "size_bytes": issued["configuration"]["size_bytes"],
        },
    )
    with NamedTemporaryFile(
        dir=archive, prefix=".px4-source-index-", suffix=".json", delete=False
    ) as staging:
        temporary = Path(staging.name)
    try:
        write_document(finalize_evidence_index(draft), temporary)
        verified = load_evidence_index(temporary, expected_run_id=issued["run_id"])
        records = []
        for number, (path, entry) in enumerate(zip(paths, entries, strict=True)):
            raw = verified.read_local(path, max_raw_evidence_bytes=LIMIT)
            record = loads_mapping(raw, source_name=str(path))
            records.append(
                (
                    record,
                    {
                        key: verified.local_files[path][key]
                        for key in ("uri", "sha256", "size_bytes", "media_type")
                    },
                )
            )
        validate_journal(
            manifest, documents["configuration"], records, issued["run_id"], "px4"
        )
        cleanup = None
        if cleanup_path.exists():
            raw = verified.read_local(cleanup_path, max_raw_evidence_bytes=LIMIT)
            cleanup = (
                loads_mapping(raw, source_name=str(cleanup_path)),
                {
                    key: verified.local_files[cleanup_path][key]
                    for key in ("uri", "sha256", "size_bytes", "media_type")
                },
            )
        if cleanup and cleanup[0].get("owner_id") != issued["run_id"]:
            raise ValueError("cleanup belongs to another native owner")
        try:
            assessed = facts(records, documents["configuration"], cleanup)
            observations = {
                "command": state(
                    assessed["command"][0],
                    assessed["command"][1],
                    reason=assessed["command"][2],
                ),
                "terminal": state(
                    {
                        "grounded": assessed["grounded"][0],
                        "disarmed": assessed["disarmed"][0],
                    }
                    if assessed["grounded"][0] is not None
                    and assessed["disarmed"][0] is not None
                    else None,
                    assessed["grounded"][1],
                    reason="required grounded/disarmed telemetry was not captured",
                ),
                "postcondition": state(
                    assessed["postcondition"][0],
                    assessed["postcondition"][1],
                    reason=assessed["postcondition"][2],
                ),
                "cleanup": state(
                    assessed["cleanup"][0],
                    assessed["cleanup"][1],
                    reason=assessed["cleanup"][2],
                ),
            }
        except ValueError as error:
            manifest_ref = {
                key: verified.local_files[
                    (frozen / "controller-manifest.json").resolve()
                ][key]
                for key in ("uri", "sha256", "size_bytes", "media_type")
            }
            observations = {
                name: {
                    "state": "invalid",
                    "reason": str(error),
                    "evidence": manifest_ref,
                }
                for name in ("command", "terminal", "postcondition", "cleanup")
            }
    finally:
        temporary.unlink(missing_ok=True)
    start_ns, end_ns = (
        int(manifest["started_unix_ns"]),
        int(manifest["finished_unix_ns"]),
    )
    if end_ns <= start_ns:
        raise ValueError("actual receiver window must have positive duration")
    observation_path, index_path = (
        archive / "observation.json",
        archive / "evidence-index.json",
    )
    if observation_path.exists() or index_path.exists():
        raise ValueError("completed output already exists")
    observation = {
        "schema_version": "acceptance-observation.v2",
        "observation_id": "px4-completed-observations",
        "run_id": issued["run_id"],
        "scenario_id": scenario["scenario_id"],
        "domain_id": "px4",
        "scenario_sha256": issued["scenario"]["sha256"],
        "runtime_manifest_sha256": issued["runtime"]["sha256"],
        "started_at": datetime.fromtimestamp(start_ns / 1e9, UTC).isoformat(),
        "finished_at": datetime.fromtimestamp(end_ns / 1e9, UTC).isoformat(),
        "measurement_window": {
            "start_ns": start_ns,
            "end_ns": end_ns,
            "clock": CLOCK,
            "timestamp_encoding": "unix_ns",
        },
        "observations": observations,
        "evidence": [
            {
                key: artifact[key]
                for key in ("uri", "sha256", "size_bytes", "media_type")
            }
            for artifact in draft["index"]["artifacts"]
        ],
    }
    validate_document(observation)
    sizes = [artifact["size_bytes"] for artifact in draft["index"]["artifacts"]]
    sizes.append(len(dumps_canonical(observation)))
    policy = scenario["evidence_policy"]
    if (
        max(sizes) > policy["max_artifact_size_bytes"]
        or sum(sizes) > policy["max_archive_size_bytes"]
    ):
        raise ValueError("completed index exceeds its admitted byte budget")
    write_document(observation, observation_path)
    draft = add_evidence_artifact(
        draft,
        observation_path,
        {
            "artifact_id": "observation",
            "kind": "acceptance_observation",
            "media_type": "application/json",
            "retention_class": "test-evidence",
            "storage_state": "local",
        },
    )
    write_document(finalize_evidence_index(draft), index_path)
    return {
        "run_id": issued["run_id"],
        "domain_id": "px4",
        "scenario": str(prepared / "scenario.json"),
        "runtime": str(prepared / "runtime.json"),
        "run_context": str(prepared / "run.json"),
        "evidence_index": str(index_path),
        "window_start_ns": start_ns,
        "window_end_ns": end_ns,
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    before = commands.add_parser("prepare")
    before.add_argument("--profile", type=Path, required=True)
    before.add_argument("--case", choices=sorted(CASES), required=True)
    before.add_argument("--output", type=Path, required=True)
    before.add_argument("--run-id")
    before.add_argument("--evaluator-binding", type=Path, required=True)
    after = commands.add_parser("complete")
    after.add_argument("--prepared", type=Path, required=True)
    after.add_argument("--capture", type=Path, required=True)
    arguments = parser.parse_args()
    result = (
        prepare(
            arguments.profile,
            arguments.case,
            arguments.output,
            binding_path=arguments.evaluator_binding,
            run_id=arguments.run_id,
        )
        if arguments.command == "prepare"
        else complete(arguments.prepared, arguments.capture)
    )
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
