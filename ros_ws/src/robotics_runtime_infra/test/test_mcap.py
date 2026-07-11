from __future__ import annotations

import os
import re
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import launch
import launch_testing.actions
import launch_testing.markers
import rclpy
from rclpy.duration import Duration
from rosbag2_interfaces.srv import Resume
from std_msgs.msg import String


@launch_testing.markers.keep_alive
def generate_test_description() -> launch.LaunchDescription:
    return launch.LaunchDescription([launch_testing.actions.ReadyToTest()])


def stop_process(process: subprocess.Popen[str]) -> None:
    if process.poll() is not None:
        return
    os.killpg(process.pid, signal.SIGINT)
    try:
        process.wait(timeout=15)
    except subprocess.TimeoutExpired:
        os.killpg(process.pid, signal.SIGKILL)
        process.wait(timeout=5)


class TestMcap(unittest.TestCase):
    def test_record_info_and_replay(self) -> None:
        rclpy.init()
        publisher_node = rclpy.create_node("mcap_probe_publisher")
        publisher = publisher_node.create_publisher(String, "/mcap_probe", 10)
        try:
            with tempfile.TemporaryDirectory(prefix="robotics-mcap-") as temporary:
                bag = Path(temporary) / "probe"
                recorder = subprocess.Popen(
                    [
                        "ros2",
                        "bag",
                        "record",
                        "--storage",
                        "mcap",
                        "--output",
                        str(bag),
                        "--topics",
                        "/mcap_probe",
                    ],
                    text=True,
                    start_new_session=True,
                )
                try:
                    deadline = time.monotonic() + 15
                    while publisher.get_subscription_count() == 0 and time.monotonic() < deadline:
                        rclpy.spin_once(publisher_node, timeout_sec=0.1)
                    self.assertGreater(publisher.get_subscription_count(), 0)
                    for _ in range(20):
                        publisher.publish(String(data="probe"))
                        rclpy.spin_once(publisher_node, timeout_sec=0.05)
                    self.assertTrue(publisher.wait_for_all_acked(Duration(seconds=5)))
                finally:
                    stop_process(recorder)

                info = subprocess.run(
                    ["ros2", "bag", "info", str(bag)],
                    check=True,
                    capture_output=True,
                    text=True,
                ).stdout
                self.assertIn("mcap", info.lower())
                self.assertIn("/mcap_probe", info)
                match = re.search(r"Messages:\s+(\d+)", info)
                self.assertIsNotNone(match)
                self.assertGreater(int(match.group(1)), 0)

                replay_node = rclpy.create_node("mcap_probe_replay")
                received: list[String] = []
                subscription = replay_node.create_subscription(
                    String,
                    "/mcap_probe",
                    received.append,
                    10,
                )
                resume = replay_node.create_client(Resume, "/rosbag2_player/resume")
                playback = subprocess.Popen(
                    [
                        "ros2",
                        "bag",
                        "play",
                        str(bag),
                        "--start-paused",
                        "--disable-keyboard-controls",
                        "--wait-for-all-acked",
                        "5000",
                    ],
                    text=True,
                    start_new_session=True,
                )
                deadline = time.monotonic() + 30
                try:
                    self.assertTrue(resume.wait_for_service(timeout_sec=15))
                    while (
                        replay_node.count_publishers("/mcap_probe") == 0
                        and time.monotonic() < deadline
                    ):
                        rclpy.spin_once(replay_node, timeout_sec=0.1)
                    self.assertGreater(replay_node.count_publishers("/mcap_probe"), 0)

                    resume.call_async(Resume.Request())
                    while not received and time.monotonic() < deadline:
                        rclpy.spin_once(replay_node, timeout_sec=0.5)
                    self.assertTrue(received)
                    self.assertEqual(received[-1].data, "probe")
                finally:
                    stop_process(playback)
                    replay_node.destroy_client(resume)
                    replay_node.destroy_subscription(subscription)
                    replay_node.destroy_node()
        finally:
            publisher_node.destroy_publisher(publisher)
            publisher_node.destroy_node()
            rclpy.shutdown()
