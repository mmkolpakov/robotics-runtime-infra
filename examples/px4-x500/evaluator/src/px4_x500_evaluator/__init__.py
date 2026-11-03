"""Evidence-bound sampled PX4 valid-home method, version0.2."""

from __future__ import annotations

import math

from robotics_acceptance_harness import AssertionEvaluation, EvaluationContext
from robotics_runtime_contracts import loads_mapping

from ._ulog import sampled_facts

NAMESPACE = "org.example.px4-x500"
CLOCK_SOURCE = "controller-utc-ms"
LIMIT = 1024 * 1024


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


def facts(records, configuration, cleanup, *, evidence=None, native=None):
    if configuration.get("measurement_method") != "px4-valid-home-sampled-v0.2":
        raise ValueError(
            "the version0.2 method requires its original sampled configuration"
        )
    if (
        configuration.get("min_ascent_m"),
        configuration.get("max_refusal_ascent_m"),
        configuration.get("application_deadline_ms"),
        configuration.get("max_ulog_bytes"),
    ) != (1.2, 0.2, 2000, 64 * 1024**2):
        raise ValueError(
            "the version0.2 method requires its declared thresholds and byte budget"
        )
    return sampled_facts(
        records, configuration, cleanup, evidence=evidence, native=native
    )


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
        native_path = named.get("native-evidence.json")
        native = read(native_path) if native_path else None
        assessed = facts(
            records, configuration, cleanup, evidence=context.evidence, native=native
        )
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
            message=reason
            or "Captured source fact must meet the declared sampled case",
            source="product",
            namespace=NAMESPACE,
            evidence_sha256=(str(reference["sha256"]),)
            if reference
            else (str(context.evidence.local_files[manifest_path]["sha256"]),),
        )
