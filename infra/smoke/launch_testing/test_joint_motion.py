#!/usr/bin/env python3
"""Headless Gazebo joint motion smoke with structured metrics."""

from __future__ import annotations

import json
import os
import re
import subprocess
import time
from pathlib import Path


ERROR_RE = re.compile(r"(error|failed|exception)", re.IGNORECASE)


def main() -> int:
    world_path = os.environ.get(
        "SMOKE_JOINT_WORLD_PATH", "/workspace/infra/smoke/worlds/joint_motion.sdf"
    )
    iterations = int(os.environ.get("SMOKE_JOINT_ITERATIONS", "200"))
    log_dir = Path(os.environ.get("SMOKE_LOG_DIR", "/tmp/robotics-smoke"))
    metrics_path = Path(
        os.environ.get("SMOKE_JOINT_METRICS_PATH", str(log_dir / "joint_motion_metrics.json"))
    )
    log_dir.mkdir(parents=True, exist_ok=True)
    log_path = log_dir / "joint_motion.log"

    started = time.monotonic()
    completed = subprocess.run(
        [
            "bash",
            "-lc",
            (
                "source /etc/profile.d/robotics_ros_setup.sh && "
                f"gz sim -s -r -v 3 --iterations {iterations} {world_path}"
            ),
        ],
        check=False,
        capture_output=True,
        text=True,
    )
    duration_s = time.monotonic() - started
    log_path.write_text(completed.stdout + completed.stderr, encoding="utf-8")

    failed = completed.returncode != 0 or bool(ERROR_RE.search(completed.stdout + completed.stderr))
    metrics = {
        "iterations": iterations,
        "duration_s": round(duration_s, 3),
        "returncode": completed.returncode,
        "result": "fail" if failed else "pass",
    }
    metrics_path.write_text(json.dumps(metrics, indent=2) + "\n", encoding="utf-8")
    print(json.dumps(metrics))
    if failed:
        print(log_path.read_text(encoding="utf-8")[-2000:])
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
