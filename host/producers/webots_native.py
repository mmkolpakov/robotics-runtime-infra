"""Issue and complete the fixed native Webots physics probe's v2 documents."""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from hashlib import sha256
from importlib.metadata import version
from pathlib import Path

from robotics_acceptance_harness.evaluator_trust import read_once
from robotics_acceptance_harness.run_context import create_run_context
from robotics_runtime_contracts import dumps_canonical, loads_mapping, validate_document
from robotics_runtime_contracts.writers import (
    add_evidence_artifact,
    create_evidence_index,
    create_runtime_manifest,
    finalize_evidence_index,
    protect_inputs,
    write_bytes_atomically,
    write_document,
)
from workers.webots.common import MODEL_MANIFEST_SHA256, model_inputs

PROFILE_ID = "org.robotics.runtime.webots-physics"
LIMIT = 16 * 1024 * 1024


def captured(path: Path) -> tuple[bytes, dict]:
    raw = read_once(path, LIMIT)
    return raw, loads_mapping(raw, source_name=str(path))


def reference(
    path: Path, media_type: str = "application/json", *, raw: bytes | None = None
) -> dict:
    if raw is None:
        raw = read_once(path, LIMIT)
    return {
        "uri": path.resolve().as_uri(),
        "sha256": sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "media_type": media_type,
    }


def require_sdk() -> None:
    expected = {
        "robotics-runtime-contracts": "0.21.1",
        "robotics-acceptance-harness": "0.22.1",
    }
    if {name: version(name) for name in expected} != expected:
        raise ValueError(
            "Webots v2 documents require robotics-runtime-contracts 0.21.1 and robotics-acceptance-harness 0.22.1"
        )


