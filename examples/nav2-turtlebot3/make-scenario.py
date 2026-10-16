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
DOCUMENT_LIMIT = 1024 * 1024


def reference(path: Path, media_type: str = "application/json") -> dict:
    raw = path.read_bytes()
    return {
        "uri": path.resolve().as_uri(),
        "sha256": sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "media_type": media_type,
    }


def prepare(
    profile_path: Path | None,
    requirements_path: Path,
    output: Path,
    *,
    run_id: str | None = None,
    native_preflight: Path | None = None,
    image_reference: str | None = None,
    image_id: str | None = None,
) -> dict:
    """Consume the exact admitted native profile; never start a robot or simulator."""
    native = None
    if native_preflight is not None:
        native_raw = read_once(native_preflight, 8 * DOCUMENT_LIMIT)
        native = loads_mapping(native_raw)
        facts = check_preflight(native, image_reference, image_id)
        profile = native_profile(facts)
        profile_raw = dumps_canonical(profile)
    else:
        profile_raw = read_once(profile_path, DOCUMENT_LIMIT)
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
    readiness = requirements["configuration"].get("readiness")
    if not isinstance(readiness, dict):
        raise ValueError("explicit consumer graph readiness configuration is required")
    budget, stable = readiness.get("timeout_sec"), readiness.get("stable_for_sec")
    if (
        isinstance(budget, bool)
        or not isinstance(budget, (int, float))
        or isinstance(stable, bool)
        or not isinstance(stable, (int, float))
        or not 0 < budget <= 10
        or not 0 <= stable < budget
    ):
        raise ValueError("consumer readiness stability must fit its bounded deadline")
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
    if native is not None:
        import base64

        for kind in ("model", "world"):
            write_bytes_atomically(
                base64.b64decode(facts["rendered"][kind]["base64"], validate=True),
                output / ("native-" + kind + ".sdf"),
            )
        model = output / "native-model.json"
        descriptor = {
            "kind": "declared_nav2_inputs",
            "loaded_model_state": "unobserved",
            "source_files": {
                key: {k: v for k, v in item.items() if k != "base64"}
                for key, item in facts["files"].items()
            },
            "expanded_model": reference(output / "native-model.sdf", "application/xml"),
            "expanded_world": reference(output / "native-world.sdf", "application/xml"),
            "launch": NATIVE_LAUNCH,
        }
        write_bytes_atomically(dumps_canonical(descriptor), model)
        write_bytes_atomically(native_raw, output / "native-preflight.json")
        scenario["native_model"] = reference(model)
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
    if native is not None:
        runtime["native_model"] = scenario["native_model"]
        runtime["execution_subject"] = {
            "kind": "oci_image",
            "locator": (
                "oci://local-image/image@" + image_id
                if image_reference == image_id
                else "oci://" + image_reference
            ),
            "digest": image_reference.rsplit("@", 1)[-1],
        }
    write_document(runtime, runtime_path)
    from robotics_acceptance_harness.documents import load_bundle

    load_bundle(
        scenario_path,
        runtime_path=runtime_path,
        extension_schemas={schema_uri: schema_raw},
    )
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
    if native is not None:
        manifest["native_preflight"] = reference(output / "native-preflight.json")
        manifest["native_model"] = reference(output / "native-model.json")
        manifest["expanded_model"] = reference(
            output / "native-model.sdf", "application/xml"
        )
        manifest["expanded_world"] = reference(
            output / "native-world.sdf", "application/xml"
        )
    write_bytes_atomically(
        dumps_canonical(manifest), output / "pre-execution-inputs.json"
    )
    return manifest


NATIVE_LAUNCH = [
    "ros2",
    "launch",
    "nav2_bringup",
    "tb3_simulation_launch.py",
    "headless:=True",
    "use_rviz:=False",
    "slam:=False",
    "use_composition:=False",
    "use_respawn:=False",
    "robot_sdf:=/consumer/inputs/native-model.sdf",
    "world:=/consumer/inputs/native-world.sdf",
    "map:=/opt/ros/jazzy/share/nav2_bringup/maps/tb3_sandbox.yaml",
]
NATIVE_FILES = {
    "model": "/opt/ros/jazzy/share/nav2_minimal_tb3_sim/urdf/gz_waffle.sdf.xacro",
    "world": "/opt/ros/jazzy/share/nav2_minimal_tb3_sim/worlds/tb3_sandbox.sdf.xacro",
    "map": "/opt/ros/jazzy/share/nav2_bringup/maps/tb3_sandbox.yaml",
    "launch": "/opt/ros/jazzy/share/nav2_bringup/launch/tb3_simulation_launch.py",
}
NATIVE_TOPICS = {
    "/odom": "nav_msgs/msg/Odometry",
    "/tf": "tf2_msgs/msg/TFMessage",
    "/tf_static": "tf2_msgs/msg/TFMessage",
    "/clock": "rosgraph_msgs/msg/Clock",
    "/amcl_pose": "geometry_msgs/msg/PoseWithCovarianceStamped",
    "/navigate_to_pose/_action/feedback": "nav2_msgs/action/NavigateToPose_FeedbackMessage",
    "/navigate_to_pose/_action/status": "action_msgs/msg/GoalStatusArray",
}


