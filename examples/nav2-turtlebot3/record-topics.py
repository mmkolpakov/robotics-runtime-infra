"""Record the external Nav2 topics with the public rosbag2 Recorder API."""

from __future__ import annotations

import argparse
import hashlib
import json
import math
import os
import re
import signal
import time
import uuid
from pathlib import Path

TOPICS = {
    "/odom": "nav_msgs/msg/Odometry",
    "/tf": "tf2_msgs/msg/TFMessage",
    "/tf_static": "tf2_msgs/msg/TFMessage",
    "/clock": "rosgraph_msgs/msg/Clock",
    "/amcl_pose": "geometry_msgs/msg/PoseWithCovarianceStamped",
    "/navigate_to_pose/_action/feedback": "nav2_msgs/action/NavigateToPose_FeedbackMessage",
    "/navigate_to_pose/_action/status": "action_msgs/msg/GoalStatusArray",
}


def write_json(path: Path, document: dict) -> None:
    temporary = path.with_name("." + path.name + "." + uuid.uuid4().hex)
    with temporary.open("x", encoding="utf-8") as stream:
        json.dump(document, stream, sort_keys=True, allow_nan=False)
        stream.write("\n")
        stream.flush()
        os.fsync(stream.fileno())
    temporary.replace(path)


def stop_request(path: Path, run_id: str, domain_id: str) -> bool:
    if not path.exists():
        return False
    if path.is_symlink() or not path.is_file() or path.stat().st_size > 4096:
        raise ValueError("stop request is not a bounded regular file")
    document = json.loads(path.read_bytes())
    if document != {"run_id": run_id, "domain_id": domain_id}:
        raise ValueError("stop request belongs to another run or domain")
    return True


def arguments():
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--facts-dir", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--domain-id", required=True)
    parser.add_argument("--startup-timeout-sec", type=float, default=20.0)
    parser.add_argument("--max-lifetime-sec", type=float, default=180.0)
    parser.add_argument("--close-timeout-sec", type=float, default=20.0)
    parser.add_argument("--max-recording-bytes", type=int, default=64 * 1024 * 1024)
    args = parser.parse_args()
    for name in ["run_id", "domain_id"]:
        if not re.fullmatch(r"[A-Za-z0-9_.:-]{1,128}", getattr(args, name)):
            parser.error("run and domain identifiers must be bounded")
    if not all(
        math.isfinite(value) and value > 0
        for value in [
            args.startup_timeout_sec,
            args.max_lifetime_sec,
            args.close_timeout_sec,
        ]
    ):
        parser.error("timeouts must be finite and positive")
    if (
        not args.startup_timeout_sec <= args.max_lifetime_sec <= 300
        or args.close_timeout_sec > 30
    ):
        parser.error(
            "recording lifetime must be at most 300 seconds and close budget at most 30"
        )
    if not 0 < args.max_recording_bytes <= 256 * 1024 * 1024:
        parser.error("recording size must be in (0,256 MiB]")
    args.output = args.output.resolve(strict=False)
    args.facts_dir = args.facts_dir.resolve(strict=False)
    if (
        args.output.exists()
        or args.output.is_symlink()
        or args.facts_dir.exists()
        or args.facts_dir.is_symlink()
    ):
        parser.error("recording and facts paths must be fresh")
    if (
        args.output == args.facts_dir
        or args.output in args.facts_dir.parents
        or args.facts_dir in args.output.parents
    ):
        parser.error("recording and facts directories must be independent")
    return args


def before_deadline(deadline: float, phase: str) -> None:
    if time.monotonic() >= deadline:
        raise TimeoutError(phase + " exceeded its finite deadline")


def artifact_file(path: Path, root: Path, deadline: float) -> dict:
    before_deadline(deadline, "artifact capture")
    if (
        path.is_symlink()
        or not path.is_file()
        or not path.resolve().is_relative_to(root)
    ):
        raise ValueError("native bag artifact is not a confined regular file")
    digest = hashlib.sha256()
    with path.open("rb") as stream:
        original = os.fstat(stream.fileno())
        while chunk := stream.read(1024 * 1024):
            digest.update(chunk)
            before_deadline(deadline, "artifact capture")
        after = os.fstat(stream.fileno())
    current = path.stat()

    def identity(value):
        return (
            value.st_dev,
            value.st_ino,
            value.st_size,
            value.st_mtime_ns,
            value.st_ctime_ns,
        )

    if identity(original) != identity(after) or identity(after) != identity(current):
        raise ValueError("native bag artifact changed during capture")
    before_deadline(deadline, "artifact capture")
    return {
        "path": str(path.relative_to(root)),
        "size_bytes": after.st_size,
        "sha256": digest.hexdigest(),
    }