def prepare(
    assets: Path, output: Path, *, owner_id: str, worker_image: str, project: str
) -> dict:
    """Issue input identity; never execute Webots or admit a composition."""
    require_sdk()
    manifest_raw, manifest = captured(assets / "upstream.json")
    if sha256(manifest_raw).hexdigest() != MODEL_MANIFEST_SHA256:
        raise ValueError("selected worker asset manifest bytes differ")
    pins = manifest["model_inputs"]
    model_inputs(assets, pins["world"]["sha256"], pins["proto"]["sha256"])
    prefix, separator, digest = worker_image.rpartition("@sha256:")
    if (
        not prefix
        or not separator
        or len(digest) != 64
        or any(c not in "0123456789abcdef" for c in digest)
    ):
        raise ValueError("explicit immutable worker image identity is required")
    copies = {
        "native.wbt": read_once(assets / "worlds/native.wbt", LIMIT),
        "NativeProbe.proto": read_once(assets / "protos/NativeProbe.proto", LIMIT),
        "upstream.json": manifest_raw,
    }
    for name, key in (("native.wbt", "world"), ("NativeProbe.proto", "proto")):
        if (sha256(copies[name]).hexdigest(), len(copies[name])) != (
            pins[key]["sha256"],
            pins[key]["size_bytes"],
        ):
            raise ValueError(
                "captured model source bytes differ from sealed asset pins"
            )
    output.mkdir(parents=True, exist_ok=False, mode=0o700)
    for name, raw in copies.items():
        write_bytes_atomically(raw, output / name)
    model = reference(output / "native.wbt", "text/plain")
    proto = reference(output / "NativeProbe.proto", "text/plain")
    asset_manifest = reference(output / "upstream.json")
    descriptor = output / "worker-observation.schema.json"
    write_bytes_atomically(
        dumps_canonical(
            {
                "$schema": "https://json-schema.org/draft/2020-12/schema",
                "type": "object",
                "required": ["owner_id", "status"],
                "properties": {
                    "owner_id": {"type": "string"},
                    "status": {"type": "string"},
                },
                "description": "Worker JSON observations of libController APIs; not a native wire payload.",
            }
        ),
        descriptor,
    )
    configuration = output / "configuration.json"
    write_bytes_atomically(
        dumps_canonical(
            {
                "owner_id": owner_id,
                "project": project,
                "mode": "physics-only",
                "worker_image": worker_image,
                "world": model,
                "proto": proto,
                "asset_manifest": asset_manifest,
            }
        ),
        configuration,
    )
    profile = {
        "profile_id": PROFILE_ID,
        "channels": [
            {
                "name": "worker-observation",
                "original_type": {
                    "name": "org.robotics.runtime.WebotsWorkerObservation.v1",
                    "codec": {"implementation": "python-json-observer", "version": "1"},
                    "descriptor": reference(descriptor),
                },
                "backend": "local-file",
                "wire_envelope": "json-object",
                "native_encoding": "utf-8",
                "recorder": {
                    "implementation": "robotics-runtime-infra/webots-worker",
                    "version": "1",
                    "transformation": "libController receiver observations; binary64 seconds preserved",
                },
            }
        ],
        "executor": {
            "implementation": "robotics-runtime-infra/webots-worker",
            "version": "1",
            "configuration": reference(configuration),
        },
        "clock": {"kind": "external", "source_id": "system-utc-provenance"},
        "observations": {
            name: {"kind": kind, "requirement": "required"}
            for name, kind in (
                ("command", "command_acceptance"),
                ("terminal", "native_final_state"),
                ("physics", "postcondition"),
                ("model", "other"),
                ("native-time", "clock"),
                ("loaded-scene", "other"),
                ("cleanup", "other"),
            )
        }
        | {
            "camera": {
                "kind": "other",
                "requirement": "not_applicable",
                "reason": "the physics-only profile disables Camera updates",
            }
        },
    }
    execution = {
        "target_environment": "simulation",
        "data_source": "webots-native-physics",
        "plant_backend": "Webots-R2025a",
        "time_mode": "discrete_steps",
    }
    scenario = {
        "schema_version": "acceptance-scenario.v2",
        "scenario_id": PROFILE_ID,
        "execution": execution,
        "profile": profile,
        "native_model": model,
        "metric_definitions": [],
        "assertions": [],
        "evaluator_requirements": [],
        "evidence_policy": {
            "max_artifact_size_bytes": LIMIT,
            "max_archive_size_bytes": LIMIT * 2,
            "max_upload_lag_sec": 0,
            "upload_mode": "local_only",
            "retention_class": "test-evidence",
            "remote_sink_allowed": False,
        },
    }
    scenario_path = write_document(scenario, output / "scenario.json")
    write_document(
        create_runtime_manifest(
            {
                "schema_version": "runtime-manifest.v2",
                "runtime_id": "webots-physics",
                "generated_at": datetime.now(UTC).isoformat(),
                "scenario_sha256": reference(scenario_path)["sha256"],
                "execution": execution,
                "profile": profile,
                "native_model": model,
                "evaluator_bindings": [],
            }
        ),
        output / "runtime.json",
    )
    run_path = output / "run.json"
    run_id = create_run_context(
        scenario_path,
        run_path,
        domains={"webots": "simulation"},
        time_authority=profile["clock"]["kind"],
        time_source=profile["clock"]["source_id"],
        run_id=owner_id,
    )
    refs = {
        name: reference(
            output / name,
            "text/plain" if name.endswith((".wbt", ".proto")) else "application/json",
        )
        for name in (
            "scenario.json",
            "runtime.json",
            "run.json",
            "native.wbt",
            "NativeProbe.proto",
            "upstream.json",
            "configuration.json",
            "worker-observation.schema.json",
        )
    }
    issued = {
        "run_id": run_id,
        "owner_id": owner_id,
        "domain_id": "webots",
        "worker_image": worker_image,
        "project": project,
        "inputs": refs,
    }
    sidecar = write_bytes_atomically(
        dumps_canonical(issued), output / "pre-execution-inputs.json"
    )
    for path in [*(output / name for name in refs), sidecar]:
        path.chmod(0o400)
    return {**issued, "input_manifest": reference(sidecar)}


