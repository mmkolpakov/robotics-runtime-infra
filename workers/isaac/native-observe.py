"""Observe a bounded workload through the pinned Isaac Sim native APIs."""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import math
import os
import re
import uuid
import sys
import time
from pathlib import Path

LOGGER = logging.getLogger(__name__)


def arguments() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--scene", type=Path, required=True)
    parser.add_argument("--expected-scene-sha256", required=True)
    parser.add_argument("--steps", type=int, default=60)
    parser.add_argument("--dt", type=float, default=1 / 60)
    parser.add_argument("--render-frames", type=int, default=0)
    parser.add_argument("--capture-directory", type=Path)
    parser.add_argument("--rtsp-port", type=int)
    parser.add_argument("--stream-seconds", type=float, default=10)
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    parser.add_argument("--phase-directory", type=Path)
    parser.add_argument("--owner-id")
    parser.add_argument("--phase-token")
    parser.add_argument("--phase-timeout-seconds", type=float, default=120)
    args = parser.parse_args()
    if any((args.phase_directory, args.owner_id, args.phase_token)):
        if not all((args.phase_directory, args.owner_id, args.phase_token)):
            parser.error("phase directory, owner and token must be supplied together")
        if not re.fullmatch(r"[a-zA-Z0-9_.:-]{1,128}", args.owner_id):
            parser.error("invalid episode owner")
        if not re.fullmatch(r"[a-f0-9-]{36}", args.phase_token):
            parser.error("invalid private phase token")
        if (
            not math.isfinite(args.phase_timeout_seconds)
            or not 1 <= args.phase_timeout_seconds <= 300
        ):
            parser.error("private phase waits must be bounded")
        args.phase_directory = args.phase_directory.resolve(strict=True)
        if not args.phase_directory.is_dir():
            parser.error("phase directory must already exist")
        for name in (
            "ready.json",
            "paused-state.json",
            "episode-result.json",
            "start.json",
            "release.json",
            "cancel.json",
        ):
            if (args.phase_directory / name).exists():
                parser.error("private episode output/marker already exists")
        if args.render_frames and not args.capture_directory:
            args.capture_directory = args.phase_directory / "capture"
    if not 1 <= args.steps <= 10000 or not 0 <= args.render_frames <= 10000:
        parser.error("step and render counts must be bounded")
    if not math.isfinite(args.dt) or not 0 < args.dt <= 1:
        parser.error("dt must be finite and within (0, 1]")
    if not 1 <= args.width <= 4096 or not 1 <= args.height <= 4096:
        parser.error("capture dimensions must be bounded")
    if args.capture_directory and args.render_frames < 1:
        parser.error("capture requires rendered frames")
    if args.rtsp_port is not None:
        if not 1024 <= args.rtsp_port <= 65535 or args.render_frames < 1:
            parser.error("RTSP requires an unprivileged port and rendered frames")
        if not math.isfinite(args.stream_seconds) or not 0 < args.stream_seconds <= 60:
            parser.error("RTSP duration must be finite and within (0, 60]")
    args.scene = args.scene.resolve(strict=True)
    if not args.scene.is_file():
        parser.error("scene must be a regular file")
    if (
        hashlib.sha256(args.scene.read_bytes()).hexdigest()
        != args.expected_scene_sha256
    ):
        parser.error("scene digest differs from the admitted fixture")
    return args


def phase_write(args: argparse.Namespace, name: str, facts: dict) -> None:
    """Private phase facts; no simulator command protocol or contract verdict."""
    if args.phase_directory is None:
        return
    output = args.phase_directory / name
    temporary = args.phase_directory / ("." + name + "-" + str(uuid.uuid4()))
    payload = {"owner_id": args.owner_id, "phase_token": args.phase_token, **facts}
    try:
        with temporary.open("x", encoding="utf-8") as stream:
            stream.write(json.dumps(payload, allow_nan=False))
            stream.flush()
            os.fsync(stream.fileno())
        temporary.replace(output)
    finally:
        temporary.unlink(missing_ok=True)


def phase_marker(args: argparse.Namespace, action: str) -> bool:
    path = args.phase_directory / (action + ".json")
    if not path.exists():
        return False
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 4096:
        raise RuntimeError("private phase marker is not a bounded regular file")
    facts = json.loads(path.read_text(encoding="utf-8"))
    if facts != {
        "owner_id": args.owner_id,
        "phase_token": args.phase_token,
        "action": action,
    }:
        raise RuntimeError("private phase marker belongs to another episode")
    return True


def wait_paused_phase(args, app, timeline, simulation, action: str, phase: str) -> None:
    if args.phase_directory is None:
        return
    deadline = time.monotonic() + args.phase_timeout_seconds
    baseline = float(simulation.get_simulation_time())
    observation = 0
    while True:
        if not app.is_running():
            raise RuntimeError("native application closed during its private phase")
        app.update()
        current = float(simulation.get_simulation_time())
        if (
            timeline.is_playing()
            or not math.isfinite(current)
            or not math.isclose(current, baseline, abs_tol=1e-9)
        ):
            raise RuntimeError("native timeline advanced during its PAUSED phase")
        observation += 1
        phase_write(
            args,
            "paused-state.json",
            {
                "phase": phase,
                "observation": observation,
                "application_running": app.is_running(),
                "timeline_playing": timeline.is_playing(),
                "simulation_time_seconds": current,
            },
        )
        if phase_marker(args, "cancel"):
            raise RuntimeError("private episode cancelled")
        if phase_marker(args, action):
            return
        if action == "start" and phase_marker(args, "release"):
            raise RuntimeError("private episode released before measurement")
        if time.monotonic() >= deadline:
            raise TimeoutError("private native phase deadline exceeded")
        time.sleep(0.025)


