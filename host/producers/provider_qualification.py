"""Bind accepted native source evidence through public P/H writers and schemas."""

from __future__ import annotations
import argparse
from pathlib import Path
from typing import Any
from uuid import uuid4
from datetime import datetime, timezone
from hashlib import sha256
from robotics_runtime_contracts import load_mapping, validate_document
from robotics_runtime_contracts.providers import validate_provider_requirements
from robotics_runtime_contracts.writers import (
    create_evidence_index,
    add_evidence_artifact,
    finalize_evidence_index,
    write_document,
    write_bytes_atomically,
    protect_inputs,
)

NAMESPACE = "org.robotics.runtime.native-provider"
SCHEMA_URI = "urn:robotics:infra:native-provider-source:v1"
CAPABILITIES = [
    "simulated_physics",
    "native-lifecycle",
    "native-simulation-time",
    "native-evidence",
]


def source(digest: str, pointer: str) -> dict[str, str]:
    return {"sha256": digest, "pointer": pointer}


def time_value(
    value: object, unit: str, authority: str, epoch: str, raw: dict[str, str]
) -> dict[str, Any]:
    if unit == "ns":
        if not isinstance(value, str):
            raise ValueError("integer native ns must remain a decimal string")
        return {
            "authority": authority,
            "epoch": epoch,
            "unit": "ns",
            "representation": "integer-decimal",
            "value": value,
            "source": raw,
        }
    if unit != "s" or type(value) not in (int, float):
        raise ValueError("native float seconds require their explicit s unit")
    native = float(value)
    return {
        "authority": authority,
        "epoch": epoch,
        "unit": "s",
        "representation": "ieee754-binary64",
        "value": native,
        "hex": native.hex(),
        "source": raw,
    }


def webots(
    documents: dict[str, dict[str, Any]], digests: dict[str, str]
) -> tuple[dict[str, Any], str]:
    controller = documents["controller-result.json"]
    worker = documents["worker-result.json"]
    pre = documents["pre-reset.json"]
    if (
        controller["status"] != "completed"
        or worker["status"] != "completed"
        or worker["processes_reaped"] is not True
        or worker["evidence_exported_before_stop"] is not True
    ):
        raise ValueError("accepted Webots check outcome is missing")
    if controller["time"] != {
        "authority": "Webots Supervisor.getTime",
        "native_unit": "seconds",
        "representation": "float64",
        "epoch": controller["owner_id"] + ":initial",
    }:
        raise ValueError("native Webots time identity differs")
    if (
        pre["last_native_state"] != controller["last_native_state"]
        or pre["reset"]["requested"] is not True
        or pre["reset"]["observed"] is not False
    ):
        raise ValueError("retained pre-reset native snapshot differs")
    if controller["reset"]["observed"] is not True:
        raise ValueError("accepted Webots reset effect is missing")
    digest = digests["controller-result.json"]
    times = []
    operations = []
    for index, row in enumerate(controller["samples"]):
        times.extend(
            time_value(
                row[key],
                "s",
                controller["time"]["authority"],
                controller["time"]["epoch"],
                source(digest, f"/samples/{index}/{key}"),
            )
            for key in ["before_seconds", "after_seconds"]
        )
        operations.append(
            {
                "native_api": "Supervisor.step",
                "request": source(digest, f"/samples/{index}/request_ms"),
                "result": {
                    "kind": "native-return",
                    "source": source(digest, f"/samples/{index}/result"),
                },
                "effect": {
                    "observed": True,
                    "source": source(digest, f"/samples/{index}"),
                },
            }
        )
    times.extend(
        [
            time_value(
                controller["reset"]["before_seconds"],
                "s",
                controller["time"]["authority"],
                controller["time"]["epoch"],
                source(digest, "/reset/before_seconds"),
            ),
            time_value(
                controller["reset"]["after_seconds"],
                "s",
                controller["time"]["authority"],
                controller["reset"]["epoch"],
                source(digest, "/reset/after_seconds"),
            ),
        ]
    )
    operations.append(
        {
            "native_api": "Supervisor.simulationReset",
            "request": source(digests["pre-reset.json"], "/reset"),
            "result": {
                "kind": "native-void-return",
                "source": source(digest, "/reset"),
            },
            "effect": {"observed": True, "source": source(digest, "/reset")},
        }
    )
    frame = {
        "native_name": "Webots world",
        "native_basis": controller["world"]["coordinate_system"],
        "position_unit": "m",
        "up_axis": "Z",
        "source": source(digest, "/world"),
    }
    return {
        "scope": "native-cpu-source",
        "backend": "webots",
        "native_execution_id": controller["owner_id"],
        "execution_evaluation": "accepted-source-proof",
        "native_times": times,
        "frame": frame,
        "lifecycle": {
            "evidence_before_destructive_reset": True,
            "cleanup_verified": True,
            "cleanup_evidence_scope": "registered-native-process-groups",
            "source": source(digests["worker-result.json"], ""),
        },
        "operations": operations,
    }, controller["owner_id"]