def main() -> int:
    args = arguments()
    args.facts_dir.mkdir(mode=0o700, parents=True, exist_ok=False)
    source_sha = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
    node_name = "nav2_recorder_" + hashlib.sha256(args.run_id.encode()).hexdigest()[:16]
    started = time.monotonic()
    state = {
        "run_id": args.run_id,
        "domain_id": args.domain_id,
        "pid": os.getpid(),
        "source_sha256": source_sha,
        "node_name": node_name,
        "topics": TOPICS,
        "capture_status": "incomplete",
        "closure_confirmed": False,
        "ros_domain_id": os.environ.get("ROS_DOMAIN_ID"),
        "checked_rosbag2_api_version": "0.26.11",
        "storage_preset_profile": "zstd_fast",
        "max_recording_bytes": args.max_recording_bytes,
        "max_recording_duration_sec": args.max_lifetime_sec,
        "service_responses_recorded": False,
        "argv": list(os.sys.argv),
    }
    write_json(args.facts_dir / "capture-state.json", state)
    requested_signal = []

    def receive_signal(signum, _frame):
        requested_signal.append(int(signum))

    signal.signal(signal.SIGINT, receive_signal)
    signal.signal(signal.SIGTERM, receive_signal)

    recorder = None
    observer = None
    ros_initialized = False
    failed = False
    try:
        import rclpy
        import rosbag2_py

        rclpy.init(args=[])
        ros_initialized = True
        observer = rclpy.create_node(
            "nav2_record_watch_" + node_name.removeprefix("nav2_recorder_")
        )
        storage = rosbag2_py.StorageOptions(
            uri=str(args.output),
            storage_id="mcap",
            storage_preset_profile="zstd_fast",
            max_cache_size=0,
        )
        options = rosbag2_py.RecordOptions()
        options.topics = list(TOPICS)
        options.include_hidden_topics = True
        options.disable_keyboard_controls = True
        options.is_discovery_disabled = False
        options.rmw_serialization_format = "cdr"
        recorder = rosbag2_py.Recorder(storage, options, "info", node_name)
        recorder.start_spin()
        recorder.record()
        startup_deadline = min(
            started + args.max_lifetime_sec, started + args.startup_timeout_sec
        )
        while True:
            if requested_signal:
                raise RuntimeError("recording canceled before readiness")
            if time.monotonic() >= startup_deadline:
                raise TimeoutError("native recorder subscriptions were not ready")
            try:
                subscriptions = dict(
                    observer.get_subscriber_names_and_types_by_node(node_name, "/")
                )
            except Exception:  # noqa: BLE001 - Unknown SDK graph errors keep readiness incomplete.
                subscriptions = {}
            before_deadline(startup_deadline, "recorder readiness")
            if all(
                expected_type in subscriptions.get(topic, [])
                for topic, expected_type in TOPICS.items()
            ):
                state["subscriptions"] = subscriptions
                state["ready_monotonic_ns"] = time.monotonic_ns()
                write_json(args.facts_dir / "ready.json", state)
                break
            rclpy.spin_once(observer, timeout_sec=0.1)
        lifetime_deadline = started + args.max_lifetime_sec
        while True:
            before_deadline(lifetime_deadline, "recording lifetime")
            stopped = bool(requested_signal) or stop_request(
                args.facts_dir / "stop.json", args.run_id, args.domain_id
            )
            before_deadline(lifetime_deadline, "recording lifetime")
            if stopped:
                break
            rclpy.spin_once(observer, timeout_sec=0.1)
        state["stop_reason"] = (
            "signal" if requested_signal else "run-bound-stop-request"
        )
        state["received_signals"] = requested_signal
    except Exception as error:  # noqa: BLE001 - SDK failure must retain diagnostics and enter teardown.
        failed = True
        state["error"] = {"type": type(error).__name__, "message": str(error)}
    finally:
        # Native stop flushes/closes the writer before stopping its executor.
        # A native hang is bounded by the owning external process/container deadline.
        close_deadline = time.monotonic() + args.close_timeout_sec
        state["closing_monotonic_ns"] = time.monotonic_ns()
        try:
            write_json(args.facts_dir / "capture-state.json", state)
        except OSError as error:
            failed = True
            state["state_write_error"] = str(error)
        try:
            if recorder is not None:
                recorder.stop()
                recorder.stop_spin()
                before_deadline(close_deadline, "native recorder close")
                import rosbag2_py

                metadata = rosbag2_py.Info().read_metadata(str(args.output), "mcap")
                before_deadline(close_deadline, "native metadata read")
                metadata_ref = artifact_file(
                    args.output / "metadata.yaml", args.output, close_deadline
                )
                members = []
                for name in metadata.relative_file_paths:
                    relative = Path(name)
                    if relative.is_absolute() or ".." in relative.parts:
                        raise ValueError("native bag member path is not confined")
                    path = args.output / relative
                    members.append(artifact_file(path, args.output, close_deadline))
                state["bag"] = {
                    "message_count": int(metadata.message_count),
                    "metadata": metadata_ref,
                    "members": members,
                    "topics": [
                        {
                            "name": item.topic_metadata.name,
                            "type": item.topic_metadata.type,
                            "message_count": int(item.message_count),
                        }
                        for item in metadata.topics_with_message_count
                    ],
                }
                if not members or int(metadata.message_count) <= 0:
                    raise ValueError("native bag has no retained messages")
                recording_size = sum(member["size_bytes"] for member in members)
                duration_ns = metadata.duration.nanoseconds
                duration_sec = duration_ns / 1e9
                state["bag"]["size_bytes"] = recording_size
                state["bag"]["duration_sec"] = duration_sec
                if recording_size > args.max_recording_bytes:
                    raise ValueError("native bag exceeds declared recording size")
                if not 0 <= duration_ns <= int(args.max_lifetime_sec * 1e9):
                    raise ValueError("native bag exceeds declared recording duration")
                state["closure_confirmed"] = True
        except Exception as error:  # noqa: BLE001 - Unknown native close errors must refuse complete capture.
            failed = True
            state["close_error"] = {"type": type(error).__name__, "message": str(error)}
        try:
            if observer is not None:
                observer.destroy_node()
            if ros_initialized:
                rclpy.shutdown()
            before_deadline(close_deadline, "recorder and ROS cleanup")
        except Exception as error:  # noqa: BLE001 - Unknown ROS teardown errors must retain incomplete state.
            failed = True
            state["ros_cleanup_error"] = {
                "type": type(error).__name__,
                "message": str(error),
            }
        state["finished_monotonic_ns"] = time.monotonic_ns()
        state["capture_status"] = "incomplete" if failed else "complete"
        write_json(args.facts_dir / "capture-state.json", state)
    return 1 if failed else 0


if __name__ == "__main__":
    raise SystemExit(main())