def issued_inputs(
    prepared: Path, expected_sha: str, expected_size: int
) -> tuple[dict, dict]:
    raw, issued = captured(prepared / "pre-execution-inputs.json")
    if sha256(raw).hexdigest() != expected_sha or len(raw) != expected_size:
        raise ValueError("host-owned pre-execution manifest identity differs")
    documents = {}
    for name, ref in issued["inputs"].items():
        raw = read_once(prepared / name, LIMIT)
        if sha256(raw).hexdigest() != ref["sha256"] or len(raw) != ref["size_bytes"]:
            raise ValueError("pre-execution source bytes changed")
        if name.endswith(".json"):
            documents[name] = loads_mapping(raw, source_name=name)
    if documents["run.json"]["run_id"] != issued["run_id"]:
        raise ValueError("pre-execution run differs")
    return issued, documents


def bind_model(controller: dict, issued: dict, capture: Path) -> dict:
    refs = {}
    for name, key in (
        ("native.wbt", "world"),
        ("NativeProbe.proto", "proto"),
        ("upstream.json", None),
    ):
        raw = read_once(capture / name, LIMIT)
        expected = issued["inputs"][name]
        if (
            sha256(raw).hexdigest() != expected["sha256"]
            or len(raw) != expected["size_bytes"]
        ):
            raise ValueError("captured model source bytes differ")
        refs[capture / name] = reference(
            capture / name, media_type(capture / name), raw=raw
        )
        observed = (
            controller.get("model_inputs", {}).get(key)
            if key
            else controller.get("asset_manifest_ref")
        )
        if not isinstance(observed, dict) or (
            observed.get("sha256"),
            observed.get("size_bytes"),
        ) != (expected["sha256"], expected["size_bytes"]):
            raise ValueError(
                "actual loaded model/source identity is unobserved or different"
            )
    if (
        controller.get("observed_world_path")
        != "/opt/robotics/webots/worlds/native.wbt"
    ):
        raise ValueError("the SDK did not observe the selected opened world")
    return refs


def measured(value, source):
    return {"state": "measured", "value": value, "evidence": source}


def missing(reason):
    return {"state": "unobserved", "reason": reason}


def native_observations(
    controller: dict, worker: dict, capture: Path, issued: dict, source: dict
) -> tuple[dict, dict]:
    result = {}
    if (
        type(controller.get("camera", {}).get("sampling_period_ms")) is not int
        or controller["camera"]["sampling_period_ms"] != 0
    ):
        raise ValueError("physics-only camera was not observed disabled")
    result["camera"] = {
        "state": "not_applicable",
        "reason": "the physics-only profile disables Camera updates",
    }
    result["model"] = measured(
        {key: controller["model_inputs"][key]["sha256"] for key in ("world", "proto")},
        source,
    )
    samples = controller.get("samples")
    result["command"] = (
        measured(
            [
                {
                    "native_api": "Supervisor.step",
                    "request_ms": row["request_ms"],
                    "return": row["result"],
                }
                for row in samples
            ],
            source,
        )
        if samples
        else missing("no native step request/return captured")
    )
    result["terminal"] = missing(
        "step returns and worker/controller exits do not establish native terminal state"
    )
    result["physics"] = (
        measured(
            {
                "initial": controller["initial_state"],
                "last": controller["last_native_state"],
            },
            source,
        )
        if ("initial_state" in controller and "last_native_state" in controller)
        else missing("native physical postcondition was not captured")
    )
    clock = controller.get("time", {})
    valid_clock = clock == {
        "authority": "Webots Supervisor.getTime",
        "native_unit": "seconds",
        "representation": "float64",
        "epoch": issued["owner_id"] + ":initial",
    }
    if valid_clock and samples:
        for row in samples:
            for field in ("before_seconds", "after_seconds"):
                if (
                    type(row.get(field)) is not float
                    or row.get(field + "_hex") != row[field].hex()
                ):
                    raise ValueError("native binary64 seconds/hex identity is invalid")
        result["native-time"] = measured({"clock": clock, "samples": samples}, source)
    else:
        result["native-time"] = missing("native seconds/epoch were not captured")
    scene = capture / "loaded-scene.wrl"
    artifacts = {}
    if scene.is_file():
        scene_raw = read_once(scene, LIMIT)
        scene_ref = reference(scene, "text/plain", raw=scene_raw)
        claimed = controller.get("loaded_scene_ref", {})
        if not scene_ref["size_bytes"] or (
            scene_ref["sha256"],
            scene_ref["size_bytes"],
        ) != (claimed.get("sha256"), claimed.get("size_bytes")):
            raise ValueError("native scene bytes differ from the observed export")
        result["loaded-scene"] = measured(
            {
                "native_api": "Supervisor.getRoot().exportString",
                "source_equivalence": "not-asserted",
            },
            scene_ref,
        )
        artifacts[scene] = scene_ref
    else:
        result["loaded-scene"] = missing("native scene export was not captured")
    return result, artifacts


