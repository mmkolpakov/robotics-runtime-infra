"""Own finite native Webots, controller and Xvfb processes; export before destructive stop."""

from __future__ import annotations

import argparse
import json
import os
import shutil
import signal
import subprocess
import time
from pathlib import Path

from common import reference, write_json

ROOT = Path(__file__).resolve().parent
WEBOTS = Path("/usr/local/webots")
stopping = False


def stop(_signum: int, _frame: object) -> None:
    global stopping
    stopping = True


def parse() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument(
        "operation", choices=("run", "measure", "cancel"), nargs="?", default="run"
    )
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--owner-id", required=True)
    p.add_argument(
        "--mode", choices=("physics-only", "offscreen-camera"), default="physics-only"
    )
    p.add_argument("--steps", type=int, default=8)
    p.add_argument("--step-ms", type=int, default=16)
    p.add_argument("--deadline-seconds", type=float, default=60)
    p.add_argument("--auto-start", action="store_true")
    p.add_argument("--probe-reset", action="store_true")
    p.add_argument("--expected-world-sha256")
    return p.parse_args()


def reap(process: subprocess.Popen[bytes]) -> dict[str, object]:
    if process.poll() is None:
        try:
            os.killpg(process.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        try:
            process.wait(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            process.wait(timeout=2)
    return {
        "pid": process.pid,
        "exit_code": process.returncode,
        "reaped": process.poll() is not None,
    }


def main() -> int:
    args = parse()
    if not args.owner_id or len(args.owner_id) > 128:
        raise ValueError("owner identity is invalid")
    if args.operation != "run":
        ownership = json.loads((args.output / "owner.json").read_bytes())
        if ownership["owner_id"] != args.owner_id:
            raise ValueError("cannot signal another owner")
        write_json(args.output / args.operation, {"owner_id": args.owner_id})
        return 0
    if (
        not args.output.is_absolute()
        or not 1 <= args.steps <= 64
        or not 0 < args.deadline_seconds <= 300
    ):
        raise ValueError("finite worker parameters are invalid")
    if args.output.exists() and list(args.output.iterdir()):
        raise ValueError("worker output must be new and single-writer")
    args.output.mkdir(parents=True, exist_ok=True)
    args.output.chmod(0o2770)
    write_json(args.output / "owner.json", {"owner_id": args.owner_id})
    exported = args.output / "inputs"
    exported.mkdir()
    for name in (
        "worlds/native.wbt",
        "protos/NativeProbe.proto",
        "native_controller.py",
        "common.py",
        "upstream.json",
    ):
        destination = exported / Path(name).name
        shutil.copyfile(ROOT / name, destination)
        destination.chmod(0o444)
    world = ROOT / "worlds/native.wbt"
    digest = reference(world)["sha256"]
    if args.expected_world_sha256 and args.expected_world_sha256 != digest:
        raise ValueError("native world bytes differ from the requested scene digest")
    for signum in (signal.SIGINT, signal.SIGTERM):
        signal.signal(signum, stop)
    environment = dict(os.environ)
    environment.update(
        WEBOTS_HOME=str(WEBOTS),
        DISPLAY=":99",
        USER="robotics",
        USERNAME="robotics",
        LIBGL_ALWAYS_SOFTWARE="1",
        PYTHONUNBUFFERED="1",
    )
    for variable in ("HOME", "XDG_CACHE_HOME", "XDG_RUNTIME_DIR"):
        Path(environment[variable]).mkdir(parents=True, exist_ok=True)
    Path(environment["XDG_RUNTIME_DIR"]).chmod(0o700)
    processes: list[tuple[str, subprocess.Popen[bytes]]] = []
    streams = []
    result: dict[str, object] = {
        "owner_id": args.owner_id,
        "status": "error",
        "platform": "linux/amd64",
        "main_view_rendering": False,
        "sensor_rendering": args.mode == "offscreen-camera",
        "display": "Xvfb :99",
        "renderer_policy": "Mesa software, LIBGL_ALWAYS_SOFTWARE=1",
        "children": [],
        "evidence_exported_before_stop": False,
    }
    deadline = time.monotonic() + args.deadline_seconds
    code = 1
    try:

        def spawn(name: str, command: list[str]) -> subprocess.Popen[bytes]:
            stream = (args.output / (name + ".log")).open("wb")
            streams.append(stream)
            process = subprocess.Popen(
                command,
                env=environment,
                stdout=stream,
                stderr=subprocess.STDOUT,
                start_new_session=True,
            )
            processes.append((name, process))
            return process

        display = spawn(
            "xvfb",
            [
                "Xvfb",
                ":99",
                "-screen",
                "0",
                "640x480x24",
                "-nolisten",
                "tcp",
                "+extension",
                "GLX",
                "+render",
                "-noreset",
            ],
        )
        while not Path("/tmp/.X11-unix/X99").exists():
            if display.poll() is not None or time.monotonic() >= deadline or stopping:
                raise RuntimeError("native Xvfb display did not become ready")
            time.sleep(0.02)
        graphics = subprocess.run(
            ["glxinfo", "-B"],
            env=environment,
            capture_output=True,
            timeout=10,
            check=True,
            text=True,
        )
        (args.output / "renderer.txt").write_text(graphics.stdout + graphics.stderr)
        packages = Path("/usr/local/share/robotics-webots/packages.tsv")
        binaries = Path("/usr/local/share/robotics-webots/binaries.sha256")
        shutil.copyfile(packages, args.output / "packages.tsv")
        shutil.copyfile(binaries, args.output / "binaries.sha256")
        identity = {
            "release": (WEBOTS / "resources/version.txt").read_text().strip(),
            "upstream": json.loads((ROOT / "upstream.json").read_bytes()),
            "packages_ref": reference(args.output / "packages.tsv"),
            "binaries_ref": reference(args.output / "binaries.sha256"),
            "renderer_ref": reference(args.output / "renderer.txt"),
            "uid": os.getuid(),
            "gid": os.getgid(),
        }
        write_json(args.output / "worker-identity.json", identity)
        simulator = spawn(
            "webots",
            [
                str(WEBOTS / "webots"),
                "--batch",
                "--stdout",
                "--stderr",
                "--no-rendering",
                "--mode=fast",
                "--port=1234",
                str(world),
            ],
        )
        command = [
            str(WEBOTS / "webots-controller"),
            "--protocol=ipc",
            "--port=1234",
            "--robot-name=rr-native-probe",
            str(ROOT / "native_controller.py"),
            "--output",
            str(args.output),
            "--owner-id",
            args.owner_id,
            "--world",
            str(world),
            "--mode",
            args.mode,
            "--steps",
            str(args.steps),
            "--step-ms",
            str(args.step_ms),
            "--deadline-seconds",
            str(args.deadline_seconds),
        ]
        if args.auto_start:
            command.append("--auto-start")
        if args.probe_reset:
            command.append("--probe-reset")
        controller = spawn("controller", command)
        while controller.poll() is None:
            if stopping or time.monotonic() >= deadline:
                (args.output / "cancel").write_text(
                    "owner canceled" if stopping else "worker deadline"
                )
                try:
                    os.killpg(controller.pid, signal.SIGTERM)
                except ProcessLookupError:
                    pass
                try:
                    controller.wait(timeout=1)
                except subprocess.TimeoutExpired:
                    pass
                raise InterruptedError("finite worker canceled or deadline exceeded")
            if simulator.poll() is not None:
                raise RuntimeError("native Webots ended before its controller")
            time.sleep(0.02)
        code = controller.returncode
        native = json.loads((args.output / "controller-result.json").read_bytes())
        result["controller_result_ref"] = reference(
            args.output / "controller-result.json"
        )
        result["evidence_exported_before_stop"] = True
        result["status"] = (
            "completed"
            if code == 0 and native["status"] == "completed"
            else native["status"]
        )
        result["requested_mode"] = args.mode
        result["worker_identity_ref"] = reference(args.output / "worker-identity.json")
        # The controller has exported state/capture before requesting native quit.
        try:
            simulator.wait(timeout=2)
        except subprocess.TimeoutExpired:
            pass
    except (OSError, RuntimeError, ValueError, subprocess.SubprocessError) as error:
        result["diagnostic"] = f"{type(error).__name__}: {error}"
        result["status"] = (
            "canceled" if isinstance(error, InterruptedError) else "error"
        )
        if (args.output / "controller-result.json").exists():
            result["controller_result_ref"] = reference(
                args.output / "controller-result.json"
            )
            result["evidence_exported_before_stop"] = True
        write_json(args.output / "failure-before-stop.json", result)
    finally:
        children = []
        for name, process in reversed(processes):
            children.append({"name": name, **reap(process)})
        for stream in streams:
            stream.close()
        result["children"] = children
        result["processes_reaped"] = all(child["reaped"] for child in children)
        result["log_refs"] = [
            reference(args.output / (name + ".log")) for name, _ in processes
        ]
        write_json(args.output / "worker-result.json", result)
    return code if result["status"] == "completed" else 1


if __name__ == "__main__":
    raise SystemExit(main())
