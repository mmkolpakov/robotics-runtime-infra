#!/usr/bin/env python3
"""Bounded native cause/reorder diagnostic, separate from full B3 acceptance."""

import argparse
import json
import os
from pathlib import Path
import signal
import subprocess
import time

import rclpy
from rclpy.qos import QoSProfile
from sensor_msgs.msg import JointState
from tf2_msgs.msg import TFMessage
from simulation_interfaces.msg import SimulationState, Result
from simulation_interfaces.srv import GetEntities
from robotics_runtime_infra.simulation_control import (
    SimulationControl,
    ConformanceError,
)

parser = argparse.ArgumentParser()
parser.add_argument("mode", choices=("overlap", "ordered"))
parser.add_argument("--output", type=Path, required=True)
args = parser.parse_args()
args.output.mkdir(parents=True, exist_ok=True)
processes = []
streams = []
report = {
    "scope": "source native startup diagnostic, not full B3 qualification",
    "mode": args.mode,
    "steps": [],
    "observations": [],
}
node = None


def start(command, name):
    stream = (args.output / name).open("wb")
    streams.append(stream)
    process = subprocess.Popen(
        command, stdout=stream, stderr=subprocess.STDOUT, start_new_session=True
    )
    processes.append(process)
    return process


def entity(node):
    client = node.create_client(GetEntities, "/simulator/get_entities")
    try:
        if not client.wait_for_service(timeout_sec=15):
            raise RuntimeError("native GetEntities unavailable")
        future = client.call_async(GetEntities.Request())
        rclpy.spin_until_future_complete(node, future, timeout_sec=15)
        result = future.result() if future.done() else None
        if result is None or result.result.result != Result.RESULT_OK:
            raise RuntimeError("native GetEntities did not return OK")
        return list(result.entities)
    finally:
        node.destroy_client(client)


def wait_asset():
    deadline = time.monotonic() + 35
    while time.monotonic() < deadline:
        models = entity(node)
        if "neutral_robot" in models:
            # Observe the upstream scene-info reinitialization before ownership.
            if (args.output / "server.log").read_text(errors="replace").count(
                "InitializeCanonicalLinks"
            ) >= 2:
                report["entity"] = {"result": "OK", "entities": models}
                return
        time.sleep(0.05)
    raise RuntimeError("native entity/canonical initialization not observed")


try:
    start(
        ["ros2", "launch", "robotics_runtime_infra", "headless.launch.py"], "server.log"
    )
    rclpy.init()
    node = SimulationControl("/simulator", 15)
    report["features"] = sorted(node.features())
    before_models = entity(node)
    if "neutral_robot" in before_models:
        raise RuntimeError("fresh world already contains the robot")
    report["entity_before"] = {"result": "OK", "entities": before_models}
    if args.mode == "ordered":
        start(
            [
                "ros2",
                "launch",
                "robotics_runtime_infra",
                "neutral_robot.launch.xml",
                "start_simulator:=false",
            ],
            "robot.log",
        )
        wait_asset()
    node.set_state(SimulationState.STATE_PAUSED)
    node.wait_for_state(SimulationState.STATE_PAUSED)
    cursor = node.wait_for_quiescent_clock()
    report["ownership_cursor_ns"] = cursor
    report["state_at_ownership"] = node.state()
    qualifying = {"joint_state": None, "tf": None}

    def joint(message):
        stamp = message.header.stamp.sec * 1_000_000_000 + message.header.stamp.nanosec
        if (
            list(message.name) == ["slider_joint"]
            and list(message.position) == [0.0]
            and stamp > report["ownership_cursor_ns"]
        ):
            qualifying["joint_state"] = {
                "stamp_ns": stamp,
                "name": list(message.name),
                "position": list(message.position),
            }

    def tf(message):
        for value in message.transforms:
            stamp = value.header.stamp.sec * 1_000_000_000 + value.header.stamp.nanosec
            t, q = value.transform.translation, value.transform.rotation
            if (
                value.header.frame_id == "base_link"
                and value.child_frame_id == "slider_link"
                and (t.x, t.y, t.z, q.x, q.y, q.z, q.w)
                == (0.2, 0.0, 0.0, 0.0, 0.0, 0.0, 1.0)
                and stamp > report["ownership_cursor_ns"]
            ):
                qualifying["tf"] = {
                    "stamp_ns": stamp,
                    "parent": value.header.frame_id,
                    "child": value.child_frame_id,
                    "translation": [t.x, t.y, t.z],
                    "rotation": [q.x, q.y, q.z, q.w],
                }

    node.create_subscription(JointState, "/joint_states", joint, QoSProfile(depth=100))
    node.create_subscription(TFMessage, "/tf", tf, QoSProfile(depth=100))
    if args.mode == "overlap":
        start(
            [
                "ros2",
                "launch",
                "robotics_runtime_infra",
                "neutral_robot.launch.xml",
                "start_simulator:=false",
            ],
            "robot.log",
        )
    deadline = time.monotonic() + 55
    caught = None
    while time.monotonic() < deadline and len(report["steps"]) < 300:
        before = cursor
        try:
            cursor = node.step_and_wait(cursor, 1, 1_000_000)
        except ConformanceError as error:
            caught = str(error)
            report["strict_failure"] = {
                "error": caught,
                "previous_ns": before,
                "expected_ns": before + 1_000_000,
                "observed_ns": node._clock_ns,
                "wall_monotonic_ns": time.monotonic_ns(),
            }
            break
        report["steps"].append(
            {
                "previous_ns": before,
                "expected_ns": before + 1_000_000,
                "observed_ns": cursor,
            }
        )
        if (
            args.mode == "ordered"
            and all(qualifying.values())
            and len(report["steps"]) >= 200
        ):
            break
        time.sleep(0.01)
    report["native_state_before_teardown"] = node.state()
    report["last_clock_ns_before_teardown"] = node._clock_ns
    report["qualifying"] = qualifying
    report["entity_after"] = {"result": "OK", "entities": entity(node)}
    report["canonical_initializations"] = (
        (args.output / "server.log")
        .read_text(errors="replace")
        .count("InitializeCanonicalLinks")
    )
    if args.mode == "overlap":
        if (
            caught is None
            or "neutral_robot" not in report["entity_after"]["entities"]
            or report["canonical_initializations"] < 2
        ):
            raise RuntimeError(
                "the overlapping initialization cause was not reproduced"
            )
        report["status"] = "expected_strict_failure_reproduced"
    else:
        if (
            caught is not None
            or len(report["steps"]) < 200
            or not all(qualifying.values())
        ):
            raise RuntimeError(
                "ordered exact-step and native JointState/TF diagnostic failed"
            )
        report["status"] = "ordered_diagnostic_passed"
finally:
    # Export the last native state and observations before stopping applications.
    (args.output / "measurement.json").write_text(json.dumps(report, indent=2) + "\n")
    if node is not None:
        node.destroy_node()
        rclpy.shutdown()
    cleanup = []
    for process in reversed(processes):
        if process.poll() is None:
            os.killpg(process.pid, signal.SIGTERM)
        try:
            process.wait(timeout=8)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
        cleanup.append(
            {
                "pid": process.pid,
                "returncode": process.returncode,
                "reaped": process.poll() is not None,
            }
        )
    for stream in streams:
        stream.close()
    (args.output / "cleanup.json").write_text(json.dumps(cleanup, indent=2) + "\n")
