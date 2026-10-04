"""Native source qualification of the pinned worker; no mocks or physical GPU claim."""

from __future__ import annotations

import argparse
import json
import subprocess
import time
import uuid
from pathlib import Path


def main() -> None:
    p = argparse.ArgumentParser()
    p.add_argument("--image", required=True)
    p.add_argument("--output", type=Path, required=True)
    args = p.parse_args()
    args.output.mkdir(parents=True, exist_ok=True)
    observations = []
    for mode in (
        "physics-only",
        "offscreen-camera",
        "cancel",
        "wrong-step",
        "wrong-digest",
        "wrong-mode",
    ):
        directory = args.output / mode
        directory.mkdir(exist_ok=False)
        owner = "c14-" + uuid.uuid4().hex
        name = "rr-webots-qual-" + uuid.uuid4().hex[:12]
        command = [
            "podman",
            "run",
            "--rm",
            "--name",
            name,
            "--userns=keep-id:uid=10001,gid=10001",
            "--network",
            "none",
            "--read-only",
            "--tmpfs",
            "/tmp:rw,mode=1777,size=512m",
            "--shm-size=256m",
            "--mount",
            f"type=bind,source={directory.resolve()},target=/run/robotics/output",
            args.image,
            "run",
            "--output",
            "/run/robotics/output",
            "--owner-id",
            owner,
            "--deadline-seconds",
            "40",
        ]
        if mode == "cancel":
            process = subprocess.Popen(
                command, stdout=subprocess.PIPE, stderr=subprocess.PIPE
            )
            try:
                end = time.monotonic() + 30
                while not (directory / "ready.json").exists():
                    if process.poll() is not None or time.monotonic() >= end:
                        raise AssertionError(
                            "native worker did not become ready before cancel"
                        )
                    time.sleep(0.05)
                wrong = subprocess.run(
                    [
                        "podman",
                        "exec",
                        name,
                        "python3",
                        "/opt/robotics/webots/launcher.py",
                        "cancel",
                        "--output",
                        "/run/robotics/output",
                        "--owner-id",
                        "foreign-owner",
                    ],
                    capture_output=True,
                    text=True,
                    timeout=10,
                    check=False,
                )
                assert wrong.returncode != 0 and not (directory / "cancel").exists()
                subprocess.run(
                    [
                        "podman",
                        "exec",
                        name,
                        "python3",
                        "/opt/robotics/webots/launcher.py",
                        "cancel",
                        "--output",
                        "/run/robotics/output",
                        "--owner-id",
                        owner,
                    ],
                    capture_output=True,
                    check=True,
                    timeout=10,
                )
                stdout, stderr = process.communicate(timeout=10)
                code = process.returncode
            finally:
                if process.poll() is None:
                    subprocess.run(
                        ["podman", "stop", "--time", "3", name],
                        check=False,
                        capture_output=True,
                    )
                    process.communicate(timeout=10)
        else:
            command += ["--auto-start"]
            if mode in ("physics-only", "offscreen-camera"):
                command += ["--mode", mode, "--probe-reset"]
            elif mode == "wrong-step":
                command += ["--step-ms", "17"]
            elif mode == "wrong-digest":
                command += ["--expected-world-sha256", "0" * 64]
            else:
                command += ["--mode", "rtsp"]
            result = subprocess.run(
                command, capture_output=True, timeout=60, check=False
            )
            code, stdout, stderr = result.returncode, result.stdout, result.stderr
        (directory / "container-stdout.log").write_bytes(stdout)
        (directory / "container-stderr.log").write_bytes(stderr)
        observation = {"case": mode, "exit": code}
        if mode in ("physics-only", "offscreen-camera"):
            assert code == 0, stderr.decode()
            native = json.loads((directory / "controller-result.json").read_bytes())
            worker = json.loads((directory / "worker-result.json").read_bytes())
            assert native["status"] == "completed"
            assert (
                worker["processes_reaped"] and worker["evidence_exported_before_stop"]
            )
            assert native["world"]["random_seed"] == 1
            assert native["world"]["optimal_thread_count"] == 1
            assert native["robot"]["synchronization"]
            assert native["time"]["native_unit"] == "seconds"
            assert native["time"]["representation"] == "float64"
            assert (
                native["last_native_state"]["time_seconds"]
                > native["initial_state"]["time_seconds"]
            )
            assert (
                native["last_native_state"]["body_position_m"][2]
                < native["initial_state"]["body_position_m"][2]
            )
            assert all(
                x["result"] == 0 and x["after_seconds"] > x["before_seconds"]
                for x in native["samples"]
            )
            assert all(
                x["request_ms"] % native["world"]["basic_time_step_ms"] == 0
                for x in native["samples"]
            )
            assert native["reset"]["requested"] and native["reset"]["observed"]
            assert native["reset"]["after_seconds"] < native["reset"]["before_seconds"]
            if mode == "physics-only":
                assert native["camera"]["sampling_period_ms"] == 0
                assert not (directory / "camera.bgra").exists()
            else:
                camera = native["camera"]
                assert camera["sampling_period_ms"] > 0 and camera["format"] == "BGRA"
                image = (directory / "camera.bgra").read_bytes()
                assert len(image) == camera["width"] * camera["height"] * 4
                assert len(set(zip(image[0::4], image[1::4], image[2::4]))) > 1
                assert (
                    (directory / "camera.png")
                    .read_bytes()
                    .startswith(b"\x89PNG\r\n\x1a\n")
                )
                assert "no camera timestamp API" in camera["timestamp_origin"]
            observation.update(
                nativeAdvance=True,
                nativeReset=True,
                sensorCapture=mode == "offscreen-camera",
                exportedBeforeStop=True,
                childrenReaped=True,
            )
        elif mode == "cancel":
            assert code != 0
            native = json.loads((directory / "controller-result.json").read_bytes())
            worker = json.loads((directory / "worker-result.json").read_bytes())
            assert native["status"] == "canceled"
            assert (
                worker["processes_reaped"] and worker["evidence_exported_before_stop"]
            )
            assert (directory / "last-native-state.json").exists()
            assert not native["samples"]
            observation.update(
                foreignOwnerRefused=True,
                noMeasurementPass=True,
                exportedBeforeStop=True,
                childrenReaped=True,
            )
        elif mode == "wrong-step":
            assert code != 0
            native = json.loads((directory / "controller-result.json").read_bytes())
            assert "multiples" in native["diagnostic"]
            assert json.loads((directory / "worker-result.json").read_bytes())[
                "processes_reaped"
            ]
        elif mode == "wrong-digest":
            assert code != 0 and b"bytes differ" in stderr
            assert not (directory / "webots.log").exists()
        else:
            assert code != 0 and b"invalid choice" in stderr
            assert not (directory / "webots.log").exists()
        observations.append(observation)
        print(json.dumps(observation), flush=True)
    (args.output / "source-qualification.json").write_text(
        json.dumps(
            {
                "scope": "native Linux amd64 CPU/Mesa fixture; no hardware/desktop or published consumer qualification",
                "image": args.image,
                "cases": observations,
            },
            indent=2,
        )
        + "\n"
    )


if __name__ == "__main__":
    main()
