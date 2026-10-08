"""Build a source-only OCI worker from unpatched stock PX4 build outputs."""

from __future__ import annotations
import argparse
import hashlib
import json
import shutil
import subprocess
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
COMMIT = "d6f12ad1c4f70ad3230afd7d86e971421e02fef4"
SUBMODULES = {
    "Tools/simulation/gz": "b6127f4ec20de867e215fb5f78ae88b80f371909",
    "src/drivers/gps/devices": "0b9695881bd1e8f830ab4538ab3acc0050019eba",
    "src/lib/events/libevents": "9ef591c447fe0386d698bf6fb9a6d27e43988ee4",
    "src/lib/heatshrink/heatshrink": "052e6de72f67f1777198bce98f3de62f7f3c16a0",
    "src/lib/cdrstream/cyclonedds": "314887ca403c2fb0a0316add22672102936ed36c",
    "src/lib/cdrstream/rosidl": "bf5682e4747843d1d5133b9a2b54ce6f12f166c7",
    "src/modules/mavlink/mavlink": "33af200d25ec6f0925b49b1ba82bbf1294ea5f72",
    "src/modules/mavlink/mavlink/pymavlink": "fcaa2c7d25e3169dc66155929c338487941555e9",
    "src/modules/uxrce_dds_client/Micro-XRCE-DDS-Client": "711aef423edd1820347b866d1e4164832df35d04",
}


def command(argv, cwd=None):
    return subprocess.check_output(argv, cwd=cwd, text=True, timeout=300).strip()


def sha(path):
    h = hashlib.sha256()
    with path.open("rb") as stream:
        for data in iter(lambda: stream.read(1024 * 1024), b""):
            h.update(data)
    return h.hexdigest()


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source", type=Path, default=ROOT / "host/.tools/PX4-Autopilot"
    )
    parser.add_argument("--mavsdk-server", type=Path, required=True)
    parser.add_argument("--deps-image", required=True)
    parser.add_argument("--context-name", default="px4-image-context")
    parser.add_argument("--tag", default="localhost/rr-c13-px4:source")
    args = parser.parse_args()
    source = args.source.resolve(strict=True)
    if not source.is_relative_to(ROOT / "host/.tools"):
        raise ValueError("source must stay in project tool directory")
    if command(["git", "rev-parse", "HEAD"], source) != COMMIT or command(
        ["git", "status", "--porcelain", "--untracked-files=all"], source
    ):
        raise ValueError("exact clean stock source required")
    for name, commit in SUBMODULES.items():
        folder = source / name
        if command(["git", "rev-parse", "HEAD"], folder) != commit or command(
            ["git", "status", "--porcelain", "--untracked-files=all"], folder
        ):
            raise ValueError("stock submodule differs: " + name)
    import re

    if not re.fullmatch(r"(?:sha256:|.+@sha256:)[a-f0-9]{64}", args.deps_image):
        raise ValueError("immutable dependency image required")
    if (
        sha(args.mavsdk_server)
        != "7cd0a2995460983e82fe2cf0ef187aba852bb849168ce972a139680f3611c0d8"
    ):
        raise ValueError("MAVSDK server bytes differ")
    if not re.fullmatch(r"px4-image-[a-z0-9-]+", args.context_name):
        raise ValueError("owned context name required")
    context = ROOT / "host/.tools" / args.context_name
    if context.exists():
        raise FileExistsError(
            "use a new project image context after preserving previous build evidence"
        )
    payload = context / "payload"
    metadata = context / "metadata"
    payload.mkdir(parents=True)
    metadata.mkdir()
    build = "build/px4_sitl_default"
    for name in [
        build + "/bin",
        build + "/etc",
        "Tools/simulation/gz/models",
        "Tools/simulation/gz/worlds",
    ]:
        shutil.copytree(source / name, payload / name, symlinks=True)
    for name in [
        build + "/rootfs/gz_env.sh",
        "src/modules/simulation/gz_bridge/server.config",
        "LICENSE",
    ]:
        target = payload / name
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(source / name, target)
    plugins = payload / build / "src/modules/simulation/gz_plugins"
    plugins.mkdir(parents=True)
    for p in (source / build).rglob("*.so"):
        target = payload / p.relative_to(source)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copy2(p, target)
    files = sorted(p for p in payload.rglob("*") if p.is_file() and not p.is_symlink())
    (metadata / "payload.sha256").write_text(
        "".join(sha(p) + "  " + str(p.relative_to(payload)) + "\n" for p in files)
    )
    record = {
        "scope": "source candidate; no released or hardware qualification",
        "px4_commit": COMMIT,
        "submodules": SUBMODULES,
        "build_target": "px4_sitl_default",
        "deps_image": args.deps_image,
        "payload_manifest_sha256": sha(metadata / "payload.sha256"),
    }
    (metadata / "source.json").write_text(json.dumps(record, indent=2) + "\n")
    shutil.copy2(args.mavsdk_server, context / "mavsdk_server")
    shutil.copytree(
        ROOT / "host/workers/px4",
        context / "workers",
        ignore=shutil.ignore_patterns("__pycache__"),
    )
    shutil.copy2(
        ROOT / "host/workers/legacy-finalization/export_retained.py",
        context / "workers/opaque_export.py",
    )
    worker_files = sorted(p for p in (context / "workers").rglob("*") if p.is_file())
    (metadata / "workers.sha256").write_text(
        "".join(
            sha(p) + "  " + str(p.relative_to(context / "workers")) + "\n"
            for p in worker_files
        )
    )
    subprocess.run(
        [
            "podman",
            "build",
            "--format=docker",
            "--build-arg",
            "PX4_DEPS_IMAGE=" + args.deps_image,
            "-f",
            str(ROOT / "docker/px4-sitl.Dockerfile"),
            "-t",
            args.tag,
            str(context),
        ],
        check=True,
        timeout=1800,
    )


if __name__ == "__main__":
    main()
