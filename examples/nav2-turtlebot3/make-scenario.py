"""Write native Nav2 v2 inputs before execution through public document APIs."""

from __future__ import annotations

import argparse
import json
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

from robotics_acceptance_harness.evaluator_trust import read_once
from robotics_acceptance_harness.run_context import create_run_context
from robotics_runtime_contracts import dumps_canonical, loads_mapping
from robotics_runtime_contracts.writers import write_bytes_atomically, write_document

NAMESPACE = "org.example.nav2-turtlebot3"


def reference(path: Path, media_type: str = "application/json") -> dict:
    raw = path.read_bytes()
    return {
        "uri": path.resolve().as_uri(),
        "sha256": sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "media_type": media_type,
    }


def prepare(
    profile_path: Path,
    requirements_path: Path,
    output: Path,
    *,
    run_id: str | None = None,
) -> dict:
    """Consume the exact admitted native profile; never start a robot or simulator."""
    profile_raw = read_once(profile_path, 1024 * 1024)
    profile = loads_mapping(profile_raw, source_name=str(profile_path))
    requirements = loads_mapping(
        read_once(requirements_path, 1024 * 1024), source_name=str(requirements_path)
    )
    if profile["profile_id"] != NAMESPACE:
        raise ValueError("the native profile must be the selected Nav2 consumer")
    if set(requirements) != {"evaluator_requirement", "configuration", "case"}:
        raise ValueError("closed Nav2 pre-execution requirements are required")
    if requirements["case"] not in {"success", "cancel", "timeout", "server-failure"}:
        raise ValueError("unknown Nav2 native case")
    if requirements["configuration"].get("case") != requirements["case"]:
        raise ValueError("Nav2 configuration differs from the selected native case")
    if set(profile.get("executor", {})) != {"implementation", "version"}:
        raise ValueError(
            "exact admitted native executor implementation/version required"
        )
    if "clock" not in profile:
        raise ValueError("the Nav2 profile requires its actual declared clock")
    # The profile supplies native IDL/backend/encoding/recorder/executor/clock
    # declarations from its composition, not invented defaults.
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    configuration = output / "nav2-configuration.json"
    schema_path = Path(__file__).with_name("nav2.schema.json")
    write_bytes_atomically(
        dumps_canonical(requirements["configuration"]), configuration
    )
    selected_profile = dict(profile)
    selected_profile["executor"] = {
        **profile["executor"],
        "configuration": reference(configuration),
    }
    profile_snapshot = output / "native-profile.json"
    write_bytes_atomically(profile_raw, profile_snapshot)
    scenario = {
        "schema_version": "acceptance-scenario.v2",
        "scenario_id": "nav2-turtlebot3-" + requirements["case"],
        "execution": {
            "target_environment": "simulation",
            "data_source": "native-ros-nav2",
            "plant_backend": "Gazebo-Harmonic",
            "time_mode": "simulation_realtime",
        },
        "profile": selected_profile,
        "metric_definitions": [],
        "assertions": [],
        "evaluator_requirements": [requirements["evaluator_requirement"]],
        "evidence_policy": {
            "max_artifact_size_bytes": 64 * 1024**2,
            "max_archive_size_bytes": 128 * 1024**2,
            "max_upload_lag_sec": 0,
            "upload_mode": "local_only",
            "retention_class": "test-evidence",
            "remote_sink_allowed": False,
        },
    }
    schema_raw = read_once(schema_path, 1024 * 1024)
    schema_snapshot = output / "nav2.schema.json"
    write_bytes_atomically(schema_raw, schema_snapshot)
    schema_uri = "urn:nav2-turtlebot3:scenario:v1"
    scenario["extension_schemas"] = [
        {
            "namespace": NAMESPACE,
            "schema_uri": schema_uri,
            "sha256": sha256(schema_raw).hexdigest(),
        }
    ]
    scenario["extensions"] = {NAMESPACE: requirements["configuration"]}
    scenario_path, runtime_path = output / "scenario.json", output / "runtime.json"
    write_document(scenario, scenario_path, extension_schemas={schema_uri: schema_raw})
    runtime = {
        "schema_version": "runtime-manifest.v2",
        "runtime_id": "nav2-turtlebot3-native",
        "generated_at": datetime.now(UTC).isoformat(),
        "scenario_sha256": reference(scenario_path)["sha256"],
        "execution": scenario["execution"],
        "profile": selected_profile,
        "evaluator_bindings": scenario["evaluator_requirements"],
    }
    write_document(runtime, runtime_path)
    context_path = output / "run.json"
    issued = create_run_context(
        scenario_path,
        context_path,
        domains={"nav2": "simulation"},
        time_authority=selected_profile["clock"]["kind"],
        time_source=selected_profile["clock"]["source_id"],
        run_id=run_id,
        extension_schemas={schema_uri: schema_raw},
    )
    manifest = {
        "run_id": issued,
        "domain_id": "nav2",
        "scenario": reference(scenario_path),
        "runtime": reference(runtime_path),
        "run_context": reference(context_path),
        "configuration": reference(configuration),
        "native_profile": reference(profile_snapshot),
        "extension_schema": reference(schema_snapshot),
    }
    write_bytes_atomically(
        dumps_canonical(manifest), output / "pre-execution-inputs.json"
    )
    return manifest


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--profile", type=Path, required=True)
    parser.add_argument("--requirements", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-id")
    args = parser.parse_args()
    print(
        json.dumps(
            prepare(args.profile, args.requirements, args.output, run_id=args.run_id)
        )
    )


if __name__ == "__main__":
    main()