def inspect_image() -> dict:
    """Read the selected image without loading ROS or starting a native node."""
    import base64
    import importlib.metadata
    import runpy
    import subprocess

    policy_root = Path("/opt/sdk-policy")
    policy = loads_mapping(read_once(policy_root / "inputs.lock.json", DOCUMENT_LIMIT))
    receipt = loads_mapping(read_once(policy_root / "image-build.json", DOCUMENT_LIMIT))
    runpy.run_path(str(policy_root / "check-sdk-wheels.py"))["check"](
        Path("/opt/sdk-cohort/wheels")
    )
    versions = {
        name: importlib.metadata.version(name)
        for name in ("robotics-runtime-contracts", "robotics-acceptance-harness")
    }
    subprocess.run(
        ["/opt/consumer/bin/python", "-I", "-m", "pip", "check"],
        check=True,
        capture_output=True,
        timeout=20,
    )
    packages = {}
    for name in policy["packages"]:
        row = subprocess.run(
            ["dpkg-query", "-W", "-f=${Version}\\t${Architecture}", name],
            check=True,
            capture_output=True,
            text=True,
            timeout=5,
        ).stdout.split("\t")
        packages[name] = {"version": row[0], "architecture": row[1]}
    verified = subprocess.run(
        ["dpkg", "--verify", *policy["packages"]],
        check=True,
        capture_output=True,
        text=True,
        timeout=20,
    )
    if verified.stdout or verified.stderr:
        raise ValueError("installed native package files differ from the build receipt")
    installed = subprocess.check_output(
        ["dpkg-query", "-W", "-f=${Package}\t${Version}\t${Architecture}\n"]
    )
    if sha256(installed).hexdigest() != receipt["installed_packages_sha256"]:
        raise ValueError(
            "native transitive package inventory differs from build receipt"
        )
    files = {}
    for name, expected in receipt["files"].items():
        path = Path(expected["path"])
        raw = read_once(path, 8 * DOCUMENT_LIMIT)
        if (
            sha256(raw).hexdigest() != expected["sha256"]
            or len(raw) != expected["size_bytes"]
        ):
            raise ValueError("installed native input differs: " + name)
        files[name] = {**expected, "base64": base64.b64encode(raw).decode("ascii")}
    rendered = {}
    for name in ("model", "world"):
        command = ["/opt/ros/jazzy/bin/xacro", NATIVE_FILES[name]]
        if name == "world":
            command.append("headless:=True")
        raw = subprocess.run(
            command, check=True, capture_output=True, timeout=20
        ).stdout
        if not raw or len(raw) > 8 * DOCUMENT_LIMIT:
            raise ValueError("native xacro output is empty or over budget")
        rendered[name] = {
            "sha256": sha256(raw).hexdigest(),
            "size_bytes": len(raw),
            "base64": base64.b64encode(raw).decode("ascii"),
            "argv": command,
        }
    return {
        "rendered": rendered,
        "build": receipt,
        "packages": packages,
        "sdk_versions": versions,
        "type_support_version": subprocess.check_output(
            [
                "dpkg-query",
                "-W",
                "-f=${Version}",
                "ros-jazzy-rosidl-typesupport-fastrtps-cpp",
            ],
            text=True,
        ).strip(),
        "files": files,
        "launch": NATIVE_LAUNCH,
        "middleware_sha256": sha256(
            read_once(Path(__file__).with_name("fastdds.xml"), DOCUMENT_LIMIT)
        ).hexdigest(),
    }


