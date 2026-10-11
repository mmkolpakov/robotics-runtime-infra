"""Assess captured Nav2 action and pose facts through verified SDK snapshots."""

import math
from collections.abc import Mapping
from hashlib import sha256

from robotics_acceptance_harness import AssertionEvaluation, EvaluationContext
from robotics_runtime_contracts import loads_mapping

NAMESPACE = "org.example.nav2-turtlebot3"


def _shutdown_or_absent_result(report, config, observed):
    """A local server observation is distinct from a physical terminal result."""
    case = report["case"]
    accepted = report.get("goal_accepted")
    if accepted is not None and type(accepted) is not bool:
        raise ValueError("malformed known SendGoal accepted flag")
    goal_id = report.get("goal_id")
    if goal_id is not None and not (
        isinstance(goal_id, list)
        and len(goal_id) == 16
        and all(type(value) is int and 0 <= value <= 255 for value in goal_id)
    ):
        raise ValueError("malformed known goal UUID")
    status = "skipped"
    matched = None
    reason = "original GetResult response was not captured"
    if accepted is False:
        matched, status, reason = False, "failed", "NavigateToPose goal was rejected"
    elif case == "server-failure":
        available = report.get("server_available_after_shutdown")
        if available is not None and type(available) is not bool:
            raise ValueError("malformed known action server presence")
        fields = (
            "goal_started_monotonic_ns",
            "goal_accepted_monotonic_ns",
            "consumer_trigger_monotonic_ns",
            "server_after_shutdown_monotonic_ns",
            "goal_finished_monotonic_ns",
        )
        values = [report.get(name) for name in fields]
        if any(
            value is not None and (type(value) is not int or value < 0)
            for value in values
        ):
            raise ValueError("malformed known shutdown receiver time")
        if available is True:
            matched, status, reason = (
                False,
                "failed",
                "Action server remained available after the requested shutdown",
            )
        elif (
            accepted is True
            and goal_id is not None
            and available is not None
            and all(value is not None for value in values)
        ):
            requested, accepted_at, issued_shutdown, observed_at, finished = values
            ordered = (
                requested <= accepted_at <= issued_shutdown <= observed_at <= finished
            )
            within_budget = (
                ordered
                and (observed_at - requested) / 1e9 < config["action_budget_sec"]
            )
            matched = (
                available is False
                and within_budget
                and report.get("observation_status")
                in {"server-unavailable", "complete"}
            )
            status = "passed" if matched else "failed"
            reason = "Captured local shutdown/server observation must match the issued goal and budget"
        else:
            reason = (
                "issued goal or ordered shutdown/server observation was not captured"
            )
    response = report.get("result_observation")
    if isinstance(response, Mapping) and response.get("goal_id") != goal_id:
        matched, status, reason = (
            False,
            "failed",
            "GetResult belongs to another issued goal",
        )
    return [
        (
            "native-observations",
            "passed" if observed else "skipped",
            observed,
            "Native odom/TF/Clock observations must be captured",
        ),
        ("action-" + case, status, matched, reason),
    ]


def _bound_cdr(context, report):
    candidates = [
        (path, link)
        for path, link in context.evidence.local_files.items()
        if path.name == "get-result-response.cdr"
    ]
    if len(candidates) > 1:
        raise ValueError("ambiguous original GetResult CDR artifacts")
    if not candidates:
        return None
    path, link = candidates[0]
    response = report.get("result_observation")
    if not isinstance(response, Mapping):
        raise ValueError("GetResult CDR has no original observation metadata")
    raw = context.evidence.read_local(path, max_raw_evidence_bytes=1024 * 1024)
    if (
        sha256(raw).hexdigest() != link["sha256"]
        or link["sha256"] != response.get("sha256")
        or len(raw) != response.get("size_bytes")
        or link["sha256"] not in context.evidence_sha256
        or response.get("capture_method")
        != "serialized-client-GetResult_Response-observation"
        or response.get("encoding") != "cdr"
    ):
        raise ValueError("GetResult CDR does not match the verified observation")
    return link


