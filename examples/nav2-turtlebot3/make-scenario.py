"""Write native Nav2 v2 inputs before execution through public document APIs."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import sys
from contextlib import contextmanager
from tempfile import TemporaryDirectory, TemporaryFile
from uuid import uuid4
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

from robotics_acceptance_harness.evaluator_trust import read_once
from robotics_runtime_contracts import (
    dumps_canonical,
    load_schema,
    loads_mapping,
    schema_registry,
    validate_role,
)
from jsonschema import Draft202012Validator
from jsonschema.exceptions import ValidationError
from robotics_runtime_contracts.writers import write_bytes_atomically, write_document

NAMESPACE = "org.example.nav2-turtlebot3"
DOCUMENT_LIMIT = 1024 * 1024
CLI_OUTPUT_LIMIT = 4096


def reference(path: Path, raw: bytes, media_type: str = "application/json") -> dict:
    return {
        "uri": path.resolve().as_uri(),
        "sha256": sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "media_type": media_type,
    }


@contextmanager
def cli_snapshot(raw_by_name: dict[str, bytes], parent: Path):
    with TemporaryDirectory(prefix=".nav2-cli-", dir=parent) as temporary:
        snapshot = Path(temporary)
        for name in ("scenario.json", "runtime.json", "nav2.schema.json"):
            path = snapshot / name
            write_bytes_atomically(raw_by_name[name], path)
            path.chmod(0o400)
        yield snapshot


def run_cli(snapshot: Path, *arguments: str) -> str:
    executable = Path(sys.executable).with_name("robotics-acceptance")
    environment = dict(os.environ)
    for key in ("PYTHONPATH", "PYTHONHOME"):
        environment.pop(key, None)
    with TemporaryFile(dir=snapshot) as stdout, TemporaryFile(dir=snapshot) as stderr:
        try:
            result = subprocess.run(
                [str(executable), *arguments],
                env=environment,
                stdin=subprocess.DEVNULL,
                stdout=stdout,
                stderr=stderr,
                timeout=30,
                check=False,
            )
        except (OSError, subprocess.TimeoutExpired) as error:
            raise ValueError("installed acceptance CLI invocation failed") from error
        stderr.seek(0)
        diagnostic = stderr.read(CLI_OUTPUT_LIMIT + 1)
        if result.returncode != 0:
            reason = (
                diagnostic[:CLI_OUTPUT_LIMIT].decode("utf-8", errors="replace").strip()
            )
            if len(diagnostic) > CLI_OUTPUT_LIMIT:
                reason += "\n[diagnostic truncated]"
            raise ValueError(
                f"acceptance CLI {arguments[0]} failed (exit {result.returncode}): "
                + (reason or "no diagnostic emitted")
            )
        if arguments[0] != "create-run":
            return ""
        stdout.seek(0)
        output = stdout.read(CLI_OUTPUT_LIMIT + 1)
        if len(output) > CLI_OUTPUT_LIMIT:
            raise ValueError("acceptance CLI create-run output exceeded its byte limit")
        return output.decode("utf-8").strip()


def check_run_binding(run: dict, run_id: str, scenario: dict, scenario_raw: bytes):
    validate_role(run, "acceptance_run")
    if (
        run["run_id"] != run_id
        or run["scenario_id"] != scenario["scenario_id"]
        or run["scenario_sha256"] != sha256(scenario_raw).hexdigest()
        or "nav2" not in {item["domain_id"] for item in run["domains"]}
    ):
        raise ValueError("run context differs from the prepared Nav2 inputs")


def require_active_nav2_lifecycle(configuration):
    graph = configuration["readiness"]["graph"]
    try:
        Draft202012Validator(
            load_schema("acceptance-scenario.v1")["properties"]["expected_ros_graph"],
            registry=schema_registry(),
        ).validate(graph)
    except ValidationError as error:
        raise ValueError("invalid native startup graph: " + error.json_path) from error
    for name in ("/amcl", "/bt_navigator"):
        selected = [row for row in graph["lifecycle_nodes"] if row["name"] == name]
        if len(selected) != 1 or selected[0]["required_state"] != "active":
            raise ValueError(
                "native Nav2 startup requires declared active node " + name
            )


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
    if native is not None:
        require_active_nav2_lifecycle(requirements["configuration"])
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    configuration = output / "nav2-configuration.json"
    schema_path = Path(__file__).with_name("nav2.schema.json")
    raw_by_name = {
        "nav2-configuration.json": dumps_canonical(requirements["configuration"])
    }
    write_bytes_atomically(raw_by_name["nav2-configuration.json"], configuration)
    selected_profile = dict(profile)
    selected_profile["executor"] = {
        **profile["executor"],
        "configuration": reference(
            configuration, raw_by_name["nav2-configuration.json"]
        ),
    }
    profile_snapshot = output / "native-profile.json"
    raw_by_name["native-profile.json"] = profile_raw
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
    raw_by_name["nav2.schema.json"] = schema_raw
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
            name = "native-" + kind + ".sdf"
            raw_by_name[name] = base64.b64decode(
                facts["rendered"][kind]["base64"], validate=True
            )
            write_bytes_atomically(raw_by_name[name], output / name)
        raw_by_name["native-preflight.json"] = native_raw
        write_bytes_atomically(native_raw, output / "native-preflight.json")
    scenario_path, runtime_path = output / "scenario.json", output / "runtime.json"
    write_document(scenario, scenario_path, extension_schemas={schema_uri: schema_raw})
    raw_by_name["scenario.json"] = read_once(scenario_path, DOCUMENT_LIMIT)
    runtime = {
        "schema_version": "runtime-manifest.v2",
        "runtime_id": "nav2-turtlebot3-native",
        "generated_at": datetime.now(UTC).isoformat(),
        "scenario_sha256": sha256(raw_by_name["scenario.json"]).hexdigest(),
        "execution": scenario["execution"],
        "profile": selected_profile,
        "evaluator_bindings": scenario["evaluator_requirements"],
    }
    if native is not None:
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
    raw_by_name["runtime.json"] = read_once(runtime_path, DOCUMENT_LIMIT)
    context_path = output / "run.json"
    reserved = run_id if run_id is not None else "run-" + str(uuid4())
    with cli_snapshot(raw_by_name, output.parent) as snapshot:
        schema_option = "urn:nav2-turtlebot3:scenario:v1=" + str(
            snapshot / "nav2.schema.json"
        )
        run_cli(
            snapshot,
            "explain",
            "--scenario",
            str(snapshot / "scenario.json"),
            "--runtime",
            str(snapshot / "runtime.json"),
            "--extension-schema",
            schema_option,
        )
        issued = run_cli(
            snapshot,
            "create-run",
            "--scenario",
            str(snapshot / "scenario.json"),
            "--output",
            str(context_path.resolve()),
            "--domain",
            "nav2=simulation",
            "--time-authority",
            selected_profile["clock"]["kind"],
            "--time-source",
            selected_profile["clock"]["source_id"],
            "--run-id",
            reserved,
            "--extension-schema",
            schema_option,
        )
    if issued != reserved:
        raise ValueError("acceptance CLI returned a different run identity")
    raw_by_name["run.json"] = read_once(context_path, DOCUMENT_LIMIT)
    check_run_binding(
        loads_mapping(raw_by_name["run.json"]),
        reserved,
        scenario,
        raw_by_name["scenario.json"],
    )
    manifest = {
        "run_id": issued,
        "domain_id": "nav2",
        "scenario": reference(scenario_path, raw_by_name["scenario.json"]),
        "runtime": reference(runtime_path, raw_by_name["runtime.json"]),
        "run_context": reference(context_path, raw_by_name["run.json"]),
        "configuration": reference(
            configuration, raw_by_name["nav2-configuration.json"]
        ),
        "native_profile": reference(
            profile_snapshot, raw_by_name["native-profile.json"]
        ),
        "extension_schema": reference(schema_snapshot, raw_by_name["nav2.schema.json"]),
    }
    if native is not None:
        manifest["native_preflight"] = reference(
            output / "native-preflight.json", raw_by_name["native-preflight.json"]
        )
        manifest["native_model"] = reference(
            output / "native-model.sdf",
            raw_by_name["native-model.sdf"],
            "application/xml",
        )
        manifest["expanded_world"] = reference(
            output / "native-world.sdf",
            raw_by_name["native-world.sdf"],
            "application/xml",
        )
    write_bytes_atomically(
        dumps_canonical(manifest), output / "pre-execution-inputs.json"
    )
    return manifest


NATIVE_LAUNCH = [
    "ros2",
    "launch",
    "/opt/sdk-policy/native_simulation.launch.py",
    "robot_sdf:=/consumer/inputs/native-model.sdf",
    "world:=/consumer/inputs/native-world.sdf",
    "map:=/opt/ros/jazzy/share/nav2_bringup/maps/tb3_sandbox.yaml",
]
NATIVE_FILES = {
    "model": "/opt/ros/jazzy/share/nav2_minimal_tb3_sim/urdf/gz_waffle.sdf.xacro",
    "world": "/opt/ros/jazzy/share/nav2_minimal_tb3_sim/worlds/tb3_sandbox.sdf.xacro",
    "map": "/opt/ros/jazzy/share/nav2_bringup/maps/tb3_sandbox.yaml",
    "launch": "/opt/ros/jazzy/share/nav2_bringup/launch/tb3_simulation_launch.py",
    "consumer_launch": "/opt/sdk-policy/native_simulation.launch.py",
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
    inventory = subprocess.check_output(
        [
            "dpkg-query",
            "-W",
            "-f=${Package}\t${Version}\t${Architecture}\t${db:Status-Status}\n",
        ]
    )
    ros_packages = [
        row.split("\t")[0]
        for row in inventory.decode().splitlines()
        if row.startswith("ros-jazzy-") and row.endswith("\tinstalled")
    ]
    if not ros_packages or ros_packages != receipt["ros_packages"]:
        raise ValueError("native ROS package inventory differs from build receipt")
    verified = subprocess.run(
        ["dpkg", "--verify", *ros_packages],
        check=True,
        capture_output=True,
        text=True,
        timeout=20,
    )
    if verified.stdout or verified.stderr:
        raise ValueError("installed native package files differ from the build receipt")
    for name, expected in receipt["snapshot_files"].items():
        if sha256(read_once(Path(name), DOCUMENT_LIMIT)).hexdigest() != expected:
            raise ValueError("native snapshot configuration differs: " + name)
    if sha256(inventory).hexdigest() != receipt["dpkg_inventory_sha256"]:
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
        files[name] = dict(expected)
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
    raw_id = image.get("Id")
    if not isinstance(raw_id, str) or not re.fullmatch(
        r"(?:sha256:)?[a-f0-9]{64}", raw_id
    ):
        raise ValueError("selected image Config ID is malformed")
    observed_id = "sha256:" + raw_id.removeprefix("sha256:")
    if observed_id != image_id or (
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
        "robotics-runtime-contracts": "0.22.0",
        "robotics-acceptance-harness": "0.23.1",
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
    launch = facts["files"].get("consumer_launch", {})
    launch_raw = read_once(root / "native_simulation.launch.py", DOCUMENT_LIMIT)
    if (launch.get("sha256"), launch.get("size_bytes")) != (
        sha256(launch_raw).hexdigest(),
        len(launch_raw),
    ):
        raise ValueError("native consumer launch differs from the captured source")
    if set(NATIVE_FILES) - set(facts["files"]):
        raise ValueError("native model/world/map/launch evidence is missing")
    for name, expected in facts["files"].items():
        if name in NATIVE_FILES and expected["path"] != NATIVE_FILES[name]:
            raise ValueError("native input path differs: " + name)
        identity = {key: expected[key] for key in ("path", "sha256", "size_bytes")}
        if identity != build["files"][name]:
            raise ValueError("native input identity differs: " + name)
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
        "native_model": "native-model.sdf",
        "expanded_world": "native-world.sdf",
    }
    raw_by_name = {}
    for key, name in names.items():
        raw = read_once(prepared / name, 8 * DOCUMENT_LIMIT)
        raw_by_name[name] = raw
        identity = manifest.get(key, {})
        if identity.get("sha256") != sha256(raw).hexdigest() or identity.get(
            "size_bytes"
        ) != len(raw):
            raise ValueError("prepared input differs: " + key)
    schema = raw_by_name["nav2.schema.json"]
    scenario = loads_mapping(raw_by_name["scenario.json"])
    runtime = loads_mapping(raw_by_name["runtime.json"])
    validate_role(
        scenario,
        "acceptance_scenario",
        extension_schemas={"urn:nav2-turtlebot3:scenario:v1": schema},
    )
    validate_role(runtime, "runtime_manifest")
    with cli_snapshot(raw_by_name, prepared.parent) as snapshot:
        run_cli(
            snapshot,
            "explain",
            "--scenario",
            str(snapshot / "scenario.json"),
            "--runtime",
            str(snapshot / "runtime.json"),
            "--extension-schema",
            "urn:nav2-turtlebot3:scenario:v1=" + str(snapshot / "nav2.schema.json"),
        )
    check_run_binding(
        loads_mapping(raw_by_name["run.json"]),
        manifest["run_id"],
        scenario,
        raw_by_name["scenario.json"],
    )
    preflight = loads_mapping(raw_by_name["native-preflight.json"])
    image_reference = preflight["image_reference"]
    facts = check_preflight(preflight, image_reference, image_id)
    for kind, key in (("model", "native_model"), ("world", "expanded_world")):
        expected = facts["rendered"][kind]
        if any(
            manifest[key][field] != expected[field]
            for field in ("sha256", "size_bytes")
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
    from copy import deepcopy

    expected_profile = native_profile(facts)
    declared_profile = deepcopy(dict(scenario["profile"]))
    configuration_ref = declared_profile["executor"].pop("configuration")
    if declared_profile != expected_profile:
        raise ValueError("declared native profile differs from observed image")
    stored_profile = loads_mapping(raw_by_name["native-profile.json"])
    if stored_profile != expected_profile:
        raise ValueError("captured native profile differs")
    for key in ("sha256", "size_bytes"):
        if configuration_ref[key] != manifest["configuration"][key]:
            raise ValueError(
                "executor configuration reference differs from captured bytes"
            )
    configuration = scenario["extensions"][NAMESPACE]
    require_active_nav2_lifecycle(configuration)
    if loads_mapping(raw_by_name["nav2-configuration.json"]) != configuration:
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
        "scenario": scenario,
        "scenario_sha256": sha256(raw_by_name["scenario.json"]).hexdigest(),
        "image_id": image_id,
        "image_reference": image_reference,
        "launch": facts["launch"],
    }


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
    args = parser.parse_args()
    if args.inspect_image:
        result = inspect_image()
    elif args.validate_prepared:
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
