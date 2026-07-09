#!/usr/bin/env python3
"""Runtime readiness checks for simulation integration smoke."""

from __future__ import annotations

import os
import signal
import subprocess
import time
from pathlib import Path


def wait_for_topic(topic: str, timeout_sec: int) -> None:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        completed = subprocess.run(
            ["bash", "-lc", "source /etc/profile.d/robotics_ros_setup.sh && ros2 topic list"],
            check=False,
            capture_output=True,
            text=True,
        )
        topics = {line.strip() for line in completed.stdout.splitlines() if line.strip()}
        if topic in topics:
            return
        time.sleep(0.5)
    raise TimeoutError(f"Timed out waiting for topic {topic}")


def terminate_process_group(proc: subprocess.Popen[str]) -> None:
    if proc.poll() is not None:
        return
    try:
        os.killpg(proc.pid, signal.SIGTERM)
    except ProcessLookupError:
        return
    try:
        proc.wait(timeout=10)
    except subprocess.TimeoutExpired:
        os.killpg(proc.pid, signal.SIGKILL)
        proc.wait(timeout=5)


def main() -> int:
    world_path = os.environ.get("SMOKE_WORLD_PATH", "/workspace/infra/smoke/worlds/empty.sdf")
    launch_path = os.environ.get(
        "SMOKE_LAUNCH_PATH", "/workspace/launch/simulation_smoke.launch.py"
    )
    clock_topic = os.environ.get("SMOKE_CLOCK_TOPIC", "/clock")
    mavros_state_topic = os.environ.get("SMOKE_MAVROS_STATE_TOPIC", "/mavros/state")
    mavros_fcu_url = os.environ.get("SMOKE_MAVROS_FCU_URL", "udp://:14540@")
    timeout_seconds = int(os.environ.get("SMOKE_TIMEOUT_SECONDS", "45"))
    log_dir = Path(os.environ.get("SMOKE_LOG_DIR", "/tmp/robotics-smoke"))
    log_dir.mkdir(parents=True, exist_ok=True)

    launch_log = open(log_dir / "launch.log", "w", encoding="utf-8")
    mavros_log = open(log_dir / "mavros.log", "w", encoding="utf-8")
    procs: list[subprocess.Popen[str]] = []
    try:
        launch_proc = subprocess.Popen(
            [
                "bash",
                "-lc",
                (
                    "source /etc/profile.d/robotics_ros_setup.sh && "
                    f"ros2 launch {launch_path} world:={world_path}"
                ),
            ],
            stdout=launch_log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
        )
        procs.append(launch_proc)
        wait_for_topic(clock_topic, timeout_seconds)

        mavros_proc = subprocess.Popen(
            [
                "bash",
                "-lc",
                (
                    "source /etc/profile.d/robotics_ros_setup.sh && "
                    "ros2 run mavros mavros_node --ros-args "
                    f"-p fcu_url:={mavros_fcu_url}"
                ),
            ],
            stdout=mavros_log,
            stderr=subprocess.STDOUT,
            start_new_session=True,
            text=True,
        )
        procs.append(mavros_proc)
        wait_for_topic(mavros_state_topic, timeout_seconds)

        listed = subprocess.run(
            ["bash", "-lc", "source /etc/profile.d/robotics_ros_setup.sh && ros2 topic list"],
            check=True,
            capture_output=True,
            text=True,
        )
        print(listed.stdout)
        return 0
    finally:
        for proc in procs:
            terminate_process_group(proc)
        launch_log.close()
        mavros_log.close()


if __name__ == "__main__":
    raise SystemExit(main())