def check_preflight(document: dict, image_reference: str, image_id: str) -> dict:
    import base64
    import re

    local = re.fullmatch(r"sha256:[a-f0-9]{64}", image_reference)
    if not local and not re.fullmatch(r"[^\s@]+@sha256:[a-f0-9]{64}", image_reference):
        raise ValueError("an immutable local Config ID or RepoDigest is required")
    if not re.fullmatch(r"sha256:[a-f0-9]{64}", image_id):
        raise ValueError("an exact image Config ID is required")
    image = document["image"]
    if image["Id"] != image_id or (
        image_reference != image_id
        if local
        else image_reference not in image.get("RepoDigests", [])
    ):
        raise ValueError(
            "selected RepoDigest does not resolve to the admitted Config ID"
        )
    facts = document["facts"]
    root = Path(__file__).parent
    policy_raw = read_once(root / "inputs.lock.json", DOCUMENT_LIMIT)
    policy = loads_mapping(policy_raw)
    build = facts["build"]
    if build["policy_sha256"] != sha256(policy_raw).hexdigest():
        raise ValueError("image package policy differs")
    if (
        build["dockerfile_sha256"]
        != sha256(read_once(root / "Dockerfile", DOCUMENT_LIMIT)).hexdigest()
    ):
        raise ValueError("image recipe differs")
    if facts["sdk_versions"] != {
        "robotics-runtime-contracts": "0.21.1",
        "robotics-acceptance-harness": "0.22.2",
    }:
        raise ValueError("native image SDK differs from the published cohort")
    if set(facts["packages"]) != set(policy["packages"]):
        raise ValueError("native package set differs")
    for name, expected in policy["packages"].items():
        actual = facts["packages"][name]
        if (
            actual["version"] != expected["Version"]
            or actual["architecture"] != "amd64"
        ):
            raise ValueError("native package identity differs: " + name)
        if build["packages"][name] != {
            "version": expected["Version"],
            "sha256": expected["SHA256"],
        }:
            raise ValueError("native package build chain differs: " + name)
    if facts["launch"] != NATIVE_LAUNCH:
        raise ValueError("native launch differs")
    if set(NATIVE_FILES) - set(facts["files"]):
        raise ValueError("native model/world/map/launch evidence is missing")
    for name, expected in facts["files"].items():
        if name in NATIVE_FILES and expected["path"] != NATIVE_FILES[name]:
            raise ValueError("native input path differs: " + name)
        raw = base64.b64decode(expected["base64"], validate=True)
        identity = {key: expected[key] for key in ("path", "sha256", "size_bytes")}
        if (
            identity != build["files"][name]
            or len(raw) != expected["size_bytes"]
            or sha256(raw).hexdigest() != expected["sha256"]
        ):
            raise ValueError("native input bytes differ: " + name)
    for value in facts["rendered"].values():
        raw = base64.b64decode(value["base64"], validate=True)
        if (
            not raw
            or len(raw) != value["size_bytes"]
            or sha256(raw).hexdigest() != value["sha256"]
        ):
            raise ValueError("native expanded model bytes differ")
    if (
        facts["middleware_sha256"]
        != sha256(read_once(root / "fastdds.xml", DOCUMENT_LIMIT)).hexdigest()
    ):
        raise ValueError("native middleware configuration differs")
    return facts


def native_profile(facts: dict) -> dict:
    """Declare only the concrete image inputs; no claim of loaded model state."""
    return {
        "profile_id": NAMESPACE,
        "executor": {
            "implementation": NAMESPACE,
            "version": sha256(
                read_once(Path(__file__).with_name("workload.py"), DOCUMENT_LIMIT)
            ).hexdigest(),
        },
        "channels": [
            {
                "name": name,
                "original_type": {
                    "name": type_name,
                    "type_support": {
                        "implementation": "rosidl",
                        "version": facts["type_support_version"],
                    },
                },
                "backend": "ROS-DDS",
                "wire_envelope": "native-ROS-message",
                "native_encoding": "CDR",
                "recorder": {
                    "implementation": "rosbag2",
                    "version": "0.26.11",
                    "transformation": "none",
                },
            }
            for name, type_name in NATIVE_TOPICS.items()
        ],
        "clock": {"kind": "sim_clock", "source_id": "gazebo-harmonic-clock"},
        "observations": {
            "command": {"kind": "command_acceptance", "requirement": "required"},
            "terminal": {"kind": "native_final_state", "requirement": "required"},
            "condition": {"kind": "postcondition", "requirement": "required"},
            "cleanup": {"kind": "shutdown", "requirement": "required"},
        },
    }


