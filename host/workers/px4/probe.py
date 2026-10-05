"""Finite native Gz Transport observation; no flight or physics implementation."""

from __future__ import annotations

import argparse
import hashlib
import os
import json
import math
import threading
import time
from pathlib import Path

from google.protobuf.json_format import MessageToDict
from gz.transport import Node
from gz.msgs.boolean_pb2 import Boolean
from gz.msgs.empty_pb2 import Empty
from gz.msgs.scene_pb2 import Scene
from gz.msgs.pose_v_pb2 import Pose_V
from gz.msgs.world_control_pb2 import WorldControl
from gz.msgs.world_stats_pb2 import WorldStatistics


def ns(value) -> str:
    return str(value.sec * 1_000_000_000 + value.nsec)


def run(args) -> dict:
    node = Node()
    service = f"/world/{args.world}"
    executed, scene = node.request(service + "/scene/info", Empty(), Empty, Scene, 3000)
    found = [m for m in scene.model if m.name == args.model] if executed else []
    if len(found) != 1:
        raise RuntimeError(
            "native Scene response does not contain exactly one admitted model"
        )
    init = Path("/proc/1/exe")
    identity = {
        "pid": 1,
        "comm": Path("/proc/1/comm").read_text().strip(),
        "executable": os.readlink(init),
        "sha256": hashlib.sha256(init.read_bytes()).hexdigest(),
    }
    result = {
        "oci_init": identity,
        "owner_id": args.owner_id,
        "model": args.model,
        "world": args.world,
        "service_executed": executed,
        "scene": MessageToDict(scene, preserving_proto_field_name=True),
    }
    if args.mode == "ready":
        result["ready"] = True
        return result
    observations = []
    stats = []
    lock = threading.Lock()

    def pose(message):
        matches = [p for p in message.pose if p.name == args.model]
        if len(matches) == 1:
            z = matches[0].position.z
            if not math.isfinite(z):
                return
            with lock:
                if len(observations) < 10000:
                    observations.append(
                        {
                            "z_m": z,
                            "simulation_ns": ns(message.header.stamp),
                            "native_pose": MessageToDict(
                                matches[0], preserving_proto_field_name=True
                            ),
                        }
                    )

    def statistics(message):
        with lock:
            if len(stats) < 10000:
                stats.append(
                    {"paused": message.paused, "simulation_ns": ns(message.sim_time)}
                )

    if not node.subscribe(Pose_V, service + "/dynamic_pose/info", pose):
        raise RuntimeError("native pose subscription refused")
    if not node.subscribe(WorldStatistics, service + "/stats", statistics):
        raise RuntimeError("native stats subscription refused")
    if args.mode == "last-state":
        # Observe a native baseline before pausing; a paused world need not publish another pose.
        baseline_end = time.monotonic() + 3
        while time.monotonic() < baseline_end:
            with lock:
                present = bool(observations and stats)
            if present:
                break
            time.sleep(0.02)
        if not present:
            raise RuntimeError("native pre-pause baseline was not observed")
        executed, response = node.request(
            service + "/control", WorldControl(pause=True), WorldControl, Boolean, 3000
        )
        result["pause_request"] = {
            "executed": executed,
            "native_response": response.data,
        }
        if not executed or not response.data:
            raise RuntimeError("native WorldControl pause was not acknowledged")
    end = time.monotonic() + args.seconds
    while time.monotonic() < end:
        time.sleep(0.02)
    node.unsubscribe(service + "/dynamic_pose/info")
    node.unsubscribe(service + "/stats")
    if not observations or not stats:
        raise RuntimeError("native pose/statistics were not observed")
    result.update({"poses": observations, "statistics": stats, "ready": True})
    if args.mode == "last-state":
        tail = stats[-2:]
        if (
            len(tail) != 2
            or not all(v["paused"] for v in tail)
            or len({v["simulation_ns"] for v in tail}) != 1
        ):
            raise RuntimeError("native paused Clock was not observed quiescent")
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--mode", choices=("ready", "observe", "last-state"), required=True
    )
    parser.add_argument("--world", default="default")
    parser.add_argument("--model", default="x500_0")
    parser.add_argument("--owner-id", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--seconds", type=float, default=3.0)
    args = parser.parse_args()
    if not 0 < args.seconds <= 60 or not args.output.is_absolute():
        parser.error("finite duration and absolute output required")
    # Reserve output before native effects. An earlier attempt is never overwritten.
    with args.output.open("x") as stream:
        try:
            facts = run(args)
        except Exception as error:
            json.dump(
                {"owner_id": args.owner_id, "ready": False, "diagnostic": str(error)},
                stream,
            )
            stream.write("\n")
            raise
        json.dump(facts, stream, allow_nan=False)
        stream.write("\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
