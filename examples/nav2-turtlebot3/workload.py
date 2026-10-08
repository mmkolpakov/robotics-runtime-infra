"""Observe real NavigateToPose outcomes using the released Nav2 client APIs."""

from __future__ import annotations

import argparse
import hashlib
import importlib.metadata
import json
import math
import operator
import os
import platform
import re
import subprocess
import time
from pathlib import Path

import rclpy
from action_msgs.msg import GoalStatus
from geometry_msgs.msg import PoseStamped, PoseWithCovarianceStamped
from nav2_msgs.action import NavigateToPose
from nav2_simple_commander.robot_navigator import BasicNavigator
from nav_msgs.msg import Odometry
from rclpy.action import ActionClient
from rclpy.parameter import Parameter
from rclpy.qos import (
    DurabilityPolicy,
    QoSProfile,
    ReliabilityPolicy,
    qos_profile_sensor_data,
)
from rclpy.serialization import serialize_message
from robotics_acceptance_harness.readiness import wait_for_readiness
from robotics_acceptance_harness.ros import RosGraphObserver
from robotics_runtime_contracts import load_mapping
from rosgraph_msgs.msg import Clock
from rosidl_runtime_py.convert import message_to_ordereddict
from std_srvs.srv import Empty
from tf2_msgs.msg import TFMessage


def native_octets(values, size: int) -> list[int]:
    """Project native uint8 fields to JSON integers without accepting lossy types."""
    result = [operator.index(value) for value in values]
    if len(result) != size or any(value < 0 or value > 255 for value in result):
        raise ValueError("native octet field has an invalid size or value")
    return result