def validate_prepared(prepared: Path, *, image_id: str, case: str) -> dict:
    from robotics_acceptance_harness.documents import load_bundle
    from robotics_acceptance_harness.run_context import load_run_context

    manifest = loads_mapping(
        read_once(prepared / "pre-execution-inputs.json", DOCUMENT_LIMIT)
    )
    names = {
        "scenario": "scenario.json",
        "runtime": "runtime.json",
        "run_context": "run.json",
        "configuration": "nav2-configuration.json",
        "native_profile": "native-profile.json",
        "extension_schema": "nav2.schema.json",
        "native_preflight": "native-preflight.json",
        "native_model": "native-model.json",
        "expanded_model": "native-model.sdf",
        "expanded_world": "native-world.sdf",
    }
    for key, name in names.items():
        raw = read_once(prepared / name, 8 * DOCUMENT_LIMIT)
        identity = manifest.get(key, {})
        if identity.get("sha256") != sha256(raw).hexdigest() or identity.get(
            "size_bytes"
        ) != len(raw):
            raise ValueError("prepared input differs: " + key)
    schema = read_once(prepared / "nav2.schema.json", DOCUMENT_LIMIT)
    bundle = load_bundle(
        prepared / "scenario.json",
        runtime_path=prepared / "runtime.json",
        extension_schemas={"urn:nav2-turtlebot3:scenario:v1": schema},
    )
    scenario, runtime = bundle.scenario.as_dict(), bundle.runtime.as_dict()
    load_run_context(
        prepared / "run.json",
        run_id=manifest["run_id"],
        domain_id="nav2",
        scenario_id=scenario["scenario_id"],
        scenario_sha256=bundle.scenario.sha256,
    )
    preflight = loads_mapping(
        read_once(prepared / "native-preflight.json", 8 * DOCUMENT_LIMIT)
    )
    image_reference = preflight["image_reference"]
    facts = check_preflight(preflight, image_reference, image_id)
    descriptor = loads_mapping(
        read_once(prepared / "native-model.json", DOCUMENT_LIMIT)
    )
    for kind in ("model", "world"):
        expected = facts["rendered"][kind]
        reference_key = "expanded_" + kind
        actual = manifest[reference_key]
        declared = descriptor[reference_key]
        if any(
            actual[key] != expected[key] or declared[key] != expected[key]
            for key in ("sha256", "size_bytes")
        ):
            raise ValueError(
                "mounted native input differs from captured preflight: " + kind
            )
    subject = {
        "kind": "oci_image",
        "locator": (
            "oci://local-image/image@" + image_id
            if image_reference == image_id
            else "oci://" + image_reference
        ),
        "digest": image_reference.rsplit("@", 1)[-1],
    }
    if runtime.get("execution_subject") != subject:
        raise ValueError("runtime does not bind the selected RepoDigest")
    if (
        scenario["profile"]["executor"]["version"]
        != native_profile(facts)["executor"]["version"]
    ):
        raise ValueError("native executor source differs")
    from copy import deepcopy

    expected_profile = native_profile(facts)
    declared_profile = deepcopy(dict(scenario["profile"]))
    configuration_ref = declared_profile["executor"].pop("configuration")
    if declared_profile != expected_profile:
        raise ValueError("declared native profile differs from observed image")
    stored_profile = loads_mapping(
        read_once(prepared / "native-profile.json", DOCUMENT_LIMIT)
    )
    if stored_profile != expected_profile:
        raise ValueError("captured native profile differs")
    for key in ("sha256", "size_bytes"):
        if configuration_ref[key] != manifest["configuration"][key]:
            raise ValueError(
                "executor configuration reference differs from captured bytes"
            )
    configuration = scenario["extensions"][NAMESPACE]
    if (
        loads_mapping(read_once(prepared / "nav2-configuration.json", DOCUMENT_LIMIT))
        != configuration
    ):
        raise ValueError("captured configuration differs from the scenario")
    if (
        scenario["execution"]["target_environment"] != "simulation"
        or configuration["case"] != case
    ):
        raise ValueError("native execution or case differs")
    if (
        scenario["profile"]["profile_id"] != NAMESPACE
        or manifest["domain_id"] != "nav2"
    ):
        raise ValueError("foreign native profile")
    return {
        "run_id": manifest["run_id"],
        "domain_id": "nav2",
        "configuration": configuration,
        "image_id": image_id,
        "image_reference": image_reference,
        "launch": facts["launch"],
    }


def complete_native(prepared: Path, capture: Path) -> dict:
    """Bind closed records without turning action acknowledgements into physical facts."""
    from shutil import copyfile

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
        "native-model.json",
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
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--requirements", type=Path)
    parser.add_argument("--output", type=Path)
    parser.add_argument("--run-id")
    parser.add_argument("--native-preflight", type=Path)
    parser.add_argument("--image-reference")
    parser.add_argument("--image-id")
    parser.add_argument("--inspect-image", action="store_true")
    parser.add_argument("--validate-prepared", type=Path)
    parser.add_argument("--case")
    parser.add_argument("--complete-capture", type=Path)
    args = parser.parse_args()
    if args.inspect_image:
        result = inspect_image()
    elif args.validate_prepared:
        if args.complete_capture:
            result = complete_native(args.validate_prepared, args.complete_capture)
        else:
            result = validate_prepared(
                args.validate_prepared, image_id=args.image_id, case=args.case
            )
    else:
        if (
            not args.requirements
            or not args.output
            or not (args.profile or args.native_preflight)
        ):
            parser.error(
                "requirements, output and a profile or native preflight are required"
            )
        result = prepare(
            args.profile,
            args.requirements,
            args.output,
            run_id=args.run_id,
            native_preflight=args.native_preflight,
            image_reference=args.image_reference,
            image_id=args.image_id,
        )
    print(json.dumps(result))


if __name__ == "__main__":
    main()
