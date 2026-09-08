from __future__ import annotations

import hashlib
import json
import os
import re
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Final

from robotics_acceptance_harness.traces import load_otlp_json_traces
from robotics_runtime_contracts.writers import write_document

MESSAGE_TYPE: Final = "robotics_observability_msgs/msg/TraceContext"
TOPIC: Final = "/robotics/trace_context"
SOURCE_DOMAIN: Final = "transport-source"
DESTINATION_DOMAIN: Final = "transport-destination"
PRODUCER_SPAN: Final = "robotics.transport.publish"
CONSUMER_SPAN: Final = "robotics.transport.receive"


def required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def load_json(path: Path) -> dict[str, Any]:
    value = json.loads(path.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise TypeError(f"{path} must contain a JSON object")
    return value


def parse_timestamp(value: str) -> datetime:
    parsed = datetime.fromisoformat(value)
    if parsed.tzinfo is None:
        raise RuntimeError(f"timestamp {value!r} has no timezone")
    return parsed.astimezone(UTC)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def validate_trace_evidence(
    path: Path,
    *,
    run_id: str,
    domain_id: str,
    span_name: str,
    expected_count: int,
) -> None:
    # The runner stops and flushes both Collectors before invoking this producer.
    spans = load_otlp_json_traces(
        path, expected_run_id=run_id, expected_domain_id=domain_id
    )
    selected = [span for span in spans if span.name == span_name]
    if len(selected) != expected_count or len(spans) != expected_count:
        raise RuntimeError(
            f"{path} contains {len(selected)}/{expected_count} "
            f"{span_name!r} spans and {len(spans)} total spans"
        )


def validate_probe(
    observation: dict[str, Any],
    *,
    run_id: str,
    domain_id: str,
    role: str,
    expected_count: int,
) -> None:
    expected = {
        "schema_version": "transport-probe-observation.v1",
        "run_id": run_id,
        "domain_id": domain_id,
        "role": role,
        "topic": TOPIC,
        "message_type": MESSAGE_TYPE,
    }
    for key, value in expected.items():
        if observation.get(key) != value:
            raise RuntimeError(
                f"{domain_id} probe field {key!r} is "
                f"{observation.get(key)!r}; expected {value!r}"
            )
    if not isinstance(observation.get("type_hash"), str) or not re.fullmatch(
        r"RIHS01_[0-9a-f]{64}", observation["type_hash"]
    ):
        raise RuntimeError(f"{domain_id} probe has no REP-2011 type hash")
    if int(observation["publishers"]) < 1 or int(observation["subscribers"]) < 1:
        raise RuntimeError(f"{domain_id} did not observe both ROS endpoint roles")
    observed_count = (
        int(observation["published_count"])
        if role == "source"
        else int(observation["received_count"])
    )
    if observed_count != expected_count:
        raise RuntimeError(
            f"{domain_id} observed {observed_count}/{expected_count} messages"
        )
    if int(observation["unique_traceparent_count"]) != expected_count:
        raise RuntimeError(f"{domain_id} traceparent values are not unique")
    if int(observation["matched_tracestate_count"]) != expected_count:
        raise RuntimeError(f"{domain_id} did not preserve every tracestate value")
    if parse_timestamp(str(observation["finished_at"])) < parse_timestamp(
        str(observation["started_at"])
    ):
        raise RuntimeError(f"{domain_id} probe timestamps are reversed")


def prepare(report_dir: Path, run_id: str, message_count: int) -> None:
    if message_count < 1:
        raise ValueError("message count must be positive")
    configuration_path = report_dir / "configuration/implementation.json"
    configuration = load_json(configuration_path)
    required_files = {
        "ros2.domain_bridge": {"domain-bridge.yaml", "udp-only.xml", "version.txt"},
        "zenoh_bridge_ros2dds": {"source.json5", "destination.json5", "version.txt"},
    }
    if configuration.get("schema_version") != "transport-implementation.v1":
        raise ValueError("unsupported bridge implementation metadata")
    expected_files = required_files.get(configuration.get("implementation_id"))
    if expected_files is None:
        raise ValueError("unsupported bridge implementation")
    artifacts = configuration.get("artifacts", [])
    names = [artifact["path"] for artifact in artifacts]
    if len(names) != len(expected_files) or set(names) != expected_files:
        raise ValueError(
            "retained bridge configuration inventory is incomplete or duplicated"
        )
    if not re.fullmatch(
        r"sha256:[0-9a-f]{64}", configuration.get("image_config_digest", "")
    ):
        raise ValueError("bridge image configuration digest is missing or invalid")
    for artifact in configuration["artifacts"]:
        path = (configuration_path.parent / artifact["path"]).resolve()
        if not path.is_relative_to(configuration_path.parent.resolve()):
            raise ValueError("bridge configuration is outside the retained directory")
        if sha256(path) != artifact["sha256"]:
            raise ValueError("retained bridge configuration digest mismatch")
    source_trace = report_dir / "source" / "traces.otlp.jsonl"
    destination_trace = report_dir / "destination" / "traces.otlp.jsonl"
    source_observation_path = report_dir / "source" / "probe.json"
    destination_observation_path = report_dir / "destination" / "probe.json"
    source_observation = load_json(source_observation_path)
    destination_observation = load_json(destination_observation_path)
    validate_probe(
        source_observation,
        run_id=run_id,
        domain_id=SOURCE_DOMAIN,
        role="source",
        expected_count=message_count,
    )
    validate_probe(
        destination_observation,
        run_id=run_id,
        domain_id=DESTINATION_DOMAIN,
        role="destination",
        expected_count=message_count,
    )
    if source_observation["type_hash"] != destination_observation["type_hash"]:
        raise RuntimeError("source and destination ROS type hashes differ")
    if source_observation.get("clock_identity") != destination_observation.get(
        "clock_identity"
    ):
        raise RuntimeError(
            "source and destination do not share one Linux realtime clock"
        )

    validate_trace_evidence(
        source_trace,
        run_id=run_id,
        domain_id=SOURCE_DOMAIN,
        span_name=PRODUCER_SPAN,
        expected_count=message_count,
    )
    validate_trace_evidence(
        destination_trace,
        run_id=run_id,
        domain_id=DESTINATION_DOMAIN,
        span_name=CONSUMER_SPAN,
        expected_count=message_count,
    )

    output_dir = report_dir / "qualification"
    output_dir.mkdir(parents=True, exist_ok=True)
    scenario_path = Path(__file__).with_name("scenario.yaml")
    clock_identity_path = output_dir / "shared-clock-identity.json"
    shared_clock_identity = {
        **source_observation["clock_identity"],
        "source_observation_sha256": sha256(source_observation_path),
        "destination_observation_sha256": sha256(destination_observation_path),
    }
    clock_identity_path.write_text(
        json.dumps(
            {
                "schema_version": "shared-clock-identity.v1",
                "method": "shared_linux_kernel_realtime_clock",
                "source_domain_id": SOURCE_DOMAIN,
                "destination_domain_id": DESTINATION_DOMAIN,
                "clock_identity": shared_clock_identity,
            },
            indent=2,
            sort_keys=True,
        )
        + "\n",
        encoding="utf-8",
    )
    write_document(
        {
            "schema_version": "clock-relation.v1",
            "relation_id": "transport-source-destination-clock",
            "run_id": run_id,
            "scenario_sha256": sha256(scenario_path),
            "source_domain_id": SOURCE_DOMAIN,
            "destination_domain_id": DESTINATION_DOMAIN,
            "method": "shared_clock_identity",
            "sync_protocol": "shared_kernel_clock",
            "started_at": min(
                source_observation["started_at"],
                destination_observation["started_at"],
            ),
            "finished_at": max(
                source_observation["finished_at"],
                destination_observation["finished_at"],
            ),
            "policy": {"method": "shared_clock_identity"},
            "shared_clock_identity": shared_clock_identity,
            "status": "passed",
            "violations": [],
            "evidence_sha256": sha256(clock_identity_path),
        },
        output_dir / "clock-relation.json",
    )
    channel_path = write_document(
        {
            "schema_version": "transport-channel.v1",
            "channel_id": "transport.trace-context",
            "source": {
                "domain_id": SOURCE_DOMAIN,
                "ros_domain_id": 31,
                "topic": TOPIC,
                "message_type": MESSAGE_TYPE,
                "type_hash": source_observation["type_hash"],
            },
            "destination": {
                "domain_id": DESTINATION_DOMAIN,
                "ros_domain_id": 32,
                "topic": TOPIC,
                "message_type": MESSAGE_TYPE,
                "type_hash": destination_observation["type_hash"],
            },
            "implementation_binding": {
                "implementation_id": configuration["implementation_id"],
                "version": configuration["version"],
                "configuration_sha256": sha256(configuration_path),
            },
            "qos": {
                "reliability": "reliable",
                "durability": "volatile",
                "history": "keep_last",
                "depth": 100,
                "liveliness": "automatic",
                "liveliness_lease_duration_ms": "infinite",
                "deadline_ms": "infinite",
                "lifespan_ms": "infinite",
            },
            "delivery": {
                "observation_window_sec": 60,
                "minimum_source_messages": message_count,
                "message_id_attribute": "messaging.message.id",
                "max_loss_ratio": 0,
                "max_duplicate_count": 0,
                "max_out_of_order_count": 0,
                "max_message_age_ms": 5000,
            },
            "trace": {
                "carrier_field": "trace_context",
                "relationship": "parent",
                "producer_span_name": PRODUCER_SPAN,
                "consumer_span_name": CONSUMER_SPAN,
            },
        },
        output_dir / "channel.json",
    )
    write_document(
        {
            "schema_version": "causal-chain.v1",
            "chain_id": "transport.trace-context.e2e",
            "required_domain_ids": [
                SOURCE_DOMAIN,
                DESTINATION_DOMAIN,
            ],
            "channel_contracts": [
                {
                    "channel_id": "transport.trace-context",
                    "sha256": sha256(channel_path),
                }
            ],
            "require_connected_trace_graph": True,
            "missing_evidence_status": "incomplete",
            "broken_relationship_status": "failed",
        },
        output_dir / "causal-chain.json",
    )


if __name__ == "__main__":
    prepare(
        Path(required_environment("ROBOTICS_TRANSPORT_REPORT_DIR")).resolve(),
        required_environment("ROBOTICS_RUN_ID"),
        int(required_environment("ROBOTICS_MESSAGE_COUNT")),
    )