def cleanup_observation(
    path: Path | None, owner: str, project: str
) -> tuple[dict, str | None, dict | None]:
    if path is None or not path.is_file():
        return missing("independent Engine inventory was not captured"), None, None
    raw, cleanup = captured(path)
    cleanup_ref = reference(path, raw=raw)
    if cleanup.get("owner_id") != owner or cleanup.get("project") != project:
        raise ValueError("cleanup inventory belongs to a foreign run")
    if cleanup.get("observation", {}).get("status") != "complete":
        return (
            missing("Engine ownership/inventory observation is incomplete"),
            None,
            cleanup_ref,
        )
    inventory = cleanup.get("observation", {}).get("inventory", {})
    volumes = inventory.get("volumes", {}).get("Volumes")
    if (
        not all(
            isinstance(inventory.get(key), list) for key in ("containers", "networks")
        )
        or "Volumes" not in inventory.get("volumes", {})
        or not (volumes is None or isinstance(volumes, list))
    ):
        return (
            missing("Engine container/network/volume inventory is incomplete"),
            None,
            cleanup_ref,
        )
    released = (
        cleanup.get("observation", {}).get("status") == "complete"
        and not inventory["containers"]
        and not inventory["networks"]
        and not volumes
    )
    if cleanup.get("released") is not released:
        raise ValueError("claimed cleanup differs from actual inventory")
    return (
        measured(
            {
                "resources_released": released,
                "robot_stopped": "not-asserted",
                "project": cleanup["project"],
            },
            cleanup_ref,
        ),
        cleanup["observed_at"],
        cleanup_ref,
    )


def media_type(path: Path) -> str:
    if path.suffix in (".wbt", ".proto", ".wrl"):
        return "text/plain"
    if path.suffix == ".jsonl":
        return "application/x-ndjson"
    return "application/json"