def atomic_json(path: Path, document: dict) -> None:
    temporary = path.with_suffix(".tmp")
    with temporary.open("x", encoding="utf-8") as stream:
        json.dump(document, stream, sort_keys=True, allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def finite_future(node, future, deadline: float):
    while not future.done():
        remaining = deadline - time.monotonic()
        if remaining <= 0:
            raise TimeoutError("action future did not settle before its deadline")
        rclpy.spin_once(node, timeout_sec=min(0.1, remaining))
    if time.monotonic() >= deadline:
        raise TimeoutError("action future settled after its deadline")
    return future.result()


def pose(node, x: float, y: float) -> PoseStamped:
    result = PoseStamped()
    result.header.frame_id = "map"
    result.header.stamp = node.get_clock().now().to_msg()
    result.pose.position.x = x
    result.pose.position.y = y
    result.pose.orientation.w = 1.0
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--case",
        choices=["success", "cancel", "timeout", "server-failure"],
        required=True,
    )
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--domain-id", required=True)
    parser.add_argument("--output", required=True, type=Path)
    parser.add_argument("--scenario", type=Path, required=True)
    parser.add_argument("--goal-x", type=float, default=1.0)
    parser.add_argument("--goal-y", type=float, default=-0.5)
    parser.add_argument("--action-budget-sec", type=float, default=120.0)
    parser.add_argument("--application-timeout-sec", type=float, default=2.0)
    parser.add_argument("--max-pose-error-m", type=float, default=0.35)
    parser.add_argument("--min-displacement-m", type=float, default=0.5)
    parser.add_argument("--max-observation-age-sec", type=float, default=2.0)
    phase = parser.add_mutually_exclusive_group()
    phase.add_argument("--prepare-only", action="store_true")
    phase.add_argument("--already-initialized", action="store_true")
    parser.add_argument("--odometry-frame", default="odom")
    parser.add_argument("--required-tf-edge", nargs=2, action="append")
    args = parser.parse_args()
    args.required_tf_edges = args.required_tf_edge or [
        ["map", "odom"],
        ["odom", "base_footprint"],
        ["base_footprint", "base_link"],
    ]
    if (
        len(args.required_tf_edges) > 16
        or len({tuple(pair) for pair in args.required_tf_edges})
        != len(args.required_tf_edges)
        or any(
            not re.fullmatch(r"[A-Za-z][A-Za-z0-9_/]{0,127}", value)
            for pair in args.required_tf_edges
            for value in pair
        )
        or not re.fullmatch(r"[A-Za-z][A-Za-z0-9_/]{0,127}", args.odometry_frame)
    ):
        parser.error("unique bounded ROS frame pairs are required")
    if (
        not all(
            math.isfinite(v)
            for v in [
                args.goal_x,
                args.goal_y,
                args.action_budget_sec,
                args.application_timeout_sec,
                args.max_pose_error_m,
                args.min_displacement_m,
                args.max_observation_age_sec,
            ]
        )
        or not 0 < args.application_timeout_sec < args.action_budget_sec <= 180
        or not 0 < args.max_pose_error_m <= 1
        or not 0 < args.min_displacement_m <= 5
        or not 0 < args.max_observation_age_sec <= 5
    ):
        parser.error("finite pose and an action budget in (0,180] are required")
    declared_scenario = load_mapping(args.scenario)
    configuration = declared_scenario["extensions"]["org.example.nav2-turtlebot3"]
    actual_parameters = {
        "goal": {"x": args.goal_x, "y": args.goal_y},
        "action_budget_sec": args.action_budget_sec,
        "application_timeout_sec": args.application_timeout_sec,
        "max_final_pose_error_m": args.max_pose_error_m,
        "min_displacement_m": args.min_displacement_m,
        "max_observation_age_sec": args.max_observation_age_sec,
        "odometry_frame": args.odometry_frame,
        "required_tf_edges": args.required_tf_edges,
    }
    if configuration != {**actual_parameters, "case": args.case}:
        parser.error("consumer parameters differ from the declared scenario")
    expected_graph = declared_scenario["expected_ros_graph"]
    graph_budget = declared_scenario["timeouts"]["graph_ready_sec"]
    graph_stability = declared_scenario["timeouts"]["stable_for_sec"]
    if not 0 < graph_budget <= 10 or not 0 <= graph_stability < graph_budget:
        parser.error("declared graph readiness must fit the existing ten-second budget")
    package_format = (
        "-f="
        + chr(36)
        + "{Package}\\t"
        + chr(36)
        + "{Version}\\t"
        + chr(36)
        + "{Architecture}\\n"
    )
    packages = subprocess.run(
        [
            "dpkg-query",
            "-W",
            package_format,
            "ros-jazzy-rclpy",
            "ros-jazzy-rmw-fastrtps-cpp",
            "ros-jazzy-nav2-bringup",
            "ros-jazzy-nav2-simple-commander",
            "ros-jazzy-rosbag2-transport",
            "ros-jazzy-gz-sim-vendor",
        ],
        capture_output=True,
        text=True,
        timeout=5,
        check=True,
    ).stdout
    bootstrap_facts = {
        "os": platform.freedesktop_os_release(),
        "kernel": platform.release(),
        "architecture": platform.machine(),
        "python": platform.python_version(),
        "namespace": {
            kind: os.readlink("/proc/self/ns/" + kind) for kind in ("net", "ipc")
        },
        "interfaces": sorted(os.listdir("/sys/class/net")),
        "environment": {
            key: os.environ.get(key)
            for key in (
                "ROS_DOMAIN_ID",
                "RMW_IMPLEMENTATION",
                "FASTRTPS_DEFAULT_PROFILES_FILE",
                "RMW_FASTRTPS_USE_QOS_FROM_XML",
                "LIBGL_ALWAYS_SOFTWARE",
            )
        },
        "package_versions": packages,
        "public_packages": {
            name: importlib.metadata.version(name)
            for name in ("robotics-runtime-contracts", "robotics-acceptance-harness")
        },
        "middleware_profile_sha256": hashlib.sha256(
            Path(os.environ["FASTRTPS_DEFAULT_PROFILES_FILE"]).read_bytes()
        ).hexdigest(),
        "scenario_sha256": hashlib.sha256(args.scenario.read_bytes()).hexdigest(),
    }
    args.output.mkdir(mode=0o700, parents=True, exist_ok=True)
    atomic_json(
        args.output / "worker-process.json",
        {
            "run_id": args.run_id,
            "bootstrap_before_ros_init": bootstrap_facts,
            "domain_id": args.domain_id,
            "pid": os.getpid(),
            "source_sha256": hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
            "argv": list(os.sys.argv),
        },
    )
    raw_path = args.output / "observations.jsonl"
    report = {
        "run_id": args.run_id,
        "domain_id": args.domain_id,
        "case": args.case,
        "mode": "prepare" if args.prepare_only else "exercise",
        "observation_status": "error",
        "expected_case_observed": False,
        "parameters": {
            "goal": {"x": args.goal_x, "y": args.goal_y},
            "action_budget_sec": args.action_budget_sec,
            "application_timeout_sec": args.application_timeout_sec,
            "max_final_pose_error_m": args.max_pose_error_m,
            "min_displacement_m": args.min_displacement_m,
            "max_observation_age_sec": args.max_observation_age_sec,
            "odometry_frame": args.odometry_frame,
            "required_tf_edges": args.required_tf_edges,
        },
    }
    rclpy.init(args=["--ros-args", "-p", "use_sim_time:=true"])
    navigator = BasicNavigator()
    configured = navigator.set_parameters([Parameter("use_sim_time", value=True)])
    if len(configured) != 1 or not configured[0].successful:
        navigator.destroy_node()
        rclpy.shutdown()
        raise RuntimeError("consumer native ROS clock parameter was refused")
    counts = {
        "odom": 0,
        "tf": 0,
        "clock": 0,
        "feedback": 0,
        "amcl_pose": 0,
        "tf_static": 0,
    }
    raw_bytes = 0
    latest_pose = {}
    latest_odometry = {}
    latest_observations = {}
    tf_edges = {}
    subscriptions_by_kind = {}
    last_graph_ns = 0
    with raw_path.open("x", encoding="utf-8", buffering=64 * 1024) as raw:

        def record(kind: str, payload: dict) -> None:
            nonlocal raw_bytes
            row = {
                "run_id": args.run_id,
                "kind": kind,
                "observed_unix_ns": time.time_ns(),
                "observed_monotonic_ns": time.monotonic_ns(),
                **payload,
            }
            encoded = json.dumps(row, sort_keys=True, allow_nan=False) + "\n"
            raw_bytes += len(encoded.encode())
            if raw_bytes > 32 * 1024 * 1024:
                raise ValueError("raw observation byte limit exceeded")
            raw.write(encoded)

        def message_callback(kind: str):
            def received(message, info):
                nonlocal last_graph_ns
                counts[kind] += 1
                latest_observations[kind] = time.monotonic_ns()
                if kind == "amcl_pose":
                    latest_pose.update(
                        frame_id=message.header.frame_id,
                        x=message.pose.pose.position.x,
                        y=message.pose.pose.position.y,
                        ros_stamp_ns=message.header.stamp.sec * 10**9
                        + message.header.stamp.nanosec,
                        observed_monotonic_ns=latest_observations[kind],
                        observed_unix_ns=time.time_ns(),
                    )
                if kind == "odom":
                    latest_odometry.update(
                        frame_id=message.header.frame_id,
                        child_frame_id=message.child_frame_id,
                        x=message.pose.pose.position.x,
                        y=message.pose.pose.position.y,
                        ros_stamp_ns=message.header.stamp.sec * 10**9
                        + message.header.stamp.nanosec,
                        observed_monotonic_ns=latest_observations[kind],
                        observed_unix_ns=time.time_ns(),
                    )
                if kind in {"tf", "tf_static"}:
                    for transform in message.transforms:
                        tf_edges[
                            (transform.header.frame_id, transform.child_frame_id)
                        ] = {
                            "parent": transform.header.frame_id,
                            "child": transform.child_frame_id,
                            "ros_stamp_ns": transform.header.stamp.sec * 10**9
                            + transform.header.stamp.nanosec,
                            "observed_monotonic_ns": latest_observations[kind],
                            "source_topic": "/" + kind,
                        }
                # Keep native RMW fields verbatim; absent/unsupported values are not zero measurements.
                fields = {
                    key: info.get(key)
                    for key in [
                        "source_timestamp",
                        "received_timestamp",
                        "publication_sequence_number",
                        "reception_sequence_number",
                    ]
                }
                gid = info.get("publisher_gid")
                fields["publisher_gid"] = (
                    native_octets(gid, 16) if gid is not None else None
                )
                fields["available_binding_keys"] = sorted(info)
                if kind == "odom":
                    # Native graph cardinality is separate from unavailable per-message GID.
                    fields["publisher_count"] = subscriptions_by_kind[
                        "odom"
                    ].get_publisher_count()
                    if latest_observations[kind] - last_graph_ns >= 1_000_000_000:
                        last_graph_ns = latest_observations[kind]
                        for topic in ["/odom", "/clock"]:
                            publishers = []
                            for endpoint in navigator.get_publishers_info_by_topic(
                                topic
                            ):
                                type_hash = endpoint.topic_type_hash
                                publishers.append(
                                    {
                                        "node_name": endpoint.node_name,
                                        "node_namespace": endpoint.node_namespace,
                                        "topic_type": endpoint.topic_type,
                                        "endpoint_gid": native_octets(
                                            endpoint.endpoint_gid, 16
                                        ),
                                        "topic_type_hash": {
                                            "version": type_hash.version,
                                            "value": native_octets(type_hash.value, 32),
                                        },
                                        "reliability": str(
                                            endpoint.qos_profile.reliability
                                        ),
                                        "durability": str(
                                            endpoint.qos_profile.durability
                                        ),
                                    }
                                )
                            record(
                                "graph-publishers",
                                {
                                    "channel": topic,
                                    "publishers": publishers,
                                    "publisher_count": len(publishers),
                                },
                            )
                # Full ROS payloads are retained by the native MCAP recorder.
                # This buffered journal keeps only the consumer state and RMW
                # metadata needed for offline policy evaluation.
                if kind == "clock":
                    observed_message = {
                        "clock": {
                            "sec": int(message.clock.sec),
                            "nanosec": int(message.clock.nanosec),
                        }
                    }
                elif kind == "odom":
                    observed_message = dict(latest_odometry)
                elif kind == "amcl_pose":
                    observed_message = dict(latest_pose)
                else:
                    observed_message = {
                        "transforms": [
                            {
                                "parent": transform.header.frame_id,
                                "child": transform.child_frame_id,
                                "ros_stamp_ns": transform.header.stamp.sec * 10**9
                                + transform.header.stamp.nanosec,
                            }
                            for transform in message.transforms
                        ]
                    }
                record(kind, {"message": observed_message, "message_info": fields})

            return received

        subscriptions = [
            navigator.create_subscription(
                TFMessage,
                "/tf_static",
                message_callback("tf_static"),
                QoSProfile(
                    depth=1,
                    reliability=ReliabilityPolicy.RELIABLE,
                    durability=DurabilityPolicy.TRANSIENT_LOCAL,
                ),
            ),
            navigator.create_subscription(
                PoseWithCovarianceStamped,
                "/amcl_pose",
                message_callback("amcl_pose"),
                qos_profile_sensor_data,
            ),
            navigator.create_subscription(
                Odometry,
                "/odom",
                message_callback("odom"),
                QoSProfile(depth=100, reliability=ReliabilityPolicy.RELIABLE),
            ),
            navigator.create_subscription(
                TFMessage, "/tf", message_callback("tf"), qos_profile_sensor_data
            ),
            navigator.create_subscription(
                Clock,
                "/clock",
                message_callback("clock"),
                QoSProfile(depth=100, reliability=ReliabilityPolicy.RELIABLE),
            ),
        ]
        subscriptions_by_kind.update(
            zip(
                ["tf_static", "amcl_pose", "odom", "tf", "clock"],
                subscriptions,
                strict=True,
            )
        )
        client = ActionClient(navigator, NavigateToPose, "navigate_to_pose")
        nomotion_client = None
        observer = None
        try:
            record(
                "consumer-clock-configuration",
                {
                    "api": "Node.set_parameters/get_parameter",
                    "use_sim_time": navigator.get_parameter("use_sim_time").value,
                    "basis": "selected ROS Clock payload; nominal shared-clock relation is configuration, not offset measurement",
                },
            )
            record("readiness-start", {"api": "BasicNavigator.waitUntilNav2Active"})
            if not args.already_initialized:
                navigator.setInitialPose(pose(navigator, -2.0, -0.5))
            # The public host Jobs deadline bounds this documented blocking startup method.
            navigator.waitUntilNav2Active()
            ready_deadline = time.monotonic() + graph_budget
            observer = RosGraphObserver(
                expected_graph,
                observe_clock=True,
                node_name="nav2_public_graph_observer",
            )
            graph_ready = wait_for_readiness(
                expected_graph,
                observer,
                timeout_sec=max(0.001, ready_deadline - time.monotonic()),
                stable_for_sec=graph_stability,
            )
            if time.monotonic() >= ready_deadline:
                raise TimeoutError(
                    "published graph observation exceeded readiness deadline"
                )
            for topic in ("/odom", "/clock"):
                offers = navigator.get_publishers_info_by_topic(topic)
                if (
                    len(offers) != 1
                    or offers[0].qos_profile.reliability != ReliabilityPolicy.RELIABLE
                ):
                    raise RuntimeError(
                        "the selected native publisher offer is not the admitted RELIABLE cohort"
                    )
                record(
                    "admitted-publisher-qos",
                    {
                        "channel": topic,
                        "publisher_count": len(offers),
                        "offered_reliability": str(offers[0].qos_profile.reliability),
                        "consumer_reliability": "RELIABLE",
                        "consumer_depth": 100,
                    },
                )
            record(
                "published-graph-ready",
                {
                    "api": "RosGraphObserver/wait_for_readiness",
                    "first_ready_at_ns": graph_ready.first_ready_at_ns,
                    "stable_for_sec": graph_ready.stable_for_sec,
                },
            )
            while not client.wait_for_server(timeout_sec=0.1):
                if time.monotonic() >= ready_deadline:
                    raise TimeoutError("NavigateToPose action server is unavailable")
            if args.already_initialized:
                nomotion_client = navigator.create_client(
                    Empty, "/request_nomotion_update"
                )
                nomotion_deadline = time.monotonic() + 2
                while not nomotion_client.wait_for_service(timeout_sec=0.1):
                    if time.monotonic() >= nomotion_deadline:
                        raise TimeoutError(
                            "the upstream AMCL nomotion service is unavailable"
                        )
                finite_future(
                    navigator,
                    nomotion_client.call_async(Empty.Request()),
                    nomotion_deadline,
                )
                record(
                    "initial-nomotion-response",
                    {
                        "service": "/request_nomotion_update",
                        "type": "std_srvs/srv/Empty",
                    },
                )
            observation_deadline = time.monotonic() + 10
            while any(
                counts[key] < minimum
                for key, minimum in {
                    "odom": 2,
                    "tf": 2,
                    "clock": 30,
                    "amcl_pose": 1,
                }.items()
            ):
                if time.monotonic() >= observation_deadline:
                    raise TimeoutError(
                        "required native odom/TF/Clock observations are missing"
                    )
                rclpy.spin_once(navigator, timeout_sec=0.1)
            if time.monotonic() >= ready_deadline:
                raise TimeoutError(
                    "native observation readiness exceeded its declared deadline"
                )
            record(
                "ready",
                {"api": "NavigateToPose", "node_names": navigator.get_node_names()},
            )
            if args.prepare_only:
                report["observation_status"] = "ready"
                report["action_server_available"] = True
                report["message_counts"] = counts
                report["initial_amcl_pose"] = dict(latest_pose)
                report["initial_odometry"] = dict(latest_odometry)
                return 0
            goal = NavigateToPose.Goal()
            goal.pose = pose(navigator, args.goal_x, args.goal_y)

            def feedback(message):
                counts["feedback"] += 1
                record(
                    "feedback",
                    {
                        "goal_id": native_octets(message.goal_id.uuid, 16),
                        "feedback": {
                            "distance_remaining": float(
                                message.feedback.distance_remaining
                            ),
                            "number_of_recoveries": int(
                                message.feedback.number_of_recoveries
                            ),
                        },
                    },
                )

            report["initial_amcl_pose"] = dict(latest_pose)
            report["initial_odometry"] = dict(latest_odometry)
            goal_started_ns = time.monotonic_ns()
            report["goal_requested"] = {"x": args.goal_x, "y": args.goal_y}
            report["goal_started_monotonic_ns"] = goal_started_ns
            deadline = time.monotonic() + args.action_budget_sec
            handle = finite_future(
                navigator,
                client.send_goal_async(goal, feedback_callback=feedback),
                min(deadline, time.monotonic() + 10),
            )
            goal_accepted_ns = time.monotonic_ns()
            report["goal_accepted_monotonic_ns"] = goal_accepted_ns
            goal_id = native_octets(handle.goal_id.uuid, 16)
            report["goal_id"] = goal_id
            report["goal_accepted"] = bool(handle.accepted)
            record(
                "goal-response",
                {
                    "goal_id": goal_id,
                    "accepted": bool(handle.accepted),
                    "goal": message_to_ordereddict(goal),
                },
            )
            if not handle.accepted:
                raise RuntimeError("NavigateToPose goal was rejected")
            result_future = handle.get_result_async()
            trigger_budget = (
                1.0 if args.case == "cancel" else args.application_timeout_sec
            )
            case_started = time.monotonic()
            trigger_at = case_started + trigger_budget
            report["consumer_trigger_budget_sec"] = trigger_budget
            report["case_started_monotonic_ns"] = time.monotonic_ns()
            triggered = False
            while not result_future.done() and time.monotonic() < deadline:
                rclpy.spin_once(navigator, timeout_sec=0.1)
                if (
                    args.case != "success"
                    and not triggered
                    and time.monotonic() >= trigger_at
                ):
                    triggered = True
                    report["consumer_trigger_elapsed_sec"] = (
                        time.monotonic() - case_started
                    )
                    report["consumer_trigger_monotonic_ns"] = time.monotonic_ns()
                    if args.case in {"cancel", "timeout"}:
                        cancel = finite_future(
                            navigator,
                            handle.cancel_goal_async(),
                            min(deadline, time.monotonic() + 10),
                        )
                        record(
                            "cancel-response",
                            {
                                "return_code": int(cancel.return_code),
                                "goals_canceling": [
                                    native_octets(g.goal_id.uuid, 16)
                                    for g in cancel.goals_canceling
                                ],
                            },
                        )
                        report["cancel_requested"] = True
                        report["cancel_acknowledged"] = int(
                            cancel.return_code
                        ) == 0 and any(
                            native_octets(g.goal_id.uuid, 16) == goal_id
                            for g in cancel.goals_canceling
                        )
                        report["application_deadline_reached"] = args.case == "timeout"
                    else:
                        record(
                            "server-shutdown-request",
                            {"api": "BasicNavigator.lifecycleShutdown"},
                        )
                        # Genuine upstream lifecycle shutdown removes the action server; it is not a fabricated result.
                        navigator.lifecycleShutdown()
                        present = client.wait_for_server(timeout_sec=1.0)
                        record(
                            "server-after-shutdown",
                            {
                                "action_server_present": present,
                                "node_names": navigator.get_node_names(),
                            },
                        )
                        report["server_available_after_shutdown"] = present
                        if not present:
                            break
            if result_future.done():
                result_observed_ns = time.monotonic_ns()
                report["result_observed_monotonic_ns"] = result_observed_ns
                result = result_future.result()
                status = int(result.status)
                report["action_status"] = status
                report["action_result"] = message_to_ordereddict(result.result)
                # Exact generated response bytes, explicitly a consumer observation:
                # The checked rosbag2 0.26.11 writer API cannot attach this service schema.
                cdr = serialize_message(result)
                with (args.output / "get-result-response.cdr").open("xb") as stream:
                    stream.write(cdr)
                report["result_observation"] = {
                    "path": "get-result-response.cdr",
                    "sha256": hashlib.sha256(cdr).hexdigest(),
                    "size_bytes": len(cdr),
                    "goal_id": goal_id,
                    "encoding": "cdr",
                    "capture_method": "serialized-client-GetResult_Response-observation",
                    "native_python_type": type(result).__module__
                    + "."
                    + type(result).__name__,
                    "native_fields": result.get_fields_and_field_types(),
                    "schema_encoding": "unavailable-in-checked-rosbag2-0.26.11-topic-writer",
                    "checked_api_cohort": {"rclpy": "7.1.12", "rosbag2": "0.26.11"},
                    "type_hash": None,
                }
                record(
                    "action-result",
                    {
                        "goal_id": goal_id,
                        "status": status,
                        "result": report["action_result"],
                    },
                )
                if args.case == "success":
                    services = dict(
                        navigator.get_service_names_and_types_by_node("amcl", "/")
                    )
                    if services.get("/request_nomotion_update") != [
                        "std_srvs/srv/Empty"
                    ]:
                        raise RuntimeError(
                            "the upstream AMCL nomotion service is not advertised by amcl"
                        )
                    if nomotion_client is None:
                        nomotion_client = navigator.create_client(
                            Empty, "/request_nomotion_update"
                        )
                    service_deadline = min(deadline, time.monotonic() + 2.0)
                    while not nomotion_client.wait_for_service(timeout_sec=0.1):
                        if time.monotonic() >= service_deadline:
                            raise TimeoutError(
                                "the upstream AMCL nomotion service is unavailable"
                            )
                    prior_amcl_stamp_ns = latest_pose.get("ros_stamp_ns", 0)
                    request_ns = time.monotonic_ns()
                    record(
                        "amcl-nomotion-request",
                        {
                            "service": "/request_nomotion_update",
                            "type": "std_srvs/srv/Empty",
                            "server_node": "/amcl",
                            "goal_id": goal_id,
                        },
                    )
                    response = finite_future(
                        navigator,
                        nomotion_client.call_async(Empty.Request()),
                        service_deadline,
                    )
                    report["amcl_nomotion_update"] = {
                        "service": "/request_nomotion_update",
                        "type": "std_srvs/srv/Empty",
                        "server_node": "/amcl",
                        "prior_amcl_ros_stamp_ns": prior_amcl_stamp_ns,
                        "requested_monotonic_ns": request_ns,
                        "responded_monotonic_ns": time.monotonic_ns(),
                        "response": message_to_ordereddict(response),
                    }
                    record("amcl-nomotion-response", report["amcl_nomotion_update"])
                    # A post-result observation closes the arrival check; cached pre-goal
                    # localization or odometry cannot stand in for actual motion.
                    post_result_deadline = min(
                        deadline, time.monotonic() + args.max_observation_age_sec
                    )
                    while (
                        any(
                            latest_observations.get(key, 0) < result_observed_ns
                            for key in ["odom", "tf", "clock", "amcl_pose"]
                        )
                        or latest_pose.get("ros_stamp_ns", 0) <= prior_amcl_stamp_ns
                        or latest_pose.get("observed_monotonic_ns", 0) < request_ns
                        or any(
                            tuple(pair) not in tf_edges
                            or (
                                tf_edges[tuple(pair)]["source_topic"] != "/tf_static"
                                and (
                                    tf_edges[tuple(pair)]["ros_stamp_ns"] <= 0
                                    or tf_edges[tuple(pair)]["observed_monotonic_ns"]
                                    < result_observed_ns
                                )
                            )
                            for pair in args.required_tf_edges
                        )
                    ) and time.monotonic() < post_result_deadline:
                        rclpy.spin_once(navigator, timeout_sec=0.1)
                    goal_error = math.hypot(
                        latest_pose.get("x", math.inf) - args.goal_x,
                        latest_pose.get("y", math.inf) - args.goal_y,
                    )
                    initial = report["initial_amcl_pose"]
                    moved = math.hypot(
                        latest_pose.get("x", 0) - initial.get("x", 0),
                        latest_pose.get("y", 0) - initial.get("y", 0),
                    )
                    observed_at = time.monotonic_ns()
                    fresh = all(
                        latest_observations.get(key, 0) >= result_observed_ns
                        and 0
                        <= (observed_at - latest_observations.get(key, 0)) / 1e9
                        <= args.max_observation_age_sec
                        for key in ["odom", "tf", "clock", "amcl_pose"]
                    )
                    matched = (
                        status == GoalStatus.STATUS_SUCCEEDED
                        and observed_at / 1e9 < post_result_deadline
                        and fresh
                        and goal_error <= args.max_pose_error_m
                        and moved >= args.min_displacement_m
                        and latest_pose.get("frame_id") == "map"
                        and latest_pose.get("ros_stamp_ns", 0) > prior_amcl_stamp_ns
                        and latest_pose.get("observed_monotonic_ns", 0) >= request_ns
                        and latest_odometry.get("frame_id")
                        == report["initial_odometry"].get("frame_id")
                        == args.odometry_frame
                        and all(
                            tuple(pair) in tf_edges
                            and (
                                tf_edges[tuple(pair)]["source_topic"] == "/tf_static"
                                or (
                                    tf_edges[tuple(pair)]["ros_stamp_ns"] > 0
                                    and tf_edges[tuple(pair)]["observed_monotonic_ns"]
                                    >= result_observed_ns
                                    and 0
                                    <= (
                                        observed_at
                                        - tf_edges[tuple(pair)]["observed_monotonic_ns"]
                                    )
                                    / 1e9
                                    <= args.max_observation_age_sec
                                )
                            )
                            for pair in args.required_tf_edges
                        )
                        and latest_odometry.get("ros_stamp_ns", 0)
                        > report["initial_odometry"].get("ros_stamp_ns", 0)
                        > 0
                        and math.hypot(
                            latest_odometry.get("x", 0)
                            - report["initial_odometry"].get("x", 0),
                            latest_odometry.get("y", 0)
                            - report["initial_odometry"].get("y", 0),
                        )
                        >= args.min_displacement_m
                    )
                elif args.case == "cancel":
                    matched = (
                        triggered
                        and status == GoalStatus.STATUS_CANCELED
                        and report.get("cancel_acknowledged") is True
                    )
                elif args.case == "timeout":
                    matched = (
                        triggered
                        and status == GoalStatus.STATUS_CANCELED
                        and report.get("cancel_acknowledged") is True
                        and report.get("application_deadline_reached") is True
                        and report["consumer_trigger_elapsed_sec"]
                        >= args.application_timeout_sec
                    )
                else:
                    matched = (
                        triggered
                        and report.get("server_available_after_shutdown") is False
                    )
                report["expected_case_observed"] = matched
                if args.case == "success" and observed_at / 1e9 >= post_result_deadline:
                    report["expected_case_observed"] = False
                    report["observation_status"] = "incomplete"
                    report["reason"] = (
                        "arrival observations exceeded the declared freshness deadline"
                    )
                elif result_observed_ns / 1e9 >= deadline:
                    report["expected_case_observed"] = False
                    report["observation_status"] = "incomplete"
                    report["reason"] = (
                        "result observed after the declared action budget"
                    )
                else:
                    report["observation_status"] = "complete"
            elif (
                args.case == "server-failure"
                and report.get("server_available_after_shutdown") is False
                and time.monotonic() < deadline
            ):
                report["expected_case_observed"] = True
                report["observation_status"] = "server-unavailable"
            else:
                report["observation_status"] = "incomplete"
                report["reason"] = "result did not settle before action deadline"
            report["message_counts"] = counts
            report["final_amcl_pose"] = latest_pose
            report["final_odometry"] = latest_odometry
            report["tf_edges"] = list(tf_edges.values())
            report["last_observation_monotonic_ns"] = latest_observations
            report["goal_finished_monotonic_ns"] = time.monotonic_ns()
            # Observing the expected negative case does not certify underlying ROS/DDS acceptance.
            report["ros_acceptance_status"] = "not-evaluated"
        except (RuntimeError, TimeoutError, ValueError, TypeError, OSError) as error:
            report["error_type"] = type(error).__name__
            report["error"] = str(error)
            report["message_counts"] = counts
            record(
                "observation-error",
                {"error_type": type(error).__name__, "message": str(error)},
            )
        finally:
            if observer is not None:
                observer.close()
            client.destroy()
            if nomotion_client is not None:
                navigator.destroy_client(nomotion_client)
            for subscription in subscriptions:
                navigator.destroy_subscription(subscription)
            navigator.destroy_node()
            rclpy.shutdown()
            atomic_json(
                args.output
                / ("readiness.json" if args.prepare_only else "workload.json"),
                report,
            )
    return 0 if report["expected_case_observed"] else 1


if __name__ == "__main__":
    raise SystemExit(main())
