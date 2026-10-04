#!/usr/bin/env python3
"""Read-only native ROS clock ownership and continuing advancement gate."""

import json
import time
import rclpy
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy
from rosgraph_msgs.msg import Clock

rclpy.init()
node = Node("legacy_clock_owner_probe")
samples = []
node.create_subscription(
    Clock,
    "/clock",
    lambda m: samples.append(m.clock.sec * 1_000_000_000 + m.clock.nanosec),
    QoSProfile(depth=1000, reliability=ReliabilityPolicy.RELIABLE),
)
try:
    deadline = time.monotonic() + 30
    while time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.05)
        if len(samples) >= 2 and samples[-1] > samples[0] and samples[-1] > 0:
            publishers = node.get_publishers_info_by_topic("/clock")
            if len(publishers) != 1:
                raise RuntimeError(
                    "legacy clock channel must have one observed publisher"
                )
            print(
                json.dumps(
                    {
                        "status": "passed",
                        "first_ns": str(samples[0]),
                        "last_ns": str(samples[-1]),
                        "publisher_count": len(publishers),
                        "publisher_node": publishers[0].node_name,
                        "scope": "channel publisher plus observed advancement; stepper process checked separately",
                    }
                )
            )
            break
    else:
        raise RuntimeError("native Clock did not continue advancing before deadline")
finally:
    node.destroy_node()
    rclpy.shutdown()
