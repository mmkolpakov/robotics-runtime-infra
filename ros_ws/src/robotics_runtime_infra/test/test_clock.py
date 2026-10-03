from __future__ import annotations

import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path

import rclpy
from rclpy.duration import Duration
from rclpy.executors import SingleThreadedExecutor
from rclpy.qos import (
    QoSProfile,
    ReliabilityPolicy,
    qos_profile_sensor_data,
    qos_profile_system_default,
)
from rosgraph_msgs.msg import Clock


def generate_test_description():
    import launch
    import launch.actions
    import launch.launch_description_sources
    import launch_testing.actions
    from ament_index_python.packages import get_package_share_directory

    launch_file = (
        Path(get_package_share_directory("robotics_runtime_infra"))
        / "launch"
        / "headless.launch.py"
    )
    return launch.LaunchDescription(
        [
            launch.actions.SetEnvironmentVariable(
                "GZ_PARTITION", f"clock-{os.getpid()}"
            ),
            launch.actions.IncludeLaunchDescription(
                launch.launch_description_sources.PythonLaunchDescriptionSource(
                    str(launch_file)
                )
            ),
            launch_testing.actions.ReadyToTest(),
        ]
    )


class TestClock(unittest.TestCase):
    def test_clock_is_monotonic(self) -> None:
        from launch_testing_ros import WaitForTopics

        with WaitForTopics(
            [("/clock", Clock)],
            timeout=60.0,
            messages_received_buffer_length=10,
            # A best-effort clock publisher cannot match this subscription.
            qos_profile=QoSProfile(depth=1000, reliability=ReliabilityPolicy.RELIABLE),
        ) as topics:
            deadline = time.monotonic() + 10.0
            messages = topics.received_messages("/clock")
            while len(messages) < 10 and time.monotonic() < deadline:
                time.sleep(0.1)
                messages = topics.received_messages("/clock")
            samples = [
                message.clock.sec * 1_000_000_000 + message.clock.nanosec
                for message in messages
            ]
            self.assertGreaterEqual(len(samples), 10)
            self.assertTrue(
                all(
                    current > previous
                    for previous, current in zip(samples, samples[1:])
                )
            )


def clock_queue_probe(mode: str) -> dict[str, object]:
    """Exercise DDS history while the native executor is not draining callbacks."""
    qos = {
        "system_default": qos_profile_system_default,
        "keep_last": QoSProfile(depth=5, reliability=ReliabilityPolicy.RELIABLE),
        "sensor_data": qos_profile_sensor_data,
    }[mode]
    publisher_qos = QoSProfile(
        depth=1000,
        reliability=(
            ReliabilityPolicy.BEST_EFFORT
            if mode == "sensor_data"
            else ReliabilityPolicy.RELIABLE
        ),
    )
    rclpy.init()
    node = rclpy.create_node("clock_queue_probe")
    received: list[int] = []
    subscription = node.create_subscription(
        Clock, "/clock", lambda message: received.append(message.clock.nanosec), qos
    )
    publisher = node.create_publisher(Clock, "/clock", publisher_qos)
    executor = SingleThreadedExecutor()
    executor.add_node(node)

    def until(predicate):
        deadline = time.monotonic() + 5.0
        while not predicate() and time.monotonic() < deadline:
            executor.spin_once(timeout_sec=0.02)
        if not predicate():
            raise AssertionError("native Clock discovery/delivery timed out")

    def publish(value: int) -> None:
        message = Clock()
        message.clock.nanosec = value
        publisher.publish(message)
        if not publisher.wait_for_all_acked(Duration(seconds=5)):
            raise AssertionError("native Clock acknowledgement timed out")

    try:
        until(lambda: publisher.get_subscription_count() == 1)
        publish(0)
        until(lambda: received == [0])
        # A finite paused-clock burst below the configured 1000-sample ceiling.
        for value in [1] * 100 + [2] * 100:
            publish(value)
        until(lambda: received[-1] == 2)
        result = {
            "distinct_clock": list(dict.fromkeys(received)),
            "received_count": len(received),
            # These fields are requests, not an actual-QoS readback.
            "requested_history": qos.history.name,
            "requested_reliability": qos.reliability.name,
        }
        return result
    finally:
        executor.shutdown()
        node.destroy_subscription(subscription)
        node.destroy_node()
        rclpy.shutdown()


class TestClockReaderQueue(unittest.TestCase):
    profile = Path("/etc/robotics/fastdds/udp-only.xml")

    def probe(self, profile: Path, mode: str) -> dict[str, object]:
        domain = 20 + os.getpid() % 60
        if domain == int(os.environ.get("ROS_DOMAIN_ID", "0")):
            domain = 20 + (domain - 19) % 60
        environment = dict(
            os.environ,
            FASTRTPS_DEFAULT_PROFILES_FILE=str(profile),
            RMW_FASTRTPS_USE_QOS_FROM_XML="1",
            RMW_IMPLEMENTATION="rmw_fastrtps_cpp",
            # Independent of the launch test's live Gazebo/bridge domain.
            ROS_DOMAIN_ID=str(domain),
        )
        completed = subprocess.run(
            [
                sys.executable,
                str(Path(__file__).resolve()),
                "--clock-queue-probe",
                mode,
            ],
            env=environment,
            capture_output=True,
            text=True,
            check=False,
            timeout=15,
        )
        self.assertEqual(completed.returncode, 0, completed.stdout + completed.stderr)
        return json.loads(completed.stdout)

    def test_system_default_retains_intermediate_clock_amid_paused_duplicates(self):
        tree = ET.parse(self.profile)
        namespace = {"dds": "http://www.eprosima.com/XMLSchemas/fastRTPS_Profiles"}
        profiles = tree.find("dds:profiles", namespace)
        self.assertIsNotNone(profiles)
        for reader in list(profiles):
            if reader.attrib.get("profile_name") == "/clock":
                profiles.remove(reader)
        # Existing default-reader policies give the native counterexample.
        with tempfile.TemporaryDirectory() as directory:
            baseline = Path(directory) / "baseline.xml"
            ET.register_namespace("", namespace["dds"])
            tree.write(baseline, encoding="utf-8", xml_declaration=True)
            before = self.probe(baseline, "system_default")
        after = self.probe(self.profile, "system_default")
        self.assertEqual(before["distinct_clock"], [0, 2])
        self.assertEqual(after["distinct_clock"], [0, 1, 2])

    def test_explicit_keep_last_and_playback_best_effort_remain_native(self):
        for mode in ("keep_last", "sensor_data"):
            with self.subTest(mode=mode):
                observed = self.probe(self.profile, mode)
                if mode == "keep_last":
                    self.assertEqual(observed["distinct_clock"], [0, 2])
                else:
                    self.assertIn(0, observed["distinct_clock"])
                    self.assertIn(2, observed["distinct_clock"])
                self.assertEqual(observed["requested_history"], "KEEP_LAST")


if __name__ == "__main__":
    if sys.argv[1:2] == ["--clock-queue-probe"]:
        print(json.dumps(clock_queue_probe(sys.argv[2]), sort_keys=True))
    else:
        unittest.main(defaultTest="TestClockReaderQueue")
