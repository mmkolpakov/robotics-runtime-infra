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
"""

from __future__ import annotations

import json
import os
import sys
import time
from pathlib import Path
from typing import Any


def _action_service_names(action_name: str) -> tuple[str, str]:
    return f"{action_name}/_action/send_goal", f"{action_name}/_action/get_result"


def _action_status_topic(action_name: str) -> str:
    return f"{action_name}/_action/status"


def observe(graph: dict[str, Any], *, wall_timeout_sec: int) -> tuple[bool, str, dict[str, Any]]:
    import rclpy
    from rclpy.node import Node

    rclpy.init()
    node = Node("infra_cross_repo_ros_observer")
    observed: dict[str, Any] = {"topics": {}, "services": {}, "actions": {}}
    deadline = time.monotonic() + wall_timeout_sec
    try:
        for topic in graph.get("topics", []):
            name = topic["name"]
            pub_needed = int(topic["publisher_match"]["min_count"])
            sub_needed = int(topic["subscriber_match"]["min_count"])
            topic_deadline = min(
                deadline, time.monotonic() + int(topic["publisher_match"]["timeout_sec"])
            )
            while True:
                pubs = node.count_publishers(name)
                subs = node.count_subscribers(name)
                observed["topics"][name] = {"publishers": pubs, "subscribers": subs}
                if pubs >= pub_needed and subs >= sub_needed:
                    break
                if time.monotonic() >= topic_deadline:
                    return False, f"topic readiness failed for {name}", observed
                rclpy.spin_once(node, timeout_sec=0.2)

        for service in graph.get("services", []):
            name = service["name"]
            service_deadline = min(
                deadline, time.monotonic() + int(service["ready_timeout_sec"])
            )
            while True:
                available = name in dict(node.get_service_names_and_types())
                observed["services"][name] = {"available": available}
                if available:
                    break
                if time.monotonic() >= service_deadline:
                    return False, f"service readiness failed for {name}", observed
                rclpy.spin_once(node, timeout_sec=0.2)

        for action in graph.get("actions", []):
            name = action["name"]
            action_deadline = min(deadline, time.monotonic() + int(action["ready_timeout_sec"]))
            send_goal, get_result = _action_service_names(name)
            status_topic = _action_status_topic(name)
            while True:
                known_services = dict(node.get_service_names_and_types())
                known_topics = {n for n, _ in node.get_topic_names_and_types()}
                available = (
                    send_goal in known_services
                    and get_result in known_services
                    and status_topic in known_topics
                )
                observed["actions"][name] = {"available": available}
                if available:
                    break
                if time.monotonic() >= action_deadline:
                    return False, f"action readiness failed for {name}", observed
                rclpy.spin_once(node, timeout_sec=0.2)

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
