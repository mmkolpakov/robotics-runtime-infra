"""Assess decoded stock MAVSDK records without implementing a vehicle or codec."""

from __future__ import annotations

import math

from robotics_acceptance_harness import AssertionEvaluation, EvaluationContext
from robotics_runtime_contracts import loads_mapping

NAMESPACE = "org.example.px4-x500"
CLOCK_SOURCE = "controller-utc-ms"
LIMIT = 1024 * 1024
# The pinned MAVSDK-Proto ActionResult.Result, not a new wire decoder.
# https://github.com/mavlink/MAVSDK-Proto/blob/5c81ecfeb6110cf74ba75ae50b78a1b265c05670/protos/action/action.proto
ACTION_RESULTS = {
    "RESULT_UNKNOWN",
    "RESULT_SUCCESS",
    "RESULT_NO_SYSTEM",
    "RESULT_CONNECTION_ERROR",
    "RESULT_BUSY",
    "RESULT_COMMAND_DENIED",
    "RESULT_COMMAND_DENIED_LANDED_STATE_UNKNOWN",
    "RESULT_COMMAND_DENIED_NOT_LANDED",
    "RESULT_TIMEOUT",
    "RESULT_VTOL_TRANSITION_SUPPORT_UNKNOWN",
    "RESULT_NO_VTOL_TRANSITION_SUPPORT",
    "RESULT_PARAMETER_ERROR",
    "RESULT_UNSUPPORTED",
    "RESULT_FAILED",
    "RESULT_INVALID_ARGUMENT",
}
UNCERTAIN_RESULTS = {
    "RESULT_UNKNOWN",
    "RESULT_NO_SYSTEM",
    "RESULT_CONNECTION_ERROR",
    "RESULT_TIMEOUT",
    "RESULT_VTOL_TRANSITION_SUPPORT_UNKNOWN",
}


def decimal(value):
    if not isinstance(value, str) or not value.isdecimal() or len(value) > 20:
        raise ValueError("receiver nanoseconds must be a bounded decimal string")
    return int(value)


def validate_journal(manifest, configuration, records, run_id, domain_id):
    """Require captured receiver order/window and the original run configuration."""
    if (
        manifest.get("run_id"),
        manifest.get("domain_id"),
        manifest.get("clock_source"),
        manifest.get("complete"),
    ) != (run_id, domain_id, CLOCK_SOURCE, True) or manifest.get(
        "complete"
    ) is not True:
        raise ValueError("foreign, open or unsupported-clock controller manifest")
    if (configuration.get("run_id"), configuration.get("domain_id")) != (
        run_id,
        domain_id,
    ):
        raise ValueError("configuration belongs to another run/domain")
    start, end = (
        decimal(manifest["started_unix_ns"]),
        decimal(manifest["finished_unix_ns"]),
    )
    if end <= start or not 0 < len(records) <= 2048:
        raise ValueError("receiver window/count is invalid")
    total = sum(reference["size_bytes"] for _record, reference in records)
    if total > 8 * 1024**2 or manifest.get("total_bytes") != total:
        raise ValueError("controller manifest total differs from captured bytes")
    previous_time, previous_monotonic = start, -1
    for number, ((record, reference), entry) in enumerate(
        zip(records, manifest["records"], strict=True)
    ):
        if (
            (
                record.get("run_id"),
                record.get("domain_id"),
                record.get("sequence"),
                record.get("kind"),
            )
            != (run_id, domain_id, number, entry["kind"])
            or type(record.get("sequence")) is not int
            or not isinstance(record.get("value"), dict)
        ):
            raise ValueError("record identity/sequence differs from its manifest")
        if (reference["sha256"], reference["size_bytes"]) != (
            entry["sha256"],
            entry["size_bytes"],
        ):
            raise ValueError("manifest differs from registered record bytes")
        timestamp = decimal(record.get("receiver_unix_ns"))
        monotonic = record.get("receiver_monotonic_ms")
        if (
            not start <= timestamp <= end
            or timestamp < previous_time
            or isinstance(monotonic, bool)
            or not isinstance(monotonic, (int, float))
            or not math.isfinite(monotonic)
            or monotonic < previous_monotonic
        ):
            raise ValueError("record has no ordered receiver time inside its window")
        previous_time, previous_monotonic = timestamp, monotonic


def decoded(record):
    value = record["value"].get("value")
    if not isinstance(value, dict):
        raise ValueError("malformed known decoded SDK response")
    return value


