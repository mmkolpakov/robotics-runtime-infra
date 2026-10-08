"""The only native Webots step writer, with finite measurement and retained capture."""

from __future__ import annotations

import argparse
import math
import signal
import time
from pathlib import Path
from typing import Any

from common import reference, write_json

stopping = False


def stop(_signum: int, _frame: object) -> None:
    global stopping
    stopping = True


def arguments() -> argparse.Namespace:
    p = argparse.ArgumentParser()
    p.add_argument("--output", type=Path, required=True)
    p.add_argument("--owner-id", required=True)
    p.add_argument("--world", type=Path, required=True)
    p.add_argument(
        "--mode", choices=("physics-only", "offscreen-camera"), required=True
    )
    p.add_argument("--step-ms", type=int, default=16)
    p.add_argument("--steps", type=int, default=8)
    p.add_argument("--deadline-seconds", type=float, default=60)
    p.add_argument("--probe-reset", action="store_true")
    p.add_argument("--auto-start", action="store_true")
    return p.parse_args()


def main() -> int:
    args = arguments()
    if not 1 <= args.steps <= 64 or not 0 < args.deadline_seconds <= 300:
        raise ValueError("finite controller limits are invalid")
    for signum in (signal.SIGTERM, signal.SIGINT):
        signal.signal(signum, stop)
    from controller import Supervisor

    robot = Supervisor()
    world = robot.getFromDef("RR_WORLD_INFO")
    body = robot.getFromDef("RR_FALLING_BODY")
    self_node = robot.getSelf()
    basic = robot.getBasicTimeStep()
    camera = robot.getDevice("native_camera")
    report: dict[str, Any] = {
        "owner_id": args.owner_id,
        "status": "error",
        "samples": [],
        "time": {
            "authority": "Webots Supervisor.getTime",
            "native_unit": "seconds",
            "representation": "float64",
            "epoch": args.owner_id + ":initial",
        },
        "camera": {
            "enabled": args.mode == "offscreen-camera",
            "timestamp_origin": "controller Supervisor.getTime observation after step; no camera timestamp API",
        },
        "reset": {"requested": False, "observed": False},
    }
    status = 1
    try:
        if (
            not basic.is_integer()
            or basic <= 0
            or args.step_ms <= 0
            or args.step_ms % int(basic)
        ):
            raise ValueError(
                "step milliseconds must be positive multiples of native basicTimeStep"
            )
        if Path(robot.getWorldPath()).resolve() != args.world.resolve():
            raise ValueError("observed native world path differs")
        if (
            robot.getName() != "rr-native-probe"
            or robot.getModel() != "robotics-runtime-webots-native-v1"
        ):
            raise ValueError("observed native robot identity differs")
        if world is None or body is None:
            raise ValueError("required native scene nodes are absent")
        native_world = {
            "path": robot.getWorldPath(),
            "source_ref": reference(args.output / "inputs/native.wbt"),
            "title": world.getField("title").getSFString(),
            "random_seed": world.getField("randomSeed").getSFInt32(),
            "optimal_thread_count": world.getField("optimalThreadCount").getSFInt32(),
            "coordinate_system": world.getField("coordinateSystem").getSFString(),
            "basic_time_step_ms": basic,
        }
        if (
            native_world["random_seed"] != 1
            or native_world["optimal_thread_count"] != 1
        ):
            raise ValueError("native deterministic settings differ")
        synchronization = self_node.getBaseNodeField("synchronization").getSFBool()
        if not synchronization:
            raise ValueError("native robot synchronization must be TRUE")
        if args.mode == "offscreen-camera":
            camera.enable(args.step_ms)
        else:
            camera.disable()
        initial = {
            "time_seconds": robot.getTime(),
            "body_position_m": body.getPosition(),
        }
        report["world"] = native_world
        report["robot"] = {
            "name": robot.getName(),
            "model": robot.getModel(),
            "node_id": self_node.getId(),
            "synchronization": bool(synchronization),
            "synchronization_native_value": synchronization,
        }
        report["initial_state"] = initial
        report["camera"]["sampling_period_ms"] = camera.getSamplingPeriod()
        write_json(
            args.output / "ready.json",
            {
                "owner_id": args.owner_id,
                "native_world": native_world,
                "robot": report["robot"],
                "initial_state": initial,
                "camera": report["camera"],
                "ready": True,
                "step_writer": "single external native Python Supervisor",
            },
        )
        deadline = time.monotonic() + args.deadline_seconds
        while not args.auto_start and not (args.output / "measure").exists():
            if stopping or (args.output / "cancel").exists():
                raise InterruptedError("measurement canceled before opening")
            if time.monotonic() >= deadline:
                raise TimeoutError("measurement admission deadline exceeded")
            time.sleep(0.01)
        samples: list[dict[str, object]] = []
        for _ in range(args.steps):
            if stopping or (args.output / "cancel").exists():
                raise InterruptedError("native measurement canceled")
            if time.monotonic() >= deadline:
                raise TimeoutError("native measurement deadline exceeded")
            before = robot.getTime()
            result = robot.step(args.step_ms)
            after = robot.getTime()
            samples.append(
                {
                    "request_ms": args.step_ms,
                    "result": result,
                    "before_seconds": before,
                    "after_seconds": after,
                    "body_position_m": body.getPosition(),
                }
            )
            report["samples"] = samples
            if result == -1:
                raise InterruptedError("native simulation terminated during step")
            if not math.isfinite(after) or after <= before:
                raise ValueError("native simulation did not advance")
        report["last_native_state"] = {
            "time_seconds": robot.getTime(),
            "body_position_m": body.getPosition(),
            "epoch": args.owner_id + ":initial",
        }
        if args.mode == "offscreen-camera":
            image = camera.getImage()
            if image is None:
                raise ValueError("enabled native camera has no image")
            pixels = bytes(image)
            if len(pixels) != camera.getWidth() * camera.getHeight() * 4:
                raise ValueError("native BGRA size differs")
            bgra = args.output / "camera.bgra"
            bgra.write_bytes(pixels)
            png = args.output / "camera.png"
            result = camera.saveImage(str(png), 100)
            if result != 0:
                raise ValueError("native Camera.saveImage failed")
            report["camera"].update(
                width=camera.getWidth(),
                height=camera.getHeight(),
                format="BGRA",
                controller_observed_time_seconds=robot.getTime(),
                save_image_result=result,
                bgra_ref=reference(bgra),
                png_ref=reference(png),
            )
        write_json(args.output / "last-native-state.json", report["last_native_state"])
        report["last_native_state_ref"] = reference(
            args.output / "last-native-state.json"
        )
        write_json(args.output / "measurement.json", report)
        if args.probe_reset:
            previous_time = robot.getTime()
            report["reset"] = {
                "requested": True,
                "api": "Supervisor.simulationReset",
                "before_seconds": previous_time,
                "observed": False,
            }
            write_json(args.output / "pre-reset.json", report)
            robot.simulationReset()
            response = robot.step(int(basic))
            report["reset"].update(
                step_result=response,
                after_seconds=robot.getTime(),
                observed=robot.getTime() < previous_time,
                epoch=args.owner_id + ":reset",
            )
            if response == -1 or not report["reset"]["observed"]:
                raise ValueError("native reset effect requires a new controller epoch")
        report["status"] = "completed"
        status = 0
    except (OSError, RuntimeError, TypeError, ValueError, AttributeError) as error:
        report["diagnostic"] = f"{type(error).__name__}: {error}"
        report["status"] = (
            "canceled" if isinstance(error, InterruptedError) else "error"
        )
        try:
            report["last_native_state"] = {
                "time_seconds": robot.getTime(),
                "body_position_m": body.getPosition(),
            }
        except (
            OSError,
            RuntimeError,
            TypeError,
            ValueError,
            AttributeError,
        ) as snapshot_error:
            report["last_state_diagnostic"] = str(snapshot_error)
    finally:
        if "last_native_state" in report:
            write_json(
                args.output / "last-native-state.json", report["last_native_state"]
            )
            report["last_native_state_ref"] = reference(
                args.output / "last-native-state.json"
            )
        write_json(args.output / "controller-result.json", report)
        robot.simulationQuit(status)
        robot.step(0)
    return status


if __name__ == "__main__":
    raise SystemExit(main())