def gazebo(
    documents: dict[str, dict[str, Any]], digests: dict[str, str]
) -> tuple[dict[str, Any], str]:
    native = documents["independent-retained-review.json"]
    digest = digests["independent-retained-review.json"]
    if (
        native["completionStatus"] != "passed"
        or native["errors"]
        or native["sourceMountPresent"] is not False
        or native["verifiedRefCount"] <= 0
    ):
        raise ValueError("accepted Gazebo source lifecycle/retention outcome missing")
    if any(
        not row["attempted"] or not row["released"] or row.get("cleanupError")
        for row in native["resourceOutcomes"]
    ):
        raise ValueError("Gazebo physical cleanup is not established")
    conformance = native["provider"]["conformance.json"]["value"]
    observation = native["provider"]["observation.json"]["value"]
    if conformance["status"] != "passed" or observation["status"] != "passed":
        raise ValueError("native simulation conformance not passed")
    times = [
        time_value(
            str(value),
            "ns",
            "Gazebo ROS simulation_interfaces Clock",
            native["runId"] + ":initial",
            source(digest, "/provider/observation.json/value/clock/" + key),
        )
        for key, value in observation["clock"].items()
    ]
    reset = documents["native-reset-probe.json"]
    reset_digest = digests["native-reset-probe.json"]
    if (
        reset.get("passed") is not True
        or reset.get("unsupportedPartialEffectAbsent") is not True
    ):
        raise ValueError("accepted native unsupported-operation check missing")
    partial = next(
        (
            index
            for index, row in enumerate(reset["requests"])
            if row["service"] == "/simulator/reset_simulation"
        ),
        None,
    )
    if partial is None:
        raise ValueError("actual unsupported partial request missing")
    operations = [
        {
            "native_api": "simulation_interfaces ResetSimulation partial TIME",
            "request": source(reset_digest, f"/requests/{partial}/request"),
            "result": {
                "kind": "native-return",
                "source": source(reset_digest, f"/requests/{partial}/response"),
            },
            "effect": {
                "observed": True,
                "source": source(reset_digest, "/afterPartial"),
            },
        }
    ]
    return {
        "scope": "native-cpu-source",
        "backend": "gazebo",
        "native_execution_id": native["runId"],
        "execution_evaluation": "accepted-source-proof",
        "native_times": times,
        "frame": {
            "native_name": "world",
            "native_basis": "Gazebo world XYZ Z-up",
            "position_unit": "m",
            "up_axis": "Z",
            "source": source(digest, "/provider/configuration.json/value"),
        },
        "lifecycle": {
            "evidence_before_destructive_reset": None,
            "cleanup_verified": True,
            "cleanup_evidence_scope": "native-project-inventory",
            "source": source(digest, "/resourceOutcomes"),
        },
        "operations": operations,
    }, native["runId"]


def isaac(
    documents: dict[str, dict[str, Any]], digests: dict[str, str]
) -> tuple[dict[str, Any], str]:
    native = documents["representative.json"]
    digest = digests["representative.json"]
    if (
        native["kind"] != "representative-fixture"
        or native["execution_evaluation"] != "unevaluated"
    ):
        raise ValueError("Isaac representative input cannot claim execution")
    return {
        "scope": "representative",
        "backend": "isaac",
        "native_execution_id": native["native_execution_id"],
        "execution_evaluation": "unevaluated",
        "native_times": [
            time_value(
                native["time"]["value"],
                "s",
                native["time"]["authority"],
                "representative-unobserved",
                source(digest, "/time/value"),
            )
        ],
        "frame": {**native["frame"], "source": source(digest, "/frame")},
        "lifecycle": {
            "evidence_before_destructive_reset": None,
            "cleanup_verified": None,
            "cleanup_evidence_scope": "unobserved",
            "source": source(digest, ""),
        },
        "operations": [
            {
                "native_api": "World.step",
                "request": source(digest, "/operation/request"),
                "result": {
                    "kind": "unobserved",
                    "source": source(digest, "/operation/result"),
                },
                "effect": {
                    "observed": None,
                    "source": source(digest, "/operation/effect"),
                },
            }
        ],
    }, native["native_execution_id"]


