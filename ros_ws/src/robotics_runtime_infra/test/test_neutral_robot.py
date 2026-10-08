from __future__ import annotations

import math
import os
import subprocess
import time
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

import launch
import launch.actions
import launch.launch_description_sources
import launch_testing.actions
import launch_testing.asserts
import rclpy
from ament_index_python.packages import get_package_share_directory
from rclpy.qos import DurabilityPolicy, QoSProfile, ReliabilityPolicy
from rosgraph_msgs.msg import Clock
from sensor_msgs.msg import JointState
from simulation_interfaces.msg import Result
from simulation_interfaces.srv import GetEntities
from std_msgs.msg import String
from tf2_msgs.msg import TFMessage


def generate_test_description():
    share = Path(get_package_share_directory("robotics_runtime_infra"))
    description_file = share / "description" / "neutral_robot.urdf"
    deadline = time.monotonic() + 90.0
    return launch.LaunchDescription(
        [
            launch.actions.SetEnvironmentVariable(
                "GZ_PARTITION", f"neutral-robot-{os.getpid()}"
            ),
            launch.actions.IncludeLaunchDescription(
                launch.launch_description_sources.FrontendLaunchDescriptionSource(
                    str(share / "launch" / "neutral_robot.launch.xml")
                ),
                launch_arguments={"description_file": str(description_file)}.items(),
            ),
            launch_testing.actions.ReadyToTest(),
        ]
    ), {"description_file": description_file, "deadline": deadline}


class TestNeutralRobot(unittest.TestCase):
    def test_native_description_spawn_and_tf(
        self, proc_info, proc_output, description_file, deadline
    ) -> None:
        def remaining() -> float:
            value = deadline - time.monotonic()
            self.assertGreater(value, 0.0, "neutral robot wall-clock deadline exceeded")
            return value

        checked = subprocess.run(
            ["check_urdf", str(description_file)],
            capture_output=True,
            text=True,
            check=False,
            timeout=remaining(),
        )
        self.assertEqual(checked.returncode, 0, checked.stdout + checked.stderr)
        print(checked.stdout, end="")
        canonical = description_file.read_text(encoding="utf-8")
        robot = ET.fromstring(canonical)
        self.assertEqual(robot.attrib["name"], "neutral_robot")
        self.assertEqual(
            [link.attrib["name"] for link in robot.findall("link")],
            ["base_link", "slider_link"],
        )
        self.assertEqual(len(robot.findall("joint")), 1)
        self.assertEqual(robot.find("joint").attrib["type"], "prismatic")

        # Only this launch's native create process can satisfy both conditions.
        proc_info.assertWaitForShutdown("neutral_robot_create", timeout=remaining())
        launch_testing.asserts.assertExitCodes(
            proc_info, allowable_exit_codes=[0], process="neutral_robot_create"
        )
        proc_output.assertWaitFor(
            "Entity creation successful.",
            process="neutral_robot_create",
            stream="stderr",
            timeout=remaining(),
        )
        remaining()

        rclpy.init()
        node = rclpy.create_node("neutral_robot_acceptance_test")
        clocks: list[int] = []
        joint_states: list[JointState] = []
        transforms = []
        descriptions: list[str] = []

        def receive_tf(message: TFMessage) -> None:
            transforms.extend(
                transform
                for transform in message.transforms
                if transform.header.frame_id == "base_link"
                and transform.child_frame_id == "slider_link"
            )

        subscriptions = [
            node.create_subscription(
                Clock,
                "/clock",
                lambda message: clocks.append(
                    message.clock.sec * 1_000_000_000 + message.clock.nanosec
                ),
                QoSProfile(depth=1000, reliability=ReliabilityPolicy.RELIABLE),
            ),
            node.create_subscription(
                JointState, "/joint_states", joint_states.append, 10
            ),
            node.create_subscription(TFMessage, "/tf", receive_tf, 10),
            node.create_subscription(
                String,
                "/robot_description",
                lambda message: descriptions.append(message.data),
                QoSProfile(depth=1, durability=DurabilityPolicy.TRANSIENT_LOCAL),
            ),
        ]
        try:
            entity_client = node.create_client(GetEntities, "/simulator/get_entities")
            self.assertTrue(entity_client.wait_for_service(timeout_sec=remaining()))
            while True:
                future = entity_client.call_async(GetEntities.Request())
                rclpy.spin_until_future_complete(node, future, timeout_sec=remaining())
                self.assertTrue(future.done(), "GetEntities timed out")
                response = future.result()
                self.assertIsInstance(response, GetEntities.Response)
                self.assertEqual(
                    response.result.result,
                    Result.RESULT_OK,
                    response.result.error_message,
                )
                if "neutral_robot" in response.entities:
                    print(f"Gazebo GetEntities: {response.entities}")
                    break
                time.sleep(min(0.1, remaining()))
            while not (
                len(clocks) >= 2
                and clocks[-1] > clocks[0]
                and joint_states
                and joint_states[-1].header.stamp.sec * 1_000_000_000
                + joint_states[-1].header.stamp.nanosec
                > 0
                and transforms
                and transforms[-1].header.stamp.sec * 1_000_000_000
                + transforms[-1].header.stamp.nanosec
                > 0
                and descriptions
            ):
                rclpy.spin_once(node, timeout_sec=min(0.1, remaining()))
            self.assertEqual(descriptions[-1], canonical)
            self.assertTrue(
                all(
                    current >= previous for previous, current in zip(clocks, clocks[1:])
                )
            )
            state = joint_states[-1]
            self.assertEqual(state.name, ["slider_joint"])
            self.assertEqual(len(state.position), 1)
            self.assertTrue(math.isfinite(state.position[0]))
            self.assertAlmostEqual(state.position[0], 0.0)
            state_stamp = (
                state.header.stamp.sec * 1_000_000_000 + state.header.stamp.nanosec
            )
            self.assertGreater(state_stamp, 0)
            self.assertLessEqual(state_stamp, clocks[-1] + 1_000_000_000)
            transform = transforms[-1]
            xyz = transform.transform.translation
            rotation = transform.transform.rotation
            self.assertTrue(
                all(
                    math.isfinite(value)
                    for value in (
                        xyz.x,
                        xyz.y,
                        xyz.z,
                        rotation.x,
                        rotation.y,
                        rotation.z,
                        rotation.w,
                    )
                )
            )
            self.assertAlmostEqual(xyz.x, 0.2)
            self.assertAlmostEqual(xyz.y, 0.0)
            self.assertAlmostEqual(xyz.z, 0.0)
            self.assertAlmostEqual(rotation.x, 0.0)
            self.assertAlmostEqual(rotation.y, 0.0)
            self.assertAlmostEqual(rotation.z, 0.0)
            self.assertAlmostEqual(rotation.w, 1.0)
            tf_stamp = (
                transform.header.stamp.sec * 1_000_000_000
                + transform.header.stamp.nanosec
            )
            self.assertGreater(tf_stamp, 0)
            self.assertLessEqual(tf_stamp, clocks[-1] + 1_000_000_000)
            remaining()
        finally:
            for subscription in subscriptions:
                node.destroy_subscription(subscription)
            node.destroy_node()
            rclpy.shutdown()