def main() -> int:
    args = arguments()
    # Isaac application bootstrap precedes imports that require a live Kit app.
    from isaacsim.simulation_app import SimulationApp

    app = SimulationApp({"headless": True})
    stage = None
    render_product = None
    annotator = None
    rtsp_writer = None
    exit_code = 1
    try:
        from isaacsim.core.experimental.prims import RigidPrim
        from isaacsim.core.experimental.utils import stage as stage_utils
        from isaacsim.core.rendering_manager import RenderingManager
        from isaacsim.core.simulation_manager import SimulationManager
        from isaacsim.core.version import get_version

        observed_version = get_version()[0]
        if observed_version != "6.1.0":
            raise RuntimeError(f"Isaac 6.1.0 required, observed {observed_version!r}")

        loaded, stage = stage_utils.open_stage(str(args.scene))
        if not loaded or stage is None:
            raise RuntimeError("native USD stage loading failed")
        SimulationManager.setup_simulation(dt=args.dt, device="cuda:0")
        SimulationManager.initialize_physics()
        body = RigidPrim(paths="/World/Body")
        body_begin = body.get_world_poses()[0].numpy()[0].tolist()
        begin = float(SimulationManager.get_simulation_time())
        if args.phase_directory is not None:
            import omni.timeline

            timeline = omni.timeline.get_timeline_interface()
            timeline.pause()
            app.update()
            current = float(SimulationManager.get_simulation_time())
            if (
                not app.is_running()
                or timeline.is_playing()
                or not math.isclose(current, begin, abs_tol=1e-9)
            ):
                raise RuntimeError(
                    "native world did not enter its live PAUSED ready phase"
                )
            body_begin = body.get_world_poses()[0].numpy()[0].tolist()
            phase_write(
                args,
                "ready.json",
                {
                    "phase": "ready",
                    "runtime_version": observed_version,
                    "scene_sha256": args.expected_scene_sha256,
                    "body_prim": "/World/Body",
                    "body_position": body_begin,
                    "scene_default_prim": stage.GetDefaultPrim().GetPath().pathString,
                    "bootstrap_sha256": hashlib.sha256(
                        Path(__file__).read_bytes()
                    ).hexdigest(),
                    "physics_device": str(SimulationManager.get_device()),
                    "simulation_time_seconds": current,
                    "application_running": app.is_running(),
                    "timeline_playing": timeline.is_playing(),
                },
            )
            wait_paused_phase(args, app, timeline, SimulationManager, "start", "ready")

        episode_deadline = time.monotonic() + args.phase_timeout_seconds

        def check_episode_cancel():
            if args.phase_directory is not None:
                if phase_marker(args, "cancel"):
                    raise RuntimeError("private episode cancelled")
                if time.monotonic() >= episode_deadline:
                    raise TimeoutError("private native episode deadline exceeded")

        def keep_stepping(_step, _steps):
            check_episode_cancel()
            return None

        SimulationManager.step(
            steps=args.steps, callback=keep_stepping, update_fabric=True
        )
        if args.phase_directory is not None and phase_marker(args, "cancel"):
            raise RuntimeError("private episode cancelled during native stepping")
        end = float(SimulationManager.get_simulation_time())
        body_end = body.get_world_poses()[0].numpy()[0].tolist()
        if not math.isfinite(begin) or not math.isfinite(end) or end <= begin:
            raise RuntimeError("native physics time did not advance")
        capture = None
        if args.capture_directory or args.rtsp_port is not None:
            import omni.replicator.core as rep

            if not stage.GetPrimAtPath("/World/Camera").IsValid():
                raise RuntimeError("native fixture camera is absent")
            render_product = rep.create.render_product(
                "/World/Camera", (args.width, args.height)
            )
            if args.capture_directory:
                annotator = rep.AnnotatorRegistry.get_annotator("rgb")
                annotator.attach([render_product.path])
            if args.rtsp_port is not None:
                import omni.kit.app

                manager = omni.kit.app.get_app().get_extension_manager()
                manager.set_extension_enabled_immediate("isaacsim.core.nodes", True)
                manager.set_extension_enabled_immediate("isaacsim.streaming.rtsp", True)
                from omni.kit.livestream.core import Server

                # The writer logs and suppresses server failures; require its native factory.
                native_server = Server("rtsp")
                native_server.close()
                from isaacsim.streaming.rtsp import RTSPStreamWriter
                from isaacsim.streaming.rtsp.impl.render_var_utils import (
                    ensure_render_var_on_product,
                )

                valid, _ = ensure_render_var_on_product(
                    stage, render_product.path, "LdrColor", "h264"
                )
                if not valid:
                    raise RuntimeError("native H.264 render variable is unavailable")
                rtsp_writer = RTSPStreamWriter(
                    port=args.rtsp_port,
                    mountPath="/stream",
                    encoding="h264",
                    width=args.width,
                    height=args.height,
                )
                rtsp_writer.attach([render_product])
        for _ in range(args.render_frames):
            check_episode_cancel()
            if render_product is not None:
                rep.orchestrator.step(
                    rt_subframes=4,
                    delta_time=0.0,
                    pause_timeline=False,
                    wait_for_render=True,
                )
            else:
                RenderingManager.render()
        if rtsp_writer is not None:
            deadline = time.monotonic() + args.stream_seconds
            while time.monotonic() < deadline:
                check_episode_cancel()
                rep.orchestrator.step(
                    rt_subframes=1,
                    delta_time=0.0,
                    pause_timeline=False,
                    wait_for_render=True,
                )
        if annotator is not None:
            rgba = annotator.get_data()
            if rgba.shape != (args.height, args.width, 4):
                raise RuntimeError(f"native RGBA dimensions differ: {rgba.shape}")
            output = args.capture_directory.resolve()
            output.mkdir(parents=True, exist_ok=False)
            pixels = output / "camera.rgba"
            pixels.write_bytes(rgba.tobytes())
            # Use the SDK's installed image library; the host carries no frame bytes.
            from PIL import Image

            image = output / "camera.png"
            Image.fromarray(rgba).save(image)
            capture = {
                "camera": "/World/Camera",
                "width": args.width,
                "height": args.height,
                "format": "RGBA",
                "rgba_sha256": hashlib.sha256(pixels.read_bytes()).hexdigest(),
                "png_sha256": hashlib.sha256(image.read_bytes()).hexdigest(),
                "size_bytes": pixels.stat().st_size,
                "native_capture_api": "Replicator rgb annotator",
                "controller_observed_physics_seconds": float(
                    SimulationManager.get_simulation_time()
                ),
            }
        import omni.timeline

        timeline = omni.timeline.get_timeline_interface()
        timeline.pause()
        app.update()
        paused_time = float(SimulationManager.get_simulation_time())
        if timeline.is_playing() or not math.isclose(paused_time, end, abs_tol=1e-9):
            raise RuntimeError("native timeline did not remain quiescent after capture")
        facts = {
            "runtime": "Isaac Sim",
            "runtime_version": observed_version,
            "expected_source_commit": "7c206f75bdadd9e05fc457f19863ca4c3f0cb693",
            "scene_sha256": hashlib.sha256(args.scene.read_bytes()).hexdigest(),
            "scene_default_prim": stage.GetDefaultPrim().GetPath().pathString,
            "requested_physics_steps": args.steps,
            "requested_dt_seconds": args.dt,
            "physics_begin_seconds": begin,
            "physics_end_seconds": end,
            "physics_advance_seconds": end - begin,
            "body": {
                "prim": "/World/Body",
                "world_frame": "Z up; metres",
                "begin_position": body_begin,
                "end_position": body_end,
                "native_api": "experimental RigidPrim.get_world_poses",
            },
            "paused_time_seconds": paused_time,
            "timeline_playing_after_pause": timeline.is_playing(),
            "native_time_representation": "float seconds; no exact ns claim",
            "requested_render_frames": args.render_frames,
            "native_capture": capture,
            "rtsp_requested": args.rtsp_port is not None,
            "rtsp_port": args.rtsp_port,
            "stream_wall_seconds_requested": args.stream_seconds
            if rtsp_writer
            else None,
            "frame_capture_qualified": False,
            "rtsp_qualified": False,
        }
        # Raw native diagnostics, not a contract or a signed qualification verdict.
        print(json.dumps(facts, allow_nan=False), flush=True)
        if args.phase_directory is not None:
            phase_write(
                args,
                "episode-result.json",
                {
                    **facts,
                    "status": "completed",
                    "application_running": app.is_running(),
                },
            )
            wait_paused_phase(
                args, app, timeline, SimulationManager, "release", "measured"
            )
        exit_code = 0
        return 0
    except Exception as error:
        phase_write(
            args, "worker-error.json", {"status": "error", "diagnostic": str(error)}
        )
        print(
            json.dumps({"status": "error", "diagnostic": str(error)}),
            file=sys.stderr,
            flush=True,
        )
        LOGGER.exception("Native Isaac workload failed")
        return 1
    finally:
        # A native capture is retained before releasing its renderer resources.
        try:
            try:
                if annotator is not None and render_product is not None:
                    annotator.detach([render_product.path])
            finally:
                try:
                    if rtsp_writer is not None:
                        rtsp_writer.detach()
                finally:
                    if render_product is not None:
                        render_product.destroy()
        except Exception:
            exit_code = 1
            LOGGER.exception("Native renderer resource cleanup failed")
        finally:
            stage = None
            # SDK fast shutdown must not hide a workload or cleanup exception.
            app.close(exit_code=exit_code)


if __name__ == "__main__":
    raise SystemExit(main())