def produce(
    backend: str,
    input_root: Path,
    manifest_path: Path,
    schema_path: Path,
    output: Path,
    *,
    generated_at: str,
    run_id: str,
) -> dict[str, Path]:
    if output.exists():
        raise FileExistsError("qualification output directory must be new")
    if backend not in ["gazebo", "webots", "isaac"]:
        raise ValueError("missing or unsupported provider")
    manifest = load_mapping(manifest_path)
    if manifest["backend"] != backend:
        raise ValueError("selected provider does not match admitted native inputs")
    raw_schema = schema_path.read_bytes()
    schemas = {SCHEMA_URI: raw_schema}
    documents = {}
    digests = {}
    template = {
        "run_id": run_id,
        "generated_at": generated_at,
        "policy_observation": {
            "recording_mode": "native-artifact",
            "compression": "none",
            "retention_class": "source-fixture",
            "upload_mode": "local_only",
            "remote_sink_used": False,
            "spool_peak_size_bytes": sum(
                row["size_bytes"] for row in manifest["files"].values()
            ),
            "upload_lag_max_sec": 0,
        },
    }
    draft = create_evidence_index(template)
    output.mkdir(parents=True, exist_ok=False)
    for name, expected in manifest["files"].items():
        path = input_root / name
        protect_inputs(
            output / "evidence-index.json", [path, manifest_path, schema_path]
        )
        metadata = {
            "artifact_id": backend + "-" + name.removesuffix(".json").replace(".", "-"),
            "kind": "native-source-evidence",
            "media_type": "application/json",
            "retention_class": "source-fixture",
            "storage_state": "local",
            **expected,
        }
        # The public writer binds original bytes before any retained copy or document verdict.
        add_evidence_artifact(create_evidence_index(template), path, metadata)
        retained = output / "raw" / name
        protect_inputs(retained, [path, manifest_path, schema_path])
        write_bytes_atomically(path.read_bytes(), retained)
        draft = add_evidence_artifact(draft, retained, metadata)
        digests[name] = expected["sha256"]
        documents[name] = load_mapping(retained)
    index = finalize_evidence_index(draft)
    native, execution_id = {"gazebo": gazebo, "webots": webots, "isaac": isaac}[
        backend
    ](documents, digests)
    profile = {
        "schema_version": "qualification-profile.v1",
        "profile_id": "native-cpu-source-" + backend,
        "provider_kind": "simulator",
        "requirements": [{"capability": c, "required": True} for c in CAPABILITIES],
    }
    profile_path = output / "qualification-profile.json"
    for destination in [
        profile_path,
        output / "conformance-result.json",
        output / "evidence-index.json",
    ]:
        protect_inputs(
            destination,
            [
                manifest_path,
                schema_path,
                *[input_root / name for name in manifest["files"]],
            ],
        )
    write_document(profile, profile_path)
    status = "skipped" if backend == "isaac" else "passed"
    capabilities = [] if backend == "isaac" else CAPABILITIES
    result = {
        "schema_version": "conformance-result.v1",
        "result_id": "native-source-" + backend,
        "run_id": run_id,
        "generated_at": generated_at,
        "qualification_profile_sha256": sha256(profile_path.read_bytes()).hexdigest(),
        "execution_subject_digest": manifest["executionSubjectDigest"],
        "provider": {
            "kind": "simulator",
            "implementation_id": backend,
            "version": manifest["version"],
            "configuration_sha256": sha256(manifest_path.read_bytes()).hexdigest(),
        },
        "target_id": "native-source-" + backend,
        "status": status,
        "capabilities": capabilities,
        "checks": [
            {
                "check_id": "accepted-source-" + c.replace("_", "-"),
                "capability": c,
                "status": status,
                "observed_value": None if backend == "isaac" else execution_id,
                "message": "Representative shape only; execution unevaluated."
                if backend == "isaac"
                else "Projected from accepted byte-bound native source check.",
            }
            for c in CAPABILITIES
        ],
        "evidence": [
            {
                "uri": row["uri"],
                "sha256": row["sha256"],
                "size_bytes": row["size_bytes"],
                "media_type": row["media_type"],
            }
            for row in index["artifacts"]
        ],
        "extension_schemas": [
            {
                "namespace": NAMESPACE,
                "schema_uri": SCHEMA_URI,
                "sha256": sha256(raw_schema).hexdigest(),
            }
        ],
        "extensions": {NAMESPACE: native},
    }
    validate_document(result, extension_schemas=schemas)
    if backend != "isaac":
        validate_provider_requirements(
            {"capabilities": CAPABILITIES}, [{"capabilities": result["capabilities"]}]
        )
    evidence_path = output / "evidence-index.json"
    result_path = output / "conformance-result.json"
    write_document(index, evidence_path)
    write_document(result, result_path, extension_schemas=schemas)
    return {
        "profile": profile_path,
        "conformance": result_path,
        "evidence": evidence_path,
    }


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--backend", required=True)
    p.add_argument("--inputs", type=Path, required=True)
    p.add_argument("--manifest", type=Path, required=True)
    p.add_argument("--schema", type=Path, required=True)
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--run-id", default="run-" + str(uuid4()))
    p.add_argument("--generated-at", default=datetime.now(timezone.utc).isoformat())
    a = p.parse_args()
    produce(
        a.backend,
        a.inputs,
        a.manifest,
        a.schema,
        a.output,
        generated_at=a.generated_at,
        run_id=a.run_id,
    )


if __name__ == "__main__":
    main()
