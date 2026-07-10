#!/usr/bin/env python3
"""Cross-repo integration graph readiness check.

Validates the running ROS graph against the `ros-graph-contract.v1` instance
at `ROBOTICS_EXPECTED_GRAPH_PATH` (default `infra/stack/cross-repo-expected-graph.json`,
schema `contracts/infra/ros-graph-contract.v1.schema.json`): waits for every
declared topic with `launch_testing_ros.WaitForTopics`, then asserts each
topic's declared minimum publisher count via `rclpy` graph introspection.
The graph under test is started by the sibling `cross-repo-simulation`
compose service (`launch/simulation_smoke.launch.py`), not by this test, so
`WaitForTopics` is used in its "attach to an already-running graph" mode.

Run with:
    source /etc/profile.d/robotics_ros_setup.sh
    python3 -m pytest infra/smoke/launch_testing/test_cross_repo_graph_ready.py \
        --junitxml=<report>.xml
"""

from __future__ import annotations

import json
import os
import time
from pathlib import Path
from typing import Any

import rclpy
from launch_testing_ros import WaitForTopics
from rosidl_runtime_py.utilities import get_message

REPO_ROOT = Path(__file__).resolve().parents[3]
DEFAULT_GRAPH_PATH = REPO_ROOT / "infra" / "stack" / "cross-repo-expected-graph.json"


def _load_expected_graph() -> dict[str, Any]:
    graph_path = Path(os.environ.get("ROBOTICS_EXPECTED_GRAPH_PATH", str(DEFAULT_GRAPH_PATH)))
    return json.loads(graph_path.read_text(encoding="utf-8"))


def test_expected_ros_graph_is_ready() -> None:
    graph = _load_expected_graph()
    default_timeout = float(
        os.environ.get("SMOKE_TIMEOUT_SECONDS", str(graph["graph_ready_timeout_sec"]))
    )
    topics = graph["topics"]

    topic_specs = [(topic["name"], get_message(topic["type"])) for topic in topics]
    with WaitForTopics(topic_specs, timeout=default_timeout):
        pass

    rclpy.init()
    try:
        node = rclpy.create_node("infra_cross_repo_graph_check")
        try:
            for topic in topics:
                min_count = topic["publisher_match"]["min_count"]
                if min_count <= 0:
                    continue
                timeout_sec = topic["publisher_match"]["timeout_sec"]
                observed = _wait_for_publisher_count(node, topic["name"], min_count, timeout_sec)
                assert observed >= min_count, (
                    f"{topic['name']}: expected >= {min_count} publisher(s), "
                    f"observed {observed}"
                )
        finally:
            node.destroy_node()
    finally:
        rclpy.shutdown()


def _wait_for_publisher_count(node: Any, topic_name: str, min_count: int, timeout_sec: float) -> int:
    """Poll graph introspection for up to `timeout_sec`.

    A freshly created node has not yet completed DDS discovery of publishers
    that existed before it was created, so a single instantaneous
    `get_publishers_info_by_topic` call can under-report; this gives
    discovery time to converge.
    """
    deadline = time.monotonic() + timeout_sec
    observed = len(node.get_publishers_info_by_topic(topic_name))
    while observed < min_count and time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.2)
        observed = len(node.get_publishers_info_by_topic(topic_name))
    return observed
