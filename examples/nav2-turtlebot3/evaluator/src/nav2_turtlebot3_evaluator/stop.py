"""Validate sampled negative-case motion from retained native odometry."""

from __future__ import annotations

import math
from collections.abc import Mapping

MAX_STOP_SAMPLES = 4096
STOP_WORKLOAD_BYTES = 8 * 1024 * 1024

STOP_POLICY = {
    "max_linear_speed_mps": 0.01,
    "max_angular_speed_radps": 0.01,
    "stable_for_sec": 0.5,
    "max_sample_gap_sec": 0.1,
}


def validate_stop_policy(value):
    if value != STOP_POLICY:
        raise ValueError(
            "negative-case stop_condition must declare the supported sampled-stop policy"
        )
    return value


def _number(value):
    if (
        isinstance(value, bool)
        or not isinstance(value, (int, float))
        or not math.isfinite(value)
    ):
        raise ValueError("stop observation contains a non-finite number")
    return value


def _stamp(value):
    if type(value) is not int or value <= 0:
        raise ValueError("stop observation requires positive integer timestamps")
    return value


def _ordered(samples, anchor, cutoff, closed, gap_ns):
    if (
        not isinstance(samples, list)
        or len(samples) < 2
        or len(samples) > MAX_STOP_SAMPLES
    ):
        raise ValueError("stop observation has insufficient or excessive samples")
    previous_source = 0
    previous_receiver = anchor
    for sample in samples:
        source = _stamp(sample["source_ns"])
        receiver = _stamp(sample["receiver_ns"])
        if source <= previous_source or not previous_receiver < receiver <= closed:
            raise ValueError(
                "stop observation timestamps do not advance after the anchor"
            )
        if previous_source > cutoff and source - previous_source > gap_ns:
            raise ValueError(
                "stop observation source-time gap exceeds the declared limit"
            )
        previous_source, previous_receiver = source, receiver
    following = [sample for sample in samples if sample["source_ns"] > cutoff]
    if len(following) < 2:
        raise ValueError("stop observation has insufficient post-anchor source samples")
    return following


def _yaw(orientation):
    x, y, z, w = (_number(orientation[key]) for key in ("x", "y", "z", "w"))
    norm = math.sqrt(x * x + y * y + z * z + w * w)
    if not math.isfinite(norm) or norm == 0:
        raise ValueError("stop observation has a zero quaternion")
    x, y, z, w = (value / norm for value in (x, y, z, w))
    return math.atan2(2 * (w * z + x * y), 1 - 2 * (y * y + z * z))


def _anchor_window(report, config, window):
    goal = report["goal_id"]
    if (
        not isinstance(goal, list)
        or len(goal) != 16
        or any(type(value) is not int or not 0 <= value <= 255 for value in goal)
    ):
        raise ValueError("stop observation has no issued goal identity")
    anchor = window["anchor"]
    if anchor["goal_id"] != goal or report.get("goal_accepted") is not True:
        raise ValueError("stop observation belongs to another goal")
    if config["case"] in ("cancel", "timeout"):
        expected = report["result_observed_monotonic_ns"]
        expected_clock = report["result_observed_clock_ns"]
        response = report.get("result_observation", {})
        if (
            anchor["kind"] != "canceled_result"
            or report.get("action_status") != 5
            or report.get("cancel_acknowledged") is not True
            or response.get("goal_id") != goal
        ):
            raise ValueError("stop observation has no matching canceled result")
    elif config["case"] == "server-failure":
        expected = report["server_after_shutdown_monotonic_ns"]
        expected_clock = report["server_after_shutdown_clock_ns"]
        if (
            anchor["kind"] != "server_unavailable"
            or report.get("server_available_after_shutdown") is not False
        ):
            raise ValueError("stop observation has no server-unavailable anchor")
    else:
        raise ValueError("stop observation is outside a negative case")
    anchored = _stamp(anchor["receiver_monotonic_ns"])
    cutoff = _stamp(anchor["clock_ns"])
    closed = _stamp(window["closed_monotonic_ns"])
    deadline = _stamp(window["deadline_monotonic_ns"])
    observed_through = _stamp(window["observation_cutoff_monotonic_ns"])
    if (
        anchored != expected
        or cutoff != expected_clock
        or not anchored < observed_through <= min(deadline, closed)
    ):
        raise ValueError(
            "stop observation receiver window differs from its terminal anchor"
        )
    goal_started = _stamp(report["goal_started_monotonic_ns"])
    goal_accepted = _stamp(report["goal_accepted_monotonic_ns"])
    if not goal_started <= goal_accepted <= anchored:
        raise ValueError("stop anchor is outside the issued goal order")
    if config["case"] == "server-failure" and not (
        goal_accepted <= _stamp(report["consumer_trigger_monotonic_ns"]) <= anchored
    ):
        raise ValueError("server-unavailable anchor precedes shutdown")
    if (deadline - goal_started) / 1e9 > config["action_budget_sec"]:
        raise ValueError("stop observation exceeded the original action deadline")
    if window.get("samples_omitted") is not False:
        raise ValueError("stop observation completeness is unavailable")
    return anchored, cutoff, observed_through, closed


