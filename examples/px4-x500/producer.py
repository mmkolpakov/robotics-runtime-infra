"""Produce immutable PX4 X500 inputs and completed public SDK documents."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from tempfile import NamedTemporaryFile, TemporaryDirectory, TemporaryFile
from urllib.parse import urlsplit
from urllib.request import url2pathname
from uuid import uuid4

from px4_x500_evaluator import facts, validate_journal
from robotics_acceptance_harness.evaluator_trust import read_once
from robotics_acceptance_harness.evidence import load_evidence_index
from robotics_runtime_contracts import (
    dumps_canonical,
    loads_mapping,
    validate_document,
    validate_role,
)
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


def create_run(scenario_path: Path, run_path: Path, run_id: str) -> str:
    scenario_raw, scenario = mapping(scenario_path)
    environment = os.environ.copy()
    environment.pop("PYTHONPATH", None)
    environment.pop("PYTHONHOME", None)
    with TemporaryDirectory(prefix=".create-run-", dir=run_path.parent) as directory:
        snapshot = Path(directory) / "scenario.json"
        snapshot.write_bytes(scenario_raw)
        snapshot.chmod(0o400)
        with (
            TemporaryFile(dir=directory) as stdout,
            TemporaryFile(dir=directory) as stderr,
        ):
            result = subprocess.run(
                [
                    str(
                        Path(sys.executable).absolute().with_name("robotics-acceptance")
                    ),
                    "create-run",
                    "--scenario",
                    str(snapshot.resolve()),
                    "--output",
                    str(run_path.absolute()),
                    "--domain",
                    "px4=simulation",
                    "--time-authority",
                    CLOCK["kind"],
                    "--time-source",
                    CLOCK["source_id"],
                    "--run-id",
                    run_id,
                ],
                cwd=directory,
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                timeout=30,
                check=False,
            )
            stderr.seek(0)
            diagnostic = stderr.read(4097)
            if result.returncode != 0:
                reason = diagnostic[:4096].decode("utf-8", errors="replace").strip()
                if len(diagnostic) > 4096:
                    reason += "\n[diagnostic truncated]"
                raise ValueError(
                    f"acceptance CLI create-run failed (exit {result.returncode}): "
                    + (reason or "no diagnostic emitted")
                )
            stdout.seek(0)
            output = stdout.read(4097)
            if len(output) > 4096 or output.decode("utf-8").strip() != run_id:
                raise ValueError("acceptance CLI returned a different run identity")
    _, run = mapping(run_path)
    validate_role(run, "acceptance_run")
    if (
        run["run_id"] != run_id
        or run["scenario_id"] != scenario["scenario_id"]
        or run["scenario_sha256"] != sha256(scenario_raw).hexdigest()
        or run["domains"] != [{"domain_id": "px4", "role": "simulation"}]
        or run["time_authority"] != CLOCK
        or read_once(scenario_path, LIMIT) != scenario_raw
    ):
        raise ValueError("run context differs from the prepared PX4 inputs")
    return run_id


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
        "measurement_method": "px4-valid-home-sampled-v0.2",
        "max_ulog_bytes": 64 * 1024**2,
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
    issued = create_run(scenario_path, run_path, run_id)
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


def retained_native(capture: Path, binding: dict) -> dict[Path, dict]:
    """Bind the small fixed custody roles to their original retained local paths."""
    if (binding.get("kind"), binding.get("domain_id")) != ("native-evidence", "px4"):
        raise ValueError("foreign or malformed native binding")
    value = binding.get("value", {})
    custody = value.get("custody", {})
    if not isinstance(custody, dict) or not set(custody) <= {
        "actor_before",
        "actor_after",
        "logger_start",
        "logger_stop",
        "export_manifest",
        "export_plan",
        "export_job",
    }:
        raise ValueError("malformed native custody references")
    selected = {}

    def capture_ref(ref, limit, *, ulog=False):
        if not isinstance(ref, dict) or set(ref) != {
            "uri",
            "sha256",
            "size_bytes",
            "media_type",
        }:
            raise ValueError("native original must be one complete ArtifactRef")
        uri = urlsplit(ref["uri"])
        if (
            uri.scheme != "file"
            or uri.netloc not in {"", "localhost"}
            or uri.query
            or uri.fragment
        ):
            raise ValueError("native original requires a local retained file URI")
        path = Path(url2pathname(uri.path))
        if not path.is_absolute() or path.as_uri() != ref["uri"]:
            raise ValueError("native original URI is not canonical")
        roots = (capture,) if ulog else (capture, capture.parent / "parent-facts")
        selected_root = next(
            (root for root in roots if path.is_relative_to(root)), None
        )
        if selected_root is None:
            raise ValueError("native original is outside the two fixed retained roots")
        relative = path.relative_to(selected_root)
        if not relative.parts or any(v in {".", ".."} for v in relative.parts):
            raise ValueError("native original path is not confined")
        parent = selected_root
        if parent.is_symlink():
            raise ValueError("native retained root is a symbolic link")
        for part in relative.parts:
            parent = parent / part
            if parent.is_symlink():
                raise ValueError("native original path contains a symbolic link")
        if path in selected:
            if selected[path] != ref:
                raise ValueError("native original has conflicting identity")
            return None
        if (
            len(selected) >= 16
            or type(ref["size_bytes"]) is not int
            or not 0 <= ref["size_bytes"] <= limit
        ):
            raise ValueError("native originals exceed count/byte policy")
        raw = read_once(path, limit)
        if (sha256(raw).hexdigest(), len(raw)) != (ref["sha256"], ref["size_bytes"]):
            raise ValueError(
                "native original bytes differ from their exact ArtifactRef"
            )
        selected[path] = ref
        return raw

    if "ulog" in value:
        capture_ref(value["ulog"], 64 * 1024**2, ulog=True)
    for role in (
        "actor_before",
        "actor_after",
        "logger_start",
        "logger_stop",
        "export_manifest",
        "export_plan",
        "export_job",
    ):
        if role not in custody:
            continue
        raw = capture_ref(custody[role], LIMIT)
        if role.startswith("actor_") and raw is not None:
            actor = loads_mapping(raw, source_name=role + ".json")
            if "process_record" in actor:
                capture_ref(actor["process_record"], LIMIT)
            if role == "actor_after":
                for key in ("exec_record", "exec_result"):
                    if key in actor:
                        capture_ref(actor[key], LIMIT)
    return selected


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
    native_originals = {}
    native_input = capture / "native-evidence.json"
    if native_input.exists() or native_input.is_symlink():
        raw = read_once(native_input, LIMIT)
        native = loads_mapping(raw, source_name=str(native_input))
        if native.get("run_id") != issued["run_id"]:
            raise ValueError("native binding belongs to another original run")
        native_originals = retained_native(capture, native)
        snapshots["native-evidence.json"] = raw
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
        original_path = capture / entry["path"]
        path = (
            original_path
            if original_path in native_originals
            else frozen / entry["path"]
        )
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
    if "native-evidence.json" in snapshots:
        draft = add_evidence_artifact(
            draft,
            frozen / "native-evidence.json",
            {
                "artifact_id": "native-binding",
                "kind": "other_evidence",
                "media_type": "application/json",
                "retention_class": "test-evidence",
                "storage_state": "local",
            },
        )
    for number, (path, ref) in enumerate(native_originals.items()):
        if path in paths:
            continue
        draft = add_evidence_artifact(
            draft,
            path,
            {
                **ref,
                "artifact_id": f"native-{number}",
                "kind": "other_evidence",
                "retention_class": "test-evidence",
                "storage_state": "local",
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
            native = None
            if "native-evidence.json" in snapshots:
                native = loads_mapping(
                    verified.read_local(
                        frozen / "native-evidence.json", max_raw_evidence_bytes=LIMIT
                    ),
                    source_name="native-evidence.json",
                )
            assessed = facts(
                records,
                documents["configuration"],
                cleanup,
                evidence=verified,
                native=native,
            )
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