def complete(
    prepared: Path,
    capture: Path,
    cleanup_path: Path | None,
    *,
    input_manifest_sha256: str,
    input_manifest_size: int,
) -> dict:
    """Bind retained observations; do not execute or infer missing native facts."""
    require_sdk()
    archive = prepared.resolve().parent
    if not capture.resolve().is_relative_to(archive):
        raise ValueError("capture must be inside this archive's retained scope")
    issued, docs = issued_inputs(prepared, input_manifest_sha256, input_manifest_size)
    controller_raw, controller = captured(capture / "controller-result.json")
    worker_raw, worker = captured(capture / "worker-result.json")
    if any(v.get("owner_id") != issued["owner_id"] for v in (controller, worker)):
        raise ValueError("native capture belongs to a foreign run")
    model_refs = bind_model(controller, issued, capture)
    claimed = worker.get("controller_result_ref", {})
    if (claimed.get("sha256"), claimed.get("size_bytes")) != (
        sha256(controller_raw).hexdigest(),
        len(controller_raw),
    ):
        raise ValueError("controller bytes differ from worker's observed identity")
    controller_ref = reference(capture / "controller-result.json", raw=controller_raw)
    observations, extra = native_observations(
        controller, worker, capture, issued, controller_ref
    )
    observations["cleanup"], cleanup_time, cleanup_ref = cleanup_observation(
        cleanup_path, issued["owner_id"], issued["project"]
    )
    artifacts = {
        prepared / name: ref
        for name, ref in issued["inputs"].items()
        if name not in ("scenario.json", "runtime.json", "run.json")
    }
    artifacts.update(model_refs)
    artifacts[capture / "controller-result.json"] = controller_ref
    artifacts[capture / "worker-result.json"] = reference(
        capture / "worker-result.json", raw=worker_raw
    )
    artifacts.update(extra)
    if cleanup_path is not None and cleanup_ref is not None:
        artifacts[cleanup_path] = cleanup_ref
    metrics = archive / "metrics.jsonl"
    protect_inputs(metrics, artifacts)
    write_bytes_atomically(b"", metrics)
    artifacts[metrics] = reference(metrics, "application/x-ndjson", raw=b"")
    observation = {
        "schema_version": "acceptance-observation.v2",
        "observation_id": "webots-native-capture",
        "run_id": issued["run_id"],
        "scenario_id": docs["scenario.json"]["scenario_id"],
        "domain_id": issued["domain_id"],
        "scenario_sha256": issued["inputs"]["scenario.json"]["sha256"],
        "runtime_manifest_sha256": issued["inputs"]["runtime.json"]["sha256"],
        "started_at": worker["started_at"],
        "finished_at": cleanup_time or worker["finished_at"],
        "native_model": docs["runtime.json"]["native_model"],
        "observations": observations,
        "evidence": list(artifacts.values()),
    }
    validate_document(observation)
    output = archive / "observation.json"
    index = archive / "evidence-index.json"
    if output.exists() or index.exists():
        raise ValueError("completed observation documents already exist")
    protect_inputs(output, artifacts)
    observation_path = write_document(observation, output)
    draft = create_evidence_index(
        {
            "schema_version": "evidence-index.v1",
            "run_id": issued["run_id"],
            "generated_at": datetime.now(UTC).isoformat(),
            "policy_observation": {
                "recording_mode": "native-files",
                "compression": "none",
                "retention_class": "test-evidence",
                "upload_mode": "local_only",
                "remote_sink_used": False,
                "spool_peak_size_bytes": sum(
                    ref["size_bytes"] for ref in artifacts.values()
                )
                + len(dumps_canonical(observation)),
                "upload_lag_max_sec": 0,
            },
        }
    )
    indexed = {
        **artifacts,
        observation_path: reference(observation_path, raw=dumps_canonical(observation)),
    }
    for path, ref in indexed.items():
        draft = add_evidence_artifact(
            draft,
            source=path,
            metadata={
                **ref,
                "artifact_id": ("prepared-" if path.parent == prepared else "captured-")
                + path.name.lower().replace(".", "-"),
                "kind": "acceptance_observation"
                if path == observation_path
                else "metrics"
                if path == metrics
                else "other_evidence",
                "media_type": media_type(path),
                "retention_class": "test-evidence",
                "storage_state": "local",
            },
        )
    write_document(finalize_evidence_index(draft), index)
    return {
        "scenario": str(prepared / "scenario.json"),
        "runtime": str(prepared / "runtime.json"),
        "run_context": str(prepared / "run.json"),
        "evidence_index": str(index),
        "otel_metrics": str(metrics),
        "observation": str(observation_path),
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="operation", required=True)
    issue = sub.add_parser("prepare")
    issue.add_argument("--assets", type=Path, required=True)
    issue.add_argument("--output", type=Path, required=True)
    issue.add_argument("--owner-id", required=True)
    issue.add_argument("--worker-image", required=True)
    issue.add_argument("--project", required=True)
    end = sub.add_parser("complete")
    end.add_argument("--prepared", type=Path, required=True)
    end.add_argument("--capture", type=Path, required=True)
    end.add_argument("--cleanup", type=Path)
    end.add_argument("--input-manifest-sha256", required=True)
    end.add_argument("--input-manifest-size", type=int, required=True)
    args = parser.parse_args()
    result = (
        prepare(
            args.assets,
            args.output,
            owner_id=args.owner_id,
            worker_image=args.worker_image,
            project=args.project,
        )
        if args.operation == "prepare"
        else complete(
            args.prepared,
            args.capture,
            args.cleanup,
            input_manifest_sha256=args.input_manifest_sha256,
            input_manifest_size=args.input_manifest_size,
        )
    )
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
