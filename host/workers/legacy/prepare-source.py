#!/usr/bin/env python3
"""Finite bridge to the existing public admission helper and exact file snapshot."""

import argparse
import os
from robotics_runtime_contracts import load_mapping
import hashlib
import json
from pathlib import Path
import shutil
import subprocess

parser = argparse.ArgumentParser()
parser.add_argument("--source", type=Path, required=True)
parser.add_argument("--destination", type=Path, required=True)
parser.add_argument("--wrong-digest", action="store_true")
args = parser.parse_args()
source = args.source.resolve(strict=True)
destination = args.destination
scenario = source / "examples/neutral-robot/scenario.yaml"
if args.wrong_digest:
    document = load_mapping(scenario)
    document["workload"]["robot_description_sha256"] = "0" * 64
    scenario = Path("/tmp/wrong-scenario.json")
    scenario.write_text(json.dumps(document))
command = [
    "/opt/contracts/bin/python",
    str(source / "docker/runtime/admit-robot-description"),
    "--root",
    str(source),
    "--scenario",
    str(scenario),
    "--artifact",
    "other_evidence:products/robot-description/examples/neutral-robot/sim/robot-description.json=examples/neutral-robot/sim/robot-description.json",
]
result = subprocess.run(
    command, stdout=subprocess.PIPE, stderr=subprocess.PIPE, check=False
)
if result.returncode:
    print(result.stderr.decode(), end="")
    raise SystemExit(result.returncode)
plan = json.loads(result.stdout)
if not plan["selected"]:
    raise RuntimeError("native robot not selected")
for entry in plan["files"]:
    src = source / entry["path"]
    raw = src.read_bytes()
    if (
        hashlib.sha256(raw).hexdigest() != entry["sha256"]
        or len(raw) != entry["size_bytes"]
    ):
        raise RuntimeError("admitted file changed before snapshot")
    dst = destination / "product" / entry["path"]
    dst.parent.mkdir(parents=True, exist_ok=True)
    dst.write_bytes(raw)
    dst.chmod(0o444)
for path in [
    "examples/neutral-robot/check-entity.py",
    "host/workers/legacy/observe-clock-owner.py",
    "host/workers/legacy/observe-robot-ready.py",
    "host/workers/legacy/capture-last-state.py",
]:
    dst = destination / "helpers" / Path(path).name
    dst.parent.mkdir(parents=True, exist_ok=True)
    shutil.copyfile(source / path, dst)
    dst.chmod(0o444)
profile = destination / "config/fastdds/udp-only.xml"
profile.parent.mkdir(parents=True, exist_ok=True)
shutil.copyfile(source / "config/fastdds/udp-only.xml", profile)
profile.chmod(0o444)
for base, dirs, files in os.walk(destination):
    os.chown(base, 1000, 1000)
    for name in files:
        os.chown(Path(base) / name, 1000, 1000)
print(result.stdout.decode(), end="")