def facts(records, configuration, cleanup):
    """One interpretation shared by producer projections and the product method."""
    kinds = {}
    for record, link in records:
        kinds.setdefault(record["kind"], []).append((record, link))
    results = kinds.get("controller-result", [])
    if len(results) > 1:
        raise ValueError("duplicate terminal controller records")
    terminal, terminal_ref = (
        (results[0][0]["value"], results[0][1]) if results else ({}, None)
    )
    if results and type(terminal.get("complete")) is not bool:
        raise ValueError("malformed terminal controller completion")
    outcome = terminal.get("outcome", {})
    if not isinstance(outcome, dict):
        raise ValueError("malformed terminal controller outcome")
    completed = terminal.get("complete") is True
    if (completed or "case" in outcome) and outcome.get("case") != configuration[
        "case"
    ]:
        raise ValueError("controller case differs from immutable inputs")
    completion = (
        True if completed else None,
        terminal_ref,
        None if completed else "terminal controller completion was not captured",
    )
    issued = {}
    for record, link in kinds.get("action-issued", []):
        method = record["value"].get("method")
        if not isinstance(method, str):
            raise ValueError("malformed issued SDK action")
        issued.setdefault(method, []).append((record, link))

    def phase(method):
        values = issued.get(method, [])
        return values[-1][0]["sequence"] if values else None

    takeoff_phase, land_phase = phase("takeoff"), phase("land")
    refusal = configuration["case"] == "unarmed-refusal"
    if refusal:
        forbidden = any(issued.get(method) for method in ("arm", "takeoff"))
        command = (
            False
            if forbidden
            else (
                outcome.get("observed") == "caller-refused-unarmed"
                and outcome.get("refusal")
                == {
                    "method": "takeoff",
                    "boundary": "caller-precondition",
                    "reason": "unarmed",
                }
            )
            if completed
            else None
        )
        command_ref = terminal_ref
        position_rows = kinds.get("telemetry-position", [])
        terminal_phase = position_rows[0][0]["sequence"] if position_rows else None
    else:
        responses = kinds.get("action-takeoff", [])
        command, command_ref = None, None
        if responses:
            response_record, command_ref = responses[-1]
            response = decoded(response_record).get("action_result")
            if (
                not isinstance(response, dict)
                or not isinstance(response.get("result"), str)
                or response["result"] not in ACTION_RESULTS
            ):
                raise ValueError("malformed known TakeoffResponse result")
            if (
                takeoff_phase is not None
                and response_record["sequence"] > takeoff_phase
            ):
                result = response["result"]
                command = (
                    None if result in UNCERTAIN_RESULTS else result == "RESULT_SUCCESS"
                )
        terminal_phase = (
            land_phase
            if land_phase is not None
            and takeoff_phase is not None
            and land_phase > takeoff_phase
            else None
        )

    def final(kind, field, expected):
        values = [
            (record, reference)
            for record, reference in kinds.get(kind, [])
            if terminal_phase is not None and record["sequence"] > terminal_phase
        ]
        if not values:
            return None, None, "required terminal-phase telemetry was not captured"
        record, reference = values[-1]
        value = decoded(record).get(field)
        if field == "is_armed" and type(value) is not bool:
            raise ValueError("malformed known ArmedResponse")
        if field == "landed_state" and (
            not isinstance(value, str)
            or value
            not in {
                "LANDED_STATE_UNKNOWN",
                "LANDED_STATE_ON_GROUND",
                "LANDED_STATE_IN_AIR",
                "LANDED_STATE_TAKING_OFF",
                "LANDED_STATE_LANDING",
            }
        ):
            raise ValueError("malformed known LandedStateResponse")
        if value == "LANDED_STATE_UNKNOWN":
            return None, reference, "native landed state is UNKNOWN"
        return value == expected, reference, None

    grounded = final("telemetry-landed", "landed_state", "LANDED_STATE_ON_GROUND")
    disarmed = final("telemetry-armed", "is_armed", False)
    positions = []
    for record, reference in kinds.get("telemetry-position", []):
        if not refusal and (
            takeoff_phase is None or record["sequence"] <= takeoff_phase
        ):
            continue
        position = decoded(record).get("position")
        altitude = (
            position.get("relative_altitude_m") if isinstance(position, dict) else None
        )
        if (
            isinstance(altitude, bool)
            or not isinstance(altitude, (float, int))
            or not math.isfinite(altitude)
        ):
            raise ValueError("malformed known PositionResponse relative altitude")
        positions.append((float(altitude), reference))
    if positions:
        if refusal:
            initial = positions[0][0]
            excursion = max(abs(value - initial) for value, _ref in positions)
            condition = (
                False
                if excursion > configuration["max_refusal_ascent_m"]
                else (True if len(positions) >= 4 else None)
            )
            condition_ref = positions[-1][1]
        else:
            maximum, condition_ref = max(positions, key=lambda item: item[0])
            condition = maximum >= configuration["min_ascent_m"]
        postcondition = (
            condition,
            condition_ref,
            (
                "required refusal position sample count was not captured"
                if condition is None
                else None
            ),
        )
    else:
        postcondition = None, None, "post-command position telemetry was not captured"
    released = None, None, "native owner cleanup was not captured"
    if cleanup:
        observed, reference = cleanup
        if observed.get("owner_id") != configuration["run_id"]:
            raise ValueError("cleanup belongs to another native owner")
        resources = observed.get("observed")
        if (
            type(observed.get("released")) is not bool
            or not isinstance(resources, dict)
            or not isinstance(resources.get("containers"), list)
            or not isinstance(resources.get("networks"), list)
        ):
            raise ValueError("malformed known Engine cleanup observation")
        released = (
            observed["released"]
            and not resources["containers"]
            and not resources["networks"],
            reference,
            None,
        )
    return {
        "completion": completion,
        "command": (
            command,
            command_ref,
            "command acceptance/order was not captured" if command is None else None,
        ),
        "grounded": grounded,
        "disarmed": disarmed,
        "postcondition": postcondition,
        "cleanup": released,
    }