def _streams(window, bounds, policy):
    anchored, cutoff, observed_through, _closed = bounds
    gap_ns = round(policy["max_sample_gap_sec"] * 1e9)
    samples, clocks, transforms = (
        _ordered(window[name], anchored, cutoff, observed_through, gap_ns)
        for name in ("samples", "clock_samples", "transforms")
    )
    end = clocks[-1]["source_ns"]
    if any(
        not 0 <= end - stream[-1]["source_ns"] <= gap_ns
        for stream in (samples, transforms)
    ):
        raise ValueError("odometry or backend transform does not cover the final clock")
    end = samples[-1]["source_ns"]
    start = end - round(policy["stable_for_sec"] * 1e9)
    if start <= cutoff:
        raise ValueError("post-terminal source-time interval is too short")
    if any(stream[0]["source_ns"] > start for stream in (clocks, transforms)):
        raise ValueError("clock or backend transform does not cover the stop interval")
    return samples, clocks, transforms, start, end


def _motion(samples, transforms, config, start, end):
    linear, angular, poses = [], [], []
    for sample in samples:
        if (sample["frame_id"], sample["child_frame_id"]) != (
            config["odometry_frame"],
            "base_footprint",
        ):
            raise ValueError(
                "stop odometry frame pair differs from the admitted backend"
            )
        linear.append(math.hypot(_number(sample["vx"]), _number(sample["vy"])))
        angular.append(abs(_number(sample["wz"])))
        poses.append(
            (_number(sample["x"]), _number(sample["y"]), _yaw(sample["orientation"]))
        )
    for transform in transforms:
        if (transform["parent"], transform["child"]) != (
            config["odometry_frame"],
            "base_footprint",
        ):
            raise ValueError(
                "stop transform frame pair differs from the admitted backend"
            )
    selected = [
        index for index, sample in enumerate(samples) if sample["source_ns"] <= end
    ]
    before_start = [index for index in selected if samples[index]["source_ns"] <= start]
    if not before_start:
        raise ValueError("odometry does not cover the complete final stop interval")
    selected = list(range(before_start[-1], selected[-1] + 1))
    duration = (
        samples[selected[-1]]["source_ns"] - samples[selected[0]]["source_ns"]
    ) / 1e9
    if duration < config["stop_condition"]["stable_for_sec"]:
        raise ValueError("odometry source-time interval is too short")
    selected_poses = [poses[index] for index in selected]
    travel = sum(
        math.hypot(b[0] - a[0], b[1] - a[1])
        for a, b in zip(selected_poses, selected_poses[1:])
    )
    rotation = sum(
        abs(math.atan2(math.sin(b[2] - a[2]), math.cos(b[2] - a[2])))
        for a, b in zip(selected_poses, selected_poses[1:])
    )
    policy = config["stop_condition"]
    return (
        all(linear[index] <= policy["max_linear_speed_mps"] for index in selected)
        and all(
            angular[index] <= policy["max_angular_speed_radps"] for index in selected
        )
        and travel <= policy["max_linear_speed_mps"] * duration
        and rotation <= policy["max_angular_speed_radps"] * duration
    )


def assess_stop(report, config):
    """Return valid captured facts, their stop verdict, and an unavailable reason."""
    policy = config.get("stop_condition")
    if policy is None:
        return None, None, "stop_condition was not declared for this original run"
    validate_stop_policy(policy)
    window = report.get("stop_observation")
    if not isinstance(window, Mapping):
        return None, None, "post-terminal stop observations were not captured"
    try:
        bounds = _anchor_window(report, config, window)
        samples, clocks, transforms, start, end = _streams(window, bounds, policy)
        closed = bounds[3]
        if any(
            (closed - stream[-1]["receiver_ns"]) / 1e9
            > config["max_observation_age_sec"]
            for stream in (samples, clocks, transforms)
        ):
            raise ValueError("stop observations are stale")
        stopped = _motion(samples, transforms, config, start, end)
    except (
        ValueError,
        KeyError,
        TypeError,
        IndexError,
        AttributeError,
        OverflowError,
    ) as error:
        return None, None, str(error)
    if stopped and closed >= window["deadline_monotonic_ns"]:
        return (
            dict(window),
            False,
            "sampled stop did not settle before the action deadline",
        )
    return (
        dict(window),
        stopped,
        "sampled backend motion must satisfy the declared stop policy",
    )


def summarize_stop(window):
    """Project compact condition metadata from a validated workload prefix."""
    return {
        "anchor": dict(window["anchor"]),
        "observation_cutoff_monotonic_ns": window["observation_cutoff_monotonic_ns"],
        "closed_monotonic_ns": window["closed_monotonic_ns"],
        "last_odometry_source_ns": window["samples"][-1]["source_ns"],
        "sample_counts": {
            name: len(window[name])
            for name in ("samples", "transforms", "clock_samples")
        },
    }
