"""Observe a bounded workload through the pinned Isaac Sim native APIs."""

from __future__ import annotations

import argparse
import hashlib
import json
import logging
import math
import sys
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
    parser.add_argument("--width", type=int, default=640)
    parser.add_argument("--height", type=int, default=480)
    args = parser.parse_args()
    if not 1 <= args.steps <= 10000 or not 0 <= args.render_frames <= 10000:
        parser.error("step and render counts must be bounded")
    if not math.isfinite(args.dt) or not 0 < args.dt <= 1:
        parser.error("dt must be finite and within (0, 1]")
    if not 1 <= args.width <= 4096 or not 1 <= args.height <= 4096:
        parser.error("capture dimensions must be bounded")
    if args.capture_directory and args.render_frames < 1:
        parser.error("capture requires rendered frames")
    args.scene = args.scene.resolve(strict=True)
    if not args.scene.is_file():
        parser.error("scene must be a regular file")
    if (
        hashlib.sha256(args.scene.read_bytes()).hexdigest()
        != args.expected_scene_sha256
    ):
        parser.error("scene digest differs from the admitted fixture")
    return args


def main() -> int:
    args = arguments()
    # Isaac application bootstrap precedes imports that require a live Kit app.
    from isaacsim.simulation_app import SimulationApp

    app = SimulationApp({"headless": True})
    stage = None
    render_product = None
    annotator = None
    exit_code = 1
    try:
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
        begin = float(SimulationManager.get_simulation_time())
        SimulationManager.step(steps=args.steps, update_fabric=True)
        end = float(SimulationManager.get_simulation_time())
        if not math.isfinite(begin) or not math.isfinite(end) or end <= begin:
            raise RuntimeError("native physics time did not advance")
        capture = None
        if args.capture_directory:
            import omni.replicator.core as rep

            if not stage.GetPrimAtPath("/World/Camera").IsValid():
                raise RuntimeError("native fixture camera is absent")
            render_product = rep.create.render_product(
                "/World/Camera", (args.width, args.height)
            )
            annotator = rep.AnnotatorRegistry.get_annotator("rgb")
            annotator.attach([render_product.path])
        for _ in range(args.render_frames):
            if annotator is not None:
                rep.orchestrator.step(
                    rt_subframes=4,
                    delta_time=0.0,
                    pause_timeline=False,
                    wait_for_render=True,
                )
            else:
                RenderingManager.render()
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
            "native_time_representation": "float seconds; no exact ns claim",
            "requested_render_frames": args.render_frames,
            "native_capture": capture,
            "frame_capture_qualified": False,
            "rtsp_qualified": False,
        }
        # Raw native diagnostics, not a contract or a signed qualification verdict.
        print(json.dumps(facts, allow_nan=False), flush=True)
        exit_code = 0
        return 0
    except Exception as error:
        print(
            json.dumps({"status": "error", "diagnostic": str(error)}),
            file=sys.stderr,
            flush=True,
        )
        LOGGER.exception("Native Isaac workload failed")
        return 1
    finally:
        # A native capture is retained before releasing its renderer resources.
        if annotator is not None and render_product is not None:
            annotator.detach([render_product.path])
            render_product.destroy()
        stage = None
        # Caller retains stdout; a closure failure remains a nonzero process outcome.
        app.close(exit_code=exit_code)


if __name__ == "__main__":
    raise SystemExit(main())
