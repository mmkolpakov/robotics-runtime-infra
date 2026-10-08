"""Bind a successful simulation_interfaces probe to retained provider evidence."""

from __future__ import annotations

import argparse
import hashlib
import json
import sys
from datetime import datetime, timezone
from decimal import Decimal, InvalidOperation
from pathlib import Path
from typing import Any
from xml.etree import ElementTree

from robotics_runtime_contracts import loads_mapping, validate_document
from robotics_runtime_contracts.providers import validate_provider_requirements
from robotics_runtime_contracts.serialization import read_document_bytes
from robotics_runtime_contracts.writers import protect_inputs, write_document


def read_mapping(path: Path) -> tuple[dict[str, Any], bytes]:
    raw = read_document_bytes(path)
    return dict(loads_mapping(raw, source_name=str(path))), raw


def digest(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def reference(path: Path, raw: bytes, media_type: str) -> dict[str, Any]:
    return {
        "uri": path.resolve().as_uri(),
        "sha256": digest(raw),
        "size_bytes": len(raw),
        "media_type": media_type,
    }


def positive_integer(value: object, label: str, *, zero: bool = False) -> int:
    if type(value) is not int or value < (0 if zero else 1):
        raise ValueError(
            f"{label} must be a {'nonnegative' if zero else 'positive'} integer"
        )
    return value


def checked_clock(report: dict[str, Any], world: bytes) -> int:
    if report.get("schema_version") != "simulation-conformance.v1":
        raise ValueError("unsupported simulation probe report")
    if report.get("status") != "passed":
        raise ValueError("simulation probe did not pass")
    steps = positive_integer(report.get("steps"), "probe steps")
    size = positive_integer(report.get("step_size_ns"), "probe step_size_ns")
    clock = report.get("clock")
    if not isinstance(clock, dict):
        raise ValueError("probe clock observations are missing")
    playing, paused, stepped, resumed = (
        positive_integer(clock.get(name), f"probe clock {name}", zero=True)
        for name in ("playing_ns", "paused_ns", "stepped_ns", "resumed_ns")
    )
    if not playing <= paused < stepped < resumed or stepped - paused != steps * size:
        raise ValueError(
            "probe clock observations contradict exact stepping and resume"
        )
    root = ElementTree.fromstring(world)
    worlds = root.findall("world")
    if root.tag != "sdf" or len(worlds) != 1:
        raise ValueError("provider evidence must contain exactly one SDF world")
    configured_steps = worlds[0].findall("physics/max_step_size")
    if len(configured_steps) != 1 or configured_steps[0].text is None:
        raise ValueError("the SDF world must declare one unambiguous physics step size")
    configured_ns = Decimal(configured_steps[0].text) * 1_000_000_000
    if not configured_ns.is_finite() or configured_ns != size:
        raise ValueError("probe step size does not match retained SDF configuration")
    return steps * size


def create_result(
    arguments: argparse.Namespace, *, now: datetime
) -> tuple[dict[str, Any], dict[str, Any]]:
    scenario, scenario_raw = read_mapping(arguments.scenario)
    run, _ = read_mapping(arguments.run_context)
    profile, profile_raw = read_mapping(arguments.profile)
    configuration, configuration_raw = read_mapping(arguments.configuration)
    report, report_raw = read_mapping(arguments.observation)
    world_raw = read_document_bytes(arguments.world)
    validate_document(scenario, schema="acceptance-scenario.v1")
    validate_document(run, schema="acceptance-run.v1")
    validate_document(profile, schema="qualification-profile.v1")
    if run["scenario_sha256"] != digest(scenario_raw):
        raise ValueError("run context does not bind the supplied scenario bytes")
    if run["scenario_id"] != scenario["scenario_id"]:
        raise ValueError("run context does not identify the supplied scenario")
    if now.tzinfo is None or now.utcoffset() is None:
        raise ValueError("conformance generation time must include a timezone")
    if (
        profile["provider_kind"] != "simulator"
        or configuration.get("implementation_id") != "gz_sim"
    ):
        raise ValueError(
            "this producer requires a simulator profile and gz_sim configuration"
        )
    if any(
        item["required"] and item["capability"] != "simulated_physics"
        for item in profile["requirements"]
    ):
        raise ValueError(
            "the baseline probe does not qualify the requested profile capabilities"
        )
    if (
        configuration.get("service_namespace") != report.get("service_namespace")
        or not isinstance(configuration.get("service_namespace"), str)
        or not configuration["service_namespace"].startswith("/")
    ):
        raise ValueError("probe namespace does not match provider configuration")
    world_size = positive_integer(
        configuration.get("world_size_bytes"), "configuration world_size_bytes"
    )
    if configuration.get("world_sha256") != digest(world_raw) or world_size != len(
        world_raw
    ):
        raise ValueError("provider configuration does not bind retained world bytes")
    delta = checked_clock(report, world_raw)
    if scenario["execution"]["time_mode"] == "simulation_stepped":
        requested = (
            Decimal(str(scenario["time_policy"]["step_size_sec"])) * 1_000_000_000
        )
        if requested != report["step_size_ns"]:
            raise ValueError(
                "probe step size does not satisfy the scenario time policy"
            )
    provider = {
        "kind": "simulator",
        "implementation_id": "gz_sim",
        "version": configuration.get("version"),
        "configuration_sha256": digest(configuration_raw),
    }
    result = {
        "schema_version": "conformance-result.v1",
        "result_id": "simulation-interfaces-conformance",
        "run_id": run["run_id"],
        "generated_at": now.astimezone(timezone.utc).isoformat(),
        "qualification_profile_sha256": digest(profile_raw),
        "execution_subject_digest": arguments.subject_digest,
        "provider": provider,
        "target_id": "simulation-primary",
        "status": "passed",
        "capabilities": ["simulated_physics"],
        "checks": [
            {
                "check_id": "standard-simulation-control",
                "capability": "simulated_physics",
                "status": "passed",
                "observed_value": delta,
                "unit": "ns",
                "message": "Standard interface probe passed pause, exact stepping and resume.",
            }
        ],
        "evidence": [
            reference(arguments.observation, report_raw, "application/json"),
            reference(arguments.world, world_raw, "application/sdf+xml"),
        ],
    }
    validate_document(result)
    binding = {
        key: result[key]
        for key in (
            "provider",
            "target_id",
            "capabilities",
            "qualification_profile_sha256",
        )
    }
    validate_provider_requirements(scenario["provider_requirements"], [binding])
    return result, binding


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    for name in (
        "scenario",
        "run-context",
        "profile",
        "configuration",
        "observation",
        "world",
        "output",
    ):
        parser.add_argument(f"--{name}", type=Path, required=True)
    parser.add_argument("--subject-digest", required=True)
    args = parser.parse_args()
    try:
        protect_inputs(
            args.output,
            [
                args.scenario,
                args.run_context,
                args.profile,
                args.configuration,
                args.observation,
                args.world,
            ],
        )
        result, binding = create_result(args, now=datetime.now(timezone.utc))
        output = write_document(result, args.output)
        binding["conformance_result_sha256"] = digest(read_document_bytes(output))
        print(json.dumps([binding], allow_nan=False, sort_keys=True))
    except (OSError, ValueError, InvalidOperation, ElementTree.ParseError) as error:
        print(f"simulation provider: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
