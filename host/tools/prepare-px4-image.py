"""Build a source-only OCI worker from unpatched stock PX4 build outputs."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
import shutil
import subprocess
import tempfile
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


def source_sdk_lock():
    path = ROOT / "host/workers/px4/mavsdk-source-lock.json"
    lock = json.loads(path.read_text())
    if (
        lock["origin"] != "project-source-build"
        or lock["platform"] != "linux/amd64"
        or lock["sdk"]["version"] != "4.2.0"
        or lock["sdk"]["tag"] != "v4.2.0"
        or set(lock["archives"])
        != {"MAVLink", "pymavlink", "libevents", "PicoSHA2", "libmavlike"}
    ):
        raise ValueError("exact source SDK composition required")
    for item in lock["archives"].values():
        if (
            not re.fullmatch(r"[a-f0-9]{40}", item["commit"])
            or not re.fullmatch(r"[a-f0-9]{64}", item["sha256"])
            or type(item["size"]) is not int
            or not 0 < item["size"] <= 50_000_000
            or item["url"]
            != "https://codeload.github.com/"
            + item["repository"]
            + "/tar.gz/"
            + item["commit"]
        ):
            raise ValueError("closed source archive identity required")
    if lock["archives"]["pymavlink"]["commit"] != lock["mavlink_pymavlink_commit"]:
        raise ValueError("MAVLink generator submodule differs")
    return lock, path


def validate_sdk_source(path, lock):
    source = path.resolve()
    if not source.is_relative_to(ROOT / "host/.tools"):
        raise ValueError("SDK source must stay in project tool directory")
    if (
        command(["git", "rev-parse", "HEAD"], source) != lock["sdk"]["commit"]
        or command(["git", "rev-parse", "HEAD^{tree}"], source) != lock["sdk"]["tree"]
        or command(["git", "rev-parse", lock["sdk"]["tag"] + "^{}"], source)
        != lock["sdk"]["commit"]
        or command(["git", "status", "--porcelain", "--untracked-files=all"], source)
    ):
        raise ValueError("exact clean tagged MAVSDK source required")
    return source


def source_archive(item):
    cache = ROOT / "host/.tools/mavsdk-source-cache"
    cache.mkdir(exist_ok=True)
    retained = cache / (item["sha256"] + ".tar.gz")
    if not retained.exists():
        with tempfile.NamedTemporaryFile(
            dir=cache, suffix=".partial", delete=False
        ) as stream:
            pending = Path(stream.name)
        subprocess.run(
            [
                "/usr/bin/timeout",
                "--signal=TERM",
                "--kill-after=15s",
                "330s",
                "/usr/bin/curl",
                "--fail",
                "--location",
                "--retry",
                "3",
                "--max-time",
                "300",
                "--max-filesize",
                str(item["size"]),
                "--proto",
                "=https",
                "--proto-redir",
                "=https",
                "--output",
                str(pending),
                item["url"],
            ],
            check=True,
        )
        if pending.stat().st_size != item["size"] or sha(pending) != item["sha256"]:
            raise ValueError("downloaded source archive differs")
        pending.replace(retained)
    if (
        retained.is_symlink()
        or retained.stat().st_size != item["size"]
        or sha(retained) != item["sha256"]
    ):
        raise ValueError("retained source archive differs")
    return retained


def build_image(args, context, dockerfile, source_lock=None):
    build = [
        "/usr/bin/timeout",
        "--signal=TERM",
        "--kill-after=120s",
        "6600s",
        "podman",
        "build",
        "--force-rm",
        "--skip-unused-stages",
        "--format=docker",
        "--build-arg",
        "PX4_DEPS_IMAGE=" + args.deps_image,
    ]
    if source_lock is not None:
        build += [
            "--platform",
            source_lock["platform"],
            "--build-arg",
            "UBUNTU_SNAPSHOT=" + source_lock["ubuntu_snapshot"],
        ]
    if source_lock is not None:
        for kind, closure in source_lock.get("apt_closure", {}).items():
            build += [
                "--build-arg",
                "APT_"
                + kind.upper()
                + "_CLOSURE_SHA256="
                + closure["inventory_sha256"],
                "--build-arg",
                "APT_"
                + kind.upper()
                + "_DEBS_SHA256="
                + closure["deb_manifest_sha256"],
            ]
    if args.build_target != "worker":
        build += ["--target", args.build_target]
    build += [
        "--iidfile",
        str(context / "image-id.txt"),
        "-f",
        str(dockerfile),
        "-t",
        args.tag,
        str(context),
    ]
    subprocess.run(build, check=True)


def stage_source_sdk(context, source, lock, lock_path):
    metadata = context / "metadata"
    metadata.mkdir(exist_ok=True)
    sdk = context / "sdk/MAVSDK"
    sdk.parent.mkdir()
    command(
        [
            "git",
            "clone",
            "--depth=1",
            "--single-branch",
            "--branch",
            lock["sdk"]["tag"],
            source.as_uri(),
            str(sdk),
        ]
    )
    command(["git", "remote", "set-url", "origin", lock["sdk"]["repository"]], sdk)
    if command(["git", "rev-parse", "HEAD"], sdk) != lock["sdk"]["commit"]:
        raise ValueError("staged SDK source identity differs")
    archives = context / "archives"
    archives.mkdir()
    checksums = []
    for name, item in lock["archives"].items():
        target = archives / (name + ".tar.gz")
        shutil.copy2(source_archive(item), target)
        checksums.append(item["sha256"] + "  archives/" + target.name + "\n")
    (metadata / "sdk-inputs.sha256").write_text("".join(checksums))
    shutil.copy2(lock_path, context / "source-sdk-lock.json")
    shutil.copy2(ROOT / "docker/python/px4-sdk-build.lock", context / "build.lock")
    shutil.copy2(
        ROOT / "docker/apt/use-package-snapshots", context / "use-package-snapshots"
    )
    record = {
        "origin": "project-source-build",
        "scope": "source candidate; execution admission and release trust are separate",
        "sdk": lock["sdk"],
        "platform": lock["platform"],
        "ubuntu_snapshot": lock["ubuntu_snapshot"],
        "source_lock_sha256": sha(lock_path),
        "python_build_lock_sha256": sha(context / "build.lock"),
        "archive_inputs": lock["archives"],
        "factory_inputs": {
            str(path.relative_to(ROOT)): sha(path)
            for path in (
                ROOT / "host/tools/prepare-px4-image.py",
                ROOT / "docker/px4-sitl-native-source.Dockerfile",
                ROOT / "docker/python/px4-sdk-build.in",
                ROOT / "docker/python/px4-sdk-build.lock",
            )
        },
    }
    (metadata / "sdk-source.json").write_text(json.dumps(record, indent=2) + "\n")
    return {
        "package": "mavsdk",
        "version": lock["sdk"]["version"],
        "origin": "project-source-build",
        "source_commit": lock["sdk"]["commit"],
        "source_lock_sha256": sha(lock_path),
        "python": "/opt/px4-native-venv/bin/python",
    }


def require_apt_closure(lock, target):
    if target in ("native-source-inputs", "native-source-runtime-inputs"):
        return
    required = ("build", "runtime") if target == "worker" else ("build",)
    for name in required:
        closure = lock.get("apt_closure", {}).get(name, {})
        if (
            not isinstance(closure.get("packages"), dict)
            or not closure["packages"]
            or not re.fullmatch(r"[a-f0-9]{64}", closure.get("inventory_sha256", ""))
            or not re.fullmatch(r"[a-f0-9]{64}", closure.get("deb_manifest_sha256", ""))
        ):
            raise ValueError(
                "measured closed APT inputs required before compilation: " + name
            )


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument(
        "--source", type=Path, default=ROOT / "host/.tools/PX4-Autopilot"
    )
    parser.add_argument(
        "--controller",
        choices=("legacy", "native-python", "native-python-source"),
        default="legacy",
    )
    parser.add_argument("--mavsdk-server", type=Path)
    parser.add_argument("--deps-image", required=True)
    parser.add_argument("--context-name")
    parser.add_argument("--tag")
    parser.add_argument("--sdk-source", type=Path)
    parser.add_argument(
        "--build-target",
        choices=(
            "worker",
            "native-source-inputs",
            "native-source-runtime-inputs",
            "native-sdk-source",
        ),
        default="worker",
    )
    args = parser.parse_args()
    source_mode = args.controller == "native-python-source"
    native = args.controller != "legacy"
    if not source_mode and (
        args.sdk_source is not None or args.build_target != "worker"
    ):
        parser.error("source SDK inputs require native-python-source")
    if source_mode and args.mavsdk_server is not None:
        parser.error("source C API does not use a MAVSDK server")
    source_lock = None
    if source_mode:
        source_lock, lock_path = source_sdk_lock()
        sdk_source = validate_sdk_source(
            args.sdk_source or ROOT / "host/.tools/MAVSDK-v4.2.0", source_lock
        )
        require_apt_closure(source_lock, args.build_target)

    if native and args.mavsdk_server is not None:
        parser.error("native-python uses the official wheel, not a MAVSDK server")
    if not native and args.mavsdk_server is None:
        parser.error("legacy controller requires --mavsdk-server")
    args.context_name = args.context_name or (
        "px4-image-native-source-context"
        if source_mode
        else "px4-image-native-context"
        if native
        else "px4-image-context"
    )
    args.tag = args.tag or (
        "localhost/rr-px4-native-source:source"
        if source_mode
        else "localhost/rr-px4-native:source"
        if native
        else "localhost/rr-c13-px4:source"
    )
    if source_mode and args.build_target != "worker":
        if not re.fullmatch(r"(?:sha256:|.+@sha256:)[a-f0-9]{64}", args.deps_image):
            raise ValueError("immutable dependency image required")
        if not re.fullmatch(r"px4-image-[a-z0-9-]+", args.context_name):
            raise ValueError("owned context name required")
        context = ROOT / "host/.tools" / args.context_name
        context.mkdir()
        stage_source_sdk(context, sdk_source, source_lock, lock_path)
        build_image(
            args,
            context,
            ROOT / "docker/px4-sitl-native-source.Dockerfile",
            source_lock,
        )
        return
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
    if not re.fullmatch(r"(?:sha256:|.+@sha256:)[a-f0-9]{64}", args.deps_image):
        raise ValueError("immutable dependency image required")
    if not native and (
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
    if native:
        (context / "workers").mkdir()
        for original, name in (
            ("examples/px4-x500/native_worker.py", "native_worker.py"),
            (
                "examples/px4-x500/evaluator/src/px4_x500_evaluator/_px4_listener.py",
                "_px4_listener.py",
            ),
            ("host/workers/px4/probe.py", "probe.py"),
        ):
            shutil.copy2(ROOT / original, context / "workers" / name)
        if source_mode:
            record.update(
                {
                    "controller": "native-python-source",
                    "native_sdk": stage_source_sdk(
                        context, sdk_source, source_lock, lock_path
                    ),
                }
            )
        else:
            lock = context / "native-sdk.lock"
            shutil.copy2(ROOT / "docker/python/px4-native-sdk.lock", lock)
            lock_sha256 = sha(lock)
            (metadata / "native-sdk.sha256").write_text(
                lock_sha256 + "  native-sdk.lock\n"
            )
            record.update(
                {
                    "controller": "native-python",
                    "native_sdk": {
                        "package": "mavsdk",
                        "version": "4.1.0",
                        "lock_sha256": lock_sha256,
                        "python": "/opt/px4-native-venv/bin/python",
                    },
                }
            )
    else:
        shutil.copy2(args.mavsdk_server, context / "mavsdk_server")
        shutil.copytree(
            ROOT / "host/workers/px4",
            context / "workers",
            ignore=shutil.ignore_patterns("__pycache__"),
        )
    (metadata / "source.json").write_text(json.dumps(record, indent=2) + "\n")
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
    if source_mode:
        build_image(
            args,
            context,
            ROOT / "docker/px4-sitl-native-source.Dockerfile",
            source_lock,
        )
    else:
        subprocess.run(
            [
                "podman",
                "build",
                "--format=docker",
                "--build-arg",
                "PX4_DEPS_IMAGE=" + args.deps_image,
                "-f",
                str(
                    ROOT
                    / (
                        "docker/px4-sitl-native.Dockerfile"
                        if native
                        else "docker/px4-sitl.Dockerfile"
                    )
                ),
                "-t",
                args.tag,
                str(context),
            ],
            check=True,
            timeout=1800,
        )


if __name__ == "__main__":
    main()
