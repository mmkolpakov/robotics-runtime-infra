"""Finite native provider observation before the periodic writer starts."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import sys
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--output", type=Path, required=True)
p.add_argument("--image-id", required=True)
a = p.parse_args()
a.output.mkdir(exist_ok=False)


def native(command: list[str]) -> bytes:
    return subprocess.run(command, capture_output=True, check=True, timeout=180).stdout


before = (
    native(
        [
            "ros2",
            "param",
            "get",
            "/simulator",
            "world_sdf_file",
            "--hide-type",
            "--timeout",
            "30",
        ]
    )
    .decode()
    .strip()
)
world = Path(before).resolve(strict=True)
if not (
    str(world).startswith("/opt/robotics_ws/")
    or str(world).startswith("/run/robotics/")
):
    raise ValueError("native world path outside admitted runtime assets")
raw = world.read_bytes()
(a.output / "world.sdf").write_bytes(raw)
version = native(["gz", "sim", "--versions"]).decode().strip()
observed = native(
    [
        sys.executable,
        "-m",
        "robotics_runtime_infra.simulation_control",
        "--namespace",
        "/simulator",
        "verify",
        "--steps",
        "5",
        "--step-size-ns",
        "1000000",
    ]
)
(a.output / "observation.json").write_bytes(observed)
after = (
    native(
        [
            "ros2",
            "param",
            "get",
            "/simulator",
            "world_sdf_file",
            "--hide-type",
            "--timeout",
            "30",
        ]
    )
    .decode()
    .strip()
)
if after != before or world.read_bytes() != raw:
    raise ValueError("native world changed during conformance")
configuration = {
    "implementation_id": "gz_sim",
    "version": version,
    "service_namespace": "/simulator",
    "container_image_id": a.image_id,
    "world_path": str(world),
    "world_sha256": hashlib.sha256(raw).hexdigest(),
    "world_size_bytes": len(raw),
}
(a.output / "configuration.json").write_text(json.dumps(configuration, indent=2) + "\n")
print(
    json.dumps(
        {
            "observed": True,
            "worldSha256": configuration["world_sha256"],
            "imageId": a.image_id,
            "destructiveReset": False,
        }
    )
)
