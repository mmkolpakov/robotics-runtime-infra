"""Prepare live neutral inputs through existing public admission/CLI tools."""

from __future__ import annotations

import argparse
import json
import os
import platform
import shutil
import subprocess
from pathlib import Path

from robotics_runtime_contracts import load_mapping


def copy_capture_configurations(source, inputs, data):
    for relative, name in (
        ("config/recording/qos-overrides.yaml", "qos-overrides.yaml"),
        (
            "host/test/fixtures/legacy-live/mcap-writer-small-segment.yaml",
            "mcap-writer.yaml",
        ),
    ):
        raw = (source / relative).read_bytes()
        for target in (
            data / "configuration/capture" / name,
            inputs / "config/recording" / name,
        ):
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_bytes(raw)


p = argparse.ArgumentParser()
p.add_argument("--source", type=Path, required=True)
p.add_argument("--input", type=Path, required=True)
p.add_argument("--data", type=Path, required=True)
p.add_argument("--run-id", required=True)
a = p.parse_args()
command = [
    "/opt/contracts/bin/python",
    str(a.source / "host/workers/legacy/prepare-source.py"),
    "--source",
    str(a.source),
    "--destination",
    str(a.input),
]
admitted = subprocess.run(command, capture_output=True, check=True)
plan = json.loads(admitted.stdout)
data = a.data
for relative in (
    "evidence/bags",
    "results",
    "logs",
    "configuration/capture",
):
    (data / relative).mkdir(parents=True, exist_ok=True)
(data / "configuration/robot-description-admission.json").write_bytes(admitted.stdout)
scenario = a.source / "examples/neutral-robot/scenario.yaml"
shutil.copyfile(scenario, data / "scenario.yaml")
subprocess.run(
    [
        "/opt/contracts/bin/robotics-acceptance",
        "create-run",
        "--scenario",
        str(data / "scenario.yaml"),
        "--output",
        str(data / "acceptance-run.json"),
        "--run-id",
        a.run_id,
        "--domain",
        "primary=observer",
        "--time-authority",
        "sim_clock",
        "--time-source",
        "gazebo-clock",
    ],
    check=True,
    stdout=subprocess.PIPE,
)
copy_capture_configurations(a.source, a.input, data)
target = a.input / "config/observability/otel-collector.yaml"
target.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(a.source / "host/test/fixtures/legacy-live/otel-collector.yaml", target)
target = a.input / "helpers/capture-provider.py"
shutil.copyfile(a.source / "host/workers/legacy-live/capture-provider.py", target)
shutil.copyfile(
    a.source / "config/fastdds/udp-only.xml", data / "configuration/fastdds-profile.xml"
)
(data / "configuration/host-topology.json").write_bytes(
    subprocess.run(["lscpu", "--json"], capture_output=True, check=True).stdout
)
release = platform.freedesktop_os_release()
(data / "configuration/host-platform.json").write_text(
    json.dumps(
        {
            "os": release["ID"],
            "os_version": release["VERSION_ID"],
            "architecture": platform.machine(),
            "kernel": platform.release(),
        }
    )
    + "\n"
)
for base, dirs, files in os.walk(data):
    os.chown(base, 1000, 1000)
    os.chmod(base, 0o2770)
    for name in files:
        os.chown(Path(base) / name, 1000, 1000)
for base, dirs, files in os.walk(a.input):
    os.chown(base, 1000, 1000)
    os.chmod(base, 0o755)
    for name in files:
        os.chown(Path(base) / name, 1000, 1000)
        os.chmod(Path(base) / name, 0o444)
document = load_mapping(scenario)
print(
    json.dumps(
        {
            "runId": a.run_id,
            "metricsTopic": "/example/sequence",
            "recordRegex": "^("
            + "|".join(document["evidence_policy"]["topics"])
            + ")$",
            "admittedFiles": plan["files"],
        }
    )
)
