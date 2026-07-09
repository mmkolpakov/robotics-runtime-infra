#!/usr/bin/env python3
"""Live ROS 2 graph readiness check, run as a sibling container on the same
Docker network as the simulation under test.

This exists so cross-repo integration evidence never claims `graph_ready` on
the strength of a launched process merely exiting zero. It reads an
`expected_ros_graph` (as produced by `robotics-harness scenario resolve`) and
uses `rclpy` to verify real publisher/subscriber counts, service
availability, and action interfaces, then writes a structured result and
exits non-zero on failure so the orchestrating `docker compose ... --exit-
code-from ros-observer` run propagates the real outcome.

NOTE on duplication with `robotics_simulation_harness.ros_observer`: this
script intentionally mirrors that module's readiness algorithm (sim-time
deadlines via `/clock`, one concurrent spin loop over every pending
topic/service/action) line-for-line rather than importing it. It runs
inside the simulation container image, which does not install the harness
package (and making the Docker build depend on installing it -- a private,
unpublished-to-PyPI package -- would couple image builds to harness's
release cadence over the network at build time for a script this small).
If this algorithm changes again, change both copies.
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any, Callable


def _action_service_names(action_name: str) -> tuple[str, str]:
    return f"{action_name}/_action/send_goal", f"{action_name}/_action/get_result"


def _action_status_topic(action_name: str) -> str:
    return f"{action_name}/_action/status"


class _SimClock:
    def __init__(self) -> None:
        self.sim_sec: float | None = None
        self._session_start_sim: float | None = None
        self._session_start_wall = time.monotonic()

    def callback(self, msg: Any) -> None:
        self.sim_sec = msg.clock.sec + msg.clock.nanosec / 1e9
        if self._session_start_sim is None:
            self._session_start_sim = self.sim_sec

    def elapsed(self) -> float:
        if self.sim_sec is not None and self._session_start_sim is not None:
            return self.sim_sec - self._session_start_sim
        return time.monotonic() - self._session_start_wall


class _PendingCheck:
    def __init__(self, kind: str, name: str, timeout_sec: float, check: Callable[[], bool]):
        self.kind = kind
        self.name = name
        self.timeout_sec = timeout_sec
        self.check = check


def observe(graph: dict[str, Any], *, wall_timeout_sec: int) -> tuple[bool, str, dict[str, Any]]:
    import rclpy
    from rclpy.node import Node
    from rclpy.qos import HistoryPolicy, QoSProfile, ReliabilityPolicy
    from rosgraph_msgs.msg import Clock

    rclpy.init()
    node = Node("infra_cross_repo_ros_observer")
    sim_clock = _SimClock()
    clock_qos = QoSProfile(
        depth=1, reliability=ReliabilityPolicy.BEST_EFFORT, history=HistoryPolicy.KEEP_LAST
    )
    node.create_subscription(Clock, "/clock", sim_clock.callback, clock_qos)

    observed: dict[str, Any] = {"topics": {}, "services": {}, "actions": {}}
    hard_deadline = time.monotonic() + wall_timeout_sec
    pending: list[_PendingCheck] = []

    def _add_topic(topic: dict[str, Any]) -> None:
        name = topic["name"]
        pub_needed = int(topic["publisher_match"]["min_count"])
        sub_needed = int(topic["subscriber_match"]["min_count"])
        timeout_sec = int(topic["publisher_match"]["timeout_sec"])

        def check() -> bool:
            pubs = node.count_publishers(name)
            subs = node.count_subscribers(name)
            observed["topics"][name] = {"publishers": pubs, "subscribers": subs}
            return pubs >= pub_needed and subs >= sub_needed

        pending.append(_PendingCheck("topic", name, timeout_sec, check))

    def _add_service(service: dict[str, Any]) -> None:
        name = service["name"]
        timeout_sec = int(service["ready_timeout_sec"])

        def check() -> bool:
            available = name in dict(node.get_service_names_and_types())
            observed["services"][name] = {"available": available}
            return available

        pending.append(_PendingCheck("service", name, timeout_sec, check))

    def _add_action(action: dict[str, Any]) -> None:
        name = action["name"]
        timeout_sec = int(action["ready_timeout_sec"])
        send_goal, get_result = _action_service_names(name)
        status_topic = _action_status_topic(name)

        def check() -> bool:
            known_services = dict(node.get_service_names_and_types())
            known_topics = {n for n, _ in node.get_topic_names_and_types()}
            available = (
                send_goal in known_services
                and get_result in known_services
                and status_topic in known_topics
            )
            observed["actions"][name] = {"available": available}
            return available

        pending.append(_PendingCheck("action", name, timeout_sec, check))

    for topic in graph.get("topics", []):
        _add_topic(topic)
    for service in graph.get("services", []):
        _add_service(service)
    for action in graph.get("actions", []):
        _add_action(action)

    try:
        while pending:
            if time.monotonic() >= hard_deadline:
                failed = pending[0]
                return False, f"{failed.kind} readiness failed for {failed.name} (wall timeout)", observed
            rclpy.spin_once(node, timeout_sec=0.2)
            elapsed = sim_clock.elapsed()
            still_pending = []
            for item in pending:
                if item.check():
                    continue
                if elapsed >= item.timeout_sec:
                    return False, f"{item.kind} readiness failed for {item.name}", observed
                still_pending.append(item)
            pending = still_pending

        if graph.get("require_clock") and "/clock" not in observed["topics"]:
            return False, "/clock required but not observed", observed
        return True, "graph ready", observed
    finally:
        node.destroy_node()
        rclpy.shutdown()


def main() -> int:
    graph_path = Path(
        os.environ.get("ROBOTICS_EXPECTED_GRAPH_PATH", "/workspace/runs/current/expected-graph.json")
    )
    result_path = Path(
        os.environ.get("ROBOTICS_GRAPH_RESULT_PATH", "/workspace/runs/current/graph-observed.json")
    )
    graph = json.loads(graph_path.read_text(encoding="utf-8"))
    timeout_sec = int(graph.get("graph_ready_timeout_sec", 30))

    ok, message, observed = observe(graph, wall_timeout_sec=timeout_sec)
    result_path.parent.mkdir(parents=True, exist_ok=True)
    result_path.write_text(
        json.dumps({"ok": ok, "message": message, "observed": observed}, indent=2) + "\n",
        encoding="utf-8",
    )
    print(json.dumps({"ok": ok, "message": message}))
    if not ok:
        print(message, file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