def evaluate(context: EvaluationContext):
    controls = context.assessment_controls
    if controls is not None and controls.data["calibration"]["state"] == "selected":
        raise ValueError("the Nav2 method does not consume selected calibration")
    candidates = [
        (path, link)
        for path, link in context.evidence.local_files.items()
        if path.name == "workload.json" and link["media_type"] == "application/json"
    ]
    if len(candidates) != 1:
        raise ValueError("one verified Nav2 workload JSON artifact is required")
    path, link = candidates[0]
    raw = context.evidence.read_local(path, max_raw_evidence_bytes=1024 * 1024)
    report = loads_mapping(raw, source_name=str(path))
    if (
        report.get("run_id") != context.run_id
        or report.get("domain_id") != context.domain_id
    ):
        raise ValueError("Nav2 observation belongs to another run or domain")
    digest = str(link["sha256"])
    if digest not in context.evidence_sha256:
        raise ValueError("Nav2 JSON has no verified evidence binding")
    config = context.bundle.scenario.as_dict().get("extensions", {}).get(NAMESPACE)
    if not isinstance(config, Mapping):
        raise TypeError("declared Nav2 scenario extension is required")
    expected_parameters = {
        key: config[key]
        for key in [
            "goal",
            "action_budget_sec",
            "application_timeout_sec",
            "max_final_pose_error_m",
            "min_displacement_m",
            "max_observation_age_sec",
            "odometry_frame",
            "required_tf_edges",
            "readiness",
        ]
    }
    if report.get("parameters") != expected_parameters:
        raise ValueError("worker parameters differ from the declared scenario")
    case = report.get("case")
    if case != config.get("case"):
        raise ValueError("observed Nav2 case differs from declared scenario")
    if case not in {"success", "cancel", "timeout", "server-failure"}:
        raise ValueError("unknown Nav2 case")
    counts = report.get("message_counts", {})
    if not isinstance(counts, Mapping) or any(
        key in counts and (type(counts[key]) is not int or counts[key] < 0)
        for key in ("odom", "tf", "clock")
    ):
        raise ValueError("malformed known native observation counts")
    observed = all(
        type(counts.get(key)) is int and counts[key] >= minimum
        for key, minimum in {"odom": 2, "tf": 2, "clock": 30}.items()
    )
    cdr_link = _bound_cdr(context, report)
    if (
        case == "server-failure"
        or report.get("goal_accepted") is False
        or cdr_link is None
    ):
        for name, status, value, message in _shutdown_or_absent_result(
            report, config, observed
        ):
            yield AssertionEvaluation(
                assertion_id=NAMESPACE + "." + name,
                status=status,
                observed_value=value,
                unit="1",
                message=message,
                source="product",
                namespace=NAMESPACE,
                evidence_sha256=(digest, str(cdr_link["sha256"]))
                if cdr_link
                else (digest,),
            )
        return
    finished = report.get("goal_finished_monotonic_ns", 0)
    latest = report.get("last_observation_monotonic_ns", {})
    freshness = config["max_observation_age_sec"]
    fresh = all(
        isinstance(latest.get(key), int)
        and latest[key] >= report.get("result_observed_monotonic_ns", finished + 1)
        and 0 <= (finished - latest[key]) / 1e9 <= freshness
        for key in ["odom", "tf", "clock", "amcl_pose"]
    )
    edges = {
        (edge["parent"], edge["child"]): edge for edge in report.get("tf_edges", [])
    }
    required = [tuple(pair) for pair in config["required_tf_edges"]]
    tf_valid = all(
        pair in edges
        and (
            edges[pair]["source_topic"] == "/tf_static"
            or (
                edges[pair]["ros_stamp_ns"] > 0
                and edges[pair]["observed_monotonic_ns"]
                >= report.get("result_observed_monotonic_ns", finished + 1)
                and 0
                <= (finished - edges[pair]["observed_monotonic_ns"]) / 1e9
                <= freshness
            )
        )
        for pair in required
    )
    complete = report.get("observation_status") in {"complete", "server-unavailable"}
    goal_id = report.get("goal_id")
    response = report.get("result_observation", {})
    action_identity = (
        isinstance(goal_id, list)
        and len(goal_id) == 16
        and all(type(value) is int and 0 <= value <= 255 for value in goal_id)
        and report.get("goal_accepted") is True
        and response.get("goal_id") == goal_id
        and response.get("capture_method")
        == "serialized-client-GetResult_Response-observation"
        and response.get("encoding") == "cdr"
        and response.get("size_bytes", 0) > 0
    )
    requested_at = report.get("goal_started_monotonic_ns")
    accepted = report.get("goal_accepted_monotonic_ns")
    result = report.get("result_observed_monotonic_ns")
    action_within_budget = (
        type(requested_at) is int
        and type(accepted) is int
        and type(result) is int
        and requested_at <= accepted <= result <= finished
        and (result - requested_at) / 1e9 < config["action_budget_sec"]
    )
    # Expected negative observations never override an ERROR/incomplete core policy result.
    action_status = report.get("action_status")
    if case == "success":
        goal = config.get("goal", {})
        requested = report.get("goal_requested", {})
        final = report.get("final_amcl_pose", {})
        identity = goal == requested and set(goal) == {"x", "y"}
        pose_error = math.hypot(
            final.get("x", math.inf) - goal.get("x", 0),
            final.get("y", math.inf) - goal.get("y", 0),
        )
        initial = report.get("initial_amcl_pose", {})
        displacement = math.hypot(
            final.get("x", 0) - initial.get("x", 0),
            final.get("y", 0) - initial.get("y", 0),
        )
        odom_initial = report.get("initial_odometry", {})
        odom_final = report.get("final_odometry", {})
        odom_moved = math.hypot(
            odom_final.get("x", 0) - odom_initial.get("x", 0),
            odom_final.get("y", 0) - odom_initial.get("y", 0),
        )
        update = report.get("amcl_nomotion_update", {})
        update_valid = (
            update.get("service") == "/request_nomotion_update"
            and update.get("type") == "std_srvs/srv/Empty"
            and update.get("server_node") == "/amcl"
            and update.get("response") == {}
            and report.get("result_observed_monotonic_ns", 0)
            <= update.get("requested_monotonic_ns", -1)
            <= update.get("responded_monotonic_ns", -1)
            <= finished
            and final.get("observed_monotonic_ns", -1)
            >= update.get("requested_monotonic_ns", finished + 1)
            and final.get("ros_stamp_ns", 0) > update.get("prior_amcl_ros_stamp_ns", 0)
        )
        matched = (
            identity
            and update_valid
            and (finished - requested_at) / 1e9 < config["action_budget_sec"]
            and 0 <= (finished - update["responded_monotonic_ns"]) / 1e9 < freshness
            and odom_initial.get("frame_id")
            == odom_final.get("frame_id")
            == config["odometry_frame"]
            and odom_initial.get("child_frame_id") == odom_final.get("child_frame_id")
            and odom_final.get("ros_stamp_ns", 0)
            > odom_initial.get("ros_stamp_ns", 0)
            > 0
            and odom_moved >= config["min_displacement_m"]
            and fresh
            and tf_valid
            and final.get("frame_id") == "map"
            and initial.get("frame_id") == "map"
            and final.get("ros_stamp_ns", 0) > initial.get("ros_stamp_ns", 0) > 0
            and displacement >= config["min_displacement_m"]
            and action_status == 4
            and pose_error <= config["max_final_pose_error_m"]
        )
    elif case in {"cancel", "timeout"}:
        matched = (
            action_status == 5
            and report.get("cancel_requested") is True
            and report.get("cancel_acknowledged") is True
        )
        if case == "timeout":
            matched = (
                matched
                and report.get("application_deadline_reached") is True
                and report.get("consumer_trigger_budget_sec")
                == config["application_timeout_sec"]
                and report.get("consumer_trigger_elapsed_sec", -1)
                >= config["application_timeout_sec"]
            )
    else:
        matched = report.get("server_available_after_shutdown") is False and report.get(
            "observation_status"
        ) in {"server-unavailable", "complete"}
    matched = matched and action_identity and action_within_budget
    outcomes = [
        (
            "native-observations",
            "passed" if observed else "error",
            observed,
            "Native odom/TF/Clock observations are required",
        ),
        (
            "action-" + str(case),
            "passed"
            if observed and complete and matched
            else "failed"
            if observed and complete
            else "error",
            matched,
            "Recorded action outcome must match the declared case",
        ),
    ]
    for name, status, value, message in outcomes:
        yield AssertionEvaluation(
            assertion_id=NAMESPACE + "." + name,
            status=status,
            observed_value=value,
            unit="1",
            message=message,
            source="product",
            namespace=NAMESPACE,
            evidence_sha256=(digest, str(cdr_link["sha256"])),
        )
