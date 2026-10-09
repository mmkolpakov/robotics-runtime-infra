"""Derive explicit offline OTLP from immutable genuine callback observations."""

from __future__ import annotations

import argparse
import hashlib
import json
import re
from pathlib import Path

from google.protobuf.json_format import MessageToJson
from opentelemetry.proto.collector.metrics.v1.metrics_service_pb2 import (
    ExportMetricsServiceRequest,
)


def attributes(destination, values: dict) -> None:
    for name, value in values.items():
        entry = destination.add(key=name)
        entry.value.string_value = str(value)


def derive(
    source: Path, output: Path, run_id: str, domain_id: str, expected_sha256: str
) -> None:
    if (
        source.is_symlink()
        or not source.is_file()
        or source.stat().st_size > 16 * 1024**2
    ):
        raise ValueError("bounded regular original observations are required")
    raw = source.read_bytes()
    if (
        not re.fullmatch("[a-f0-9]{64}", expected_sha256)
        or hashlib.sha256(raw).hexdigest() != expected_sha256
    ):
        raise ValueError(
            "original observations digest differs from the selected source"
        )
    rows = [json.loads(line) for line in raw.splitlines()]
    if any(row.get("run_id") != run_id for row in rows):
        raise ValueError("foreign observation run")
    selected = [row for row in rows if row["kind"] in {"odom", "clock"}]
    if not selected or not all(
        any(row["kind"] == kind for row in selected) for kind in ("odom", "clock")
    ):
        raise ValueError("genuine odom and Clock observations are required")
    # Epoch timestamps schedule OTLP contribution intervals. ROS simulation stamps
    # remain separate payload evidence; no simulation-to-wall offset is inferred.
    starts = {
        kind: next(row["observed_unix_ns"] for row in selected if row["kind"] == kind)
        for kind in ("odom", "clock")
    }
    ends = {
        kind: next(
            row["observed_unix_ns"] for row in reversed(selected) if row["kind"] == kind
        )
        for kind in ("odom", "clock")
    }
    window_start, window_end = min(starts.values()), max(ends.values())
    if window_end <= window_start:
        raise ValueError("no common native observation window")
    output.mkdir(mode=0o700)
    state = {
        kind: {"count": 0, "sum": 0.0, "buckets": [0] * 9} for kind in ("odom", "clock")
    }
    bounds = [0, 0.1, 0.5, 1, 5, 10, 50, 100]
    previous_sequence = None
    previous_observed = {}
    received = lost = 0
    metrics_file = output / "metrics.otlp.jsonl"
    with metrics_file.open("w") as stream:
        for row in selected:
            kind, info = row["kind"], row["message_info"]
            source_ns, received_ns = (
                info.get("source_timestamp"),
                info.get("received_timestamp"),
            )
            if not (
                type(source_ns) is int
                and type(received_ns) is int
                and 0 < source_ns <= received_ns
            ):
                raise ValueError("native RMW age metadata is unavailable")
            observed = row["observed_unix_ns"]
            if (
                type(observed) is not int
                or observed < starts[kind]
                or observed <= previous_observed.get(kind, 0)
            ):
                raise ValueError("observation epoch time moved backwards")
            previous_observed[kind] = observed
            age = (received_ns - source_ns) / 1_000_000
            request = ExportMetricsServiceRequest()
            resource = request.resource_metrics.add()
            attributes(
                resource.resource.attributes,
                {
                    "run.id": run_id,
                    "domain.id": domain_id,
                    "service.name": "nav2-offline-derived-observations",
                },
            )
            scope = resource.scope_metrics.add()
            scope.scope.name = "org.example.nav2-turtlebot3.offline"
            common = {"run.id": run_id, "domain.id": domain_id, "channel": "/" + kind}
            series = state[kind]
            include_event = observed > window_start
            series["count"] += int(include_event)
            series["sum"] += age if include_event else 0.0
            bucket = next(
                (i for i, bound in enumerate(bounds) if age <= bound), len(bounds)
            )
            series["buckets"][bucket] += int(include_event)
            metric = scope.metrics.add(
                name="robotics.message.age"
                if kind == "odom"
                else "robotics.time_authority.delivery_latency",
                unit="ms",
            )
            metric.histogram.aggregation_temporality = 2
            point = metric.histogram.data_points.add(
                start_time_unix_nano=window_start,
                time_unix_nano=observed,
                count=series["count"],
                sum=series["sum"],
            )
            point.explicit_bounds.extend(bounds)
            point.bucket_counts.extend(series["buckets"])
            attributes(
                point.attributes,
                common
                if kind == "odom"
                else {
                    **common,
                    "time.measurement.method": "rmw_source_to_reception_latency",
                    "time.source.id": "gazebo-harmonic-clock",
                },
            )
            if kind == "odom":
                sequence = info.get("publication_sequence_number")
                if (
                    type(info.get("publisher_count")) is not int
                    or info["publisher_count"] != 1
                    or type(sequence) is not int
                    or not 0 <= sequence < (1 << 64) - 1
                ):
                    raise ValueError(
                        "single-publisher native publication sequence unavailable"
                    )
                if previous_sequence is not None:
                    if sequence <= previous_sequence:
                        raise ValueError(
                            "native publication sequence reordered or reset"
                        )
                    lost += sequence - previous_sequence - 1
                previous_sequence = sequence
                received += int(include_event)
                for name, value in (
                    ("received", received),
                    ("lost", lost),
                    ("sequence_error", 0),
                ):
                    counter = scope.metrics.add(
                        name="robotics.message." + name, unit="{message}"
                    )
                    counter.sum.aggregation_temporality = 2
                    counter.sum.is_monotonic = True
                    point = counter.sum.data_points.add(
                        start_time_unix_nano=window_start,
                        time_unix_nano=observed,
                        as_int=value,
                    )
                    attributes(
                        point.attributes,
                        {
                            **common,
                            "sequence.measurement.method": "rmw_publication_sequence_single_publisher",
                        },
                    )
            stream.write(MessageToJson(request, indent=None) + "\n")
    (output / "derivation.json").write_text(
        json.dumps(
            {
                "capture_scope": "offline-derived-from-original-native-RMW-callback-observations",
                "source": {
                    "sha256": hashlib.sha256(raw).hexdigest(),
                    "size_bytes": len(raw),
                },
                "run_id": run_id,
                "domain_id": domain_id,
                "window_start_ns": str(window_start),
                "window_end_ns": str(window_end),
                "timestamp_semantics": "OTLP interval endpoints use actual callback observed_unix_ns; age is RMW received_timestamp minus source_timestamp; ROS Clock payload is never subtracted from wall time",
                "loss_scope": "gaps between observed native odom publication sequences only; no inferred loss before first or after last observation; first event at the window boundary is a zero-count cumulative baseline",
                "native_odom_received_in_window": received,
                "native_odom_callback_rows": sum(
                    row["kind"] == "odom" for row in selected
                ),
                "native_odom_sequence_gaps": lost,
                "metrics_sha256": hashlib.sha256(metrics_file.read_bytes()).hexdigest(),
            },
            indent=2,
        )
        + "\n"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--source-sha256", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--domain-id", required=True)
    args = parser.parse_args()
    derive(args.source, args.output, args.run_id, args.domain_id, args.source_sha256)


if __name__ == "__main__":
    main()
