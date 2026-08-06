from __future__ import annotations

import hashlib
import json
import os
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Final

from robotics_acceptance_harness.result import (
    write_contract_json,
)
from robotics_acceptance_harness.traces import (
    TraceInputError,
    load_otlp_json_traces,
)

MESSAGE_TYPE: Final = "robotics_observability_msgs/msg/TraceContext"
TOPIC: Final = "/robotics/trace_context"
SOURCE_DOMAIN: Final = "zenoh-source"
DESTINATION_DOMAIN: Final = "zenoh-destination"
PRODUCER_SPAN: Final = "robotics.zenoh.publish"
CONSUMER_SPAN: Final = "robotics.zenoh.receive"


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
    normalized = value[:-1] + "+00:00" if value.endswith("Z") else value
    parsed = datetime.fromisoformat(normalized)
    if parsed.tzinfo is None:
        raise RuntimeError(f"timestamp {value!r} has no timezone")
    return parsed.astimezone(UTC)


def sha256(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def configuration_sha256(paths: tuple[Path, ...]) -> str:
    digest = hashlib.sha256()
    for path in paths:
        digest.update(path.name.encode("utf-8"))
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()


def wait_for_trace_evidence(
    path: Path,
    *,
    run_id: str,
    domain_id: str,
    span_name: str,
    expected_count: int,
) -> None:
    deadline = time.monotonic() + 30.0
    stable_size: int | None = None
    stable_observations = 0
    last_error: Exception | None = None
    while time.monotonic() < deadline:
        try:
            spans = load_otlp_json_traces(
                path,
                expected_run_id=run_id,
                expected_domain_id=domain_id,
            )
            selected = [span for span in spans if span.name == span_name]
            if len(selected) != expected_count or len(spans) != expected_count:
                raise RuntimeError(
                    f"{path} contains {len(selected)}/{expected_count} "
                    f"{span_name!r} spans and {len(spans)} total spans"
                )
            size = path.stat().st_size
            if size == stable_size:
                stable_observations += 1
            else:
                stable_size = size
                stable_observations = 0
            if stable_observations >= 2:
                return
        except (OSError, RuntimeError, TraceInputError, ValueError) as error:
            last_error = error
            stable_observations = 0
        time.sleep(0.25)
    raise RuntimeError(f"trace evidence did not stabilize: {last_error}")


def validate_probe(
    observation: dict[str, Any],
    *,
    run_id: str,
    domain_id: str,
    role: str,
    expected_count: int,
) -> None:
    expected = {
        "schema_version": "zenoh-probe-observation.v1",
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
    if not isinstance(observation.get("type_hash"), str) or not str(
        observation["type_hash"]
    ).startswith("RIHS01_"):
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


def main() -> None:
    run_id = required_environment("ROBOTICS_RUN_ID")
    report_dir = Path(required_environment("ROBOTICS_ZENOH_REPORT_DIR")).resolve()
    config_dir = Path(required_environment("ROBOTICS_ZENOH_CONFIG_DIR")).resolve()
    message_count = int(os.environ.get("ROBOTICS_MESSAGE_COUNT", "20"))

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

    wait_for_trace_evidence(
        source_trace,
        run_id=run_id,
        domain_id=SOURCE_DOMAIN,
        span_name=PRODUCER_SPAN,
        expected_count=message_count,
    )
    wait_for_trace_evidence(
        destination_trace,
        run_id=run_id,
        domain_id=DESTINATION_DOMAIN,
        span_name=CONSUMER_SPAN,
        expected_count=message_count,
    )

    output_dir = report_dir / "qualification"
    output_dir.mkdir(parents=True, exist_ok=True)
    scenario_path = Path("/opt/robotics/zenoh/scenario.yaml")
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
    write_contract_json(
        {
            "schema_version": "clock-relation.v1",
            "relation_id": "zenoh-source-destination-clock",
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
    channel_path = write_contract_json(
        {
            "schema_version": "zenoh-channel.v1",
            "channel_id": "zenoh.trace-context",
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
            "bridge": {
                "implementation": "zenoh-bridge-ros2dds",
                "version": "1.9.0",
                "configuration_sha256": configuration_sha256(
                    (
                        config_dir / "source.json5",
                        config_dir / "destination.json5",
                    )
                ),
                "dds_discovery_scope": "local_domain_only",
                "zenoh_key_expression": TOPIC,
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
    write_contract_json(
        {
            "schema_version": "causal-chain.v1",
            "chain_id": "zenoh.trace-context.e2e",
            "required_domain_ids": [
                SOURCE_DOMAIN,
                DESTINATION_DOMAIN,
            ],
            "channel_contracts": [
                {
                    "channel_id": "zenoh.trace-context",
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
    main()
