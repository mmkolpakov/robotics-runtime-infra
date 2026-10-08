"""Project actual native metadata into existing provider/manifest workers."""

from __future__ import annotations

import argparse
import json
import shutil
import subprocess
from pathlib import Path

p = argparse.ArgumentParser()
p.add_argument("--source", type=Path, required=True)
p.add_argument("--data", type=Path, required=True)
p.add_argument("--native-metadata", type=Path, required=True)
p.add_argument("--run-id", required=True)
p.add_argument("--project", required=True)
p.add_argument("--subject-digest", required=True)
a = p.parse_args()
metadata = a.native_metadata
if metadata.is_dir():
    candidates = sorted(metadata.glob("*simulation-native-metadata.json"))
    if len(candidates) != 1:
        raise ValueError("one retained native simulation metadata snapshot is required")
    metadata = candidates[0]
observed = json.loads(metadata.read_bytes())
native = observed["container"]
labels = native["Config"]["Labels"]
if (
    observed["status"] != "complete"
    or labels["org.robotics.runtime.run-id"] != a.run_id
    or labels["com.docker.compose.project"] != a.project
):
    raise ValueError("runtime metadata is not the observed owned source")
fields = (
    "NanoCpus",
    "CpuPeriod",
    "CpuQuota",
    "CpusetCpus",
    "Memory",
    "MemorySwap",
    "ShmSize",
)
resources = {key: native["HostConfig"][key] for key in fields}
(a.data / "configuration/runtime-resources.json").write_text(
    json.dumps(resources, indent=2) + "\n"
)
provider = a.data / "provider"
shutil.copyfile(
    a.source / "config/qualification/simulation-interfaces.json",
    provider / "profile.json",
)
command = [
    "/opt/contracts/bin/python",
    str(a.source / "scripts/ci/foundation/create-simulation-provider.py"),
    "--scenario",
    str(a.data / "scenario.yaml"),
    "--run-context",
    str(a.data / "acceptance-run.json"),
    "--profile",
    str(provider / "profile.json"),
    "--configuration",
    str(provider / "configuration.json"),
    "--observation",
    str(provider / "observation.json"),
    "--world",
    str(provider / "world.sdf"),
    "--subject-digest",
    a.subject_digest,
    "--output",
    str(provider / "conformance.json"),
]
bindings = subprocess.run(command, capture_output=True, check=True, timeout=30)
(provider / "bindings.json").write_bytes(bindings.stdout)
subprocess.run(
    [
        "bash",
        str(a.source / "docker/runtime/emit-runtime-manifest"),
        str(a.data / "runtime-manifest.json"),
    ],
    check=True,
    timeout=30,
)
print(
    json.dumps(
        {
            "ready": True,
            "actualContainerId": native["Id"],
            "actualImageId": native["Image"],
            "providerBindings": str(provider / "bindings.json"),
        }
    )
)