def evaluate(context: EvaluationContext):
    if (
        context.assessment_controls is not None
        and context.assessment_controls.data["calibration"]["state"] == "selected"
    ):
        raise ValueError("the PX4 method does not consume selected calibration")
    named = {path.name: path for path in context.evidence.local_files}
    if len(named) != len(context.evidence.local_files):
        raise ValueError("ambiguous source artifact basenames")
    manifest_path = named.get("controller-manifest.json")
    config_path = named.get("configuration.json")
    if manifest_path is None or config_path is None:
        raise ValueError(
            "one original manifest and executor configuration are required"
        )

    def read(path):
        return loads_mapping(
            context.evidence.read_local(path, max_raw_evidence_bytes=LIMIT),
            source_name=str(path),
        )

    manifest, configuration = read(manifest_path), read(config_path)
    config_link = context.evidence.local_files[config_path]
    expected = context.scenario["profile"]["executor"]["configuration"]
    if (config_link["sha256"], config_link["size_bytes"]) != (
        expected["sha256"],
        expected["size_bytes"],
    ):
        raise ValueError("configuration differs from immutable scenario inputs")
    entries = manifest.get("records")
    if not isinstance(entries, list) or not 0 < len(entries) <= 2048:
        raise ValueError("controller manifest record count is invalid")
    records, seen = [], set()
    for entry in entries:
        name = entry["path"]
        if not isinstance(name, str) or name in seen or "/" in name or "\\" in name:
            raise ValueError("manifest record names must be unique basenames")
        seen.add(name)
        path = named.get(name)
        if path is None:
            raise ValueError("manifest record is not registered evidence")
        records.append((read(path), context.evidence.local_files[path]))
    validate_journal(
        manifest, configuration, records, context.run_id, context.domain_id
    )
    if (
        decimal(manifest["started_unix_ns"]),
        decimal(manifest["finished_unix_ns"]),
    ) != (context.window_start_ns, context.window_end_ns):
        raise ValueError("assessment window differs from captured receiver window")
    cleanup_path = named.get("engine-cleanup.json")
    cleanup = (
        (read(cleanup_path), context.evidence.local_files[cleanup_path])
        if cleanup_path
        else None
    )
    try:
        assessed = facts(records, configuration, cleanup)
    except ValueError as error:
        yield AssertionEvaluation(
            assertion_id=NAMESPACE + ".invalid",
            status="error",
            observed_value=None,
            unit="1",
            message=str(error),
            source="product",
            namespace=NAMESPACE,
            evidence_sha256=(
                str(context.evidence.local_files[manifest_path]["sha256"]),
            ),
        )
        return
    for name, (value, reference, reason) in assessed.items():
        yield AssertionEvaluation(
            assertion_id=NAMESPACE + "." + name,
            status="skipped" if value is None else "passed" if value else "failed",
            observed_value=value,
            unit="1",
            message=reason or "Captured SDK fact must meet the declared case",
            source="product",
            namespace=NAMESPACE,
            evidence_sha256=(str(reference["sha256"]),)
            if reference
            else (str(context.evidence.local_files[manifest_path]["sha256"]),),
        )
