from __future__ import annotations

import argparse
import json
import os
import re
import secrets
import time
from datetime import UTC, datetime
from pathlib import Path
from typing import Any, Final

import rclpy
from opentelemetry import trace
from opentelemetry.exporter.otlp.proto.http.trace_exporter import OTLPSpanExporter
from opentelemetry.sdk.resources import Resource
from opentelemetry.sdk.trace import TracerProvider
from opentelemetry.sdk.trace.export import BatchSpanProcessor
from opentelemetry.trace import (
    NonRecordingSpan,
    SpanContext,
    SpanKind,
    TraceFlags,
    TraceState,
    set_span_in_context,
)
from rclpy.node import Node
from rclpy.qos import (
    DurabilityPolicy,
    HistoryPolicy,
    QoSProfile,
    ReliabilityPolicy,
)
from robotics_observability import extract_context, inject_context
from robotics_observability_msgs.msg import TraceContext

MESSAGE_TYPE: Final = "robotics_observability_msgs/msg/TraceContext"
PRODUCER_SPAN: Final = "robotics.zenoh.publish"
CONSUMER_SPAN: Final = "robotics.zenoh.receive"
TRACEPARENT_PATTERN: Final = re.compile(r"^00-[0-9a-f]{32}-[0-9a-f]{16}-0[1-9a-f]$")
TRACESTATE: Final = "runtime=zenoh"
DISCOVERY_TIMEOUT_SEC: Final = 120.0


def clock_identity() -> dict[str, object]:
    clock = time.get_clock_info("time")
    return {
        "authority": "shared-linux-kernel-clock-realtime",
        "boot_id": Path("/proc/sys/kernel/random/boot_id")
        .read_text(encoding="ascii")
        .strip(),
        "implementation": clock.implementation,
        "resolution_sec": clock.resolution,
    }


def required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise RuntimeError(f"{name} is required")
    return value


def positive_integer_environment(name: str) -> int:
    value = int(required_environment(name))
    if value < 1:
        raise RuntimeError(f"{name} must be positive")
    return value


def iso8601_now() -> str:
    return datetime.now(UTC).isoformat().replace("+00:00", "Z")


def qos_profile() -> QoSProfile:
    return QoSProfile(
        history=HistoryPolicy.KEEP_LAST,
        depth=100,
        reliability=ReliabilityPolicy.RELIABLE,
        durability=DurabilityPolicy.VOLATILE,
    )


def configure_telemetry(domain_id: str, run_id: str) -> TracerProvider:
    provider = TracerProvider(
        resource=Resource.create(
            {
                "service.name": f"robotics-zenoh-{domain_id}",
                "service.namespace": "robotics-runtime",
                "run.id": run_id,
                "domain.id": domain_id,
            }
        )
    )
    endpoint = required_environment("OTEL_EXPORTER_OTLP_ENDPOINT")
    provider.add_span_processor(
        BatchSpanProcessor(
            OTLPSpanExporter(endpoint=f"{endpoint.rstrip('/')}/v1/traces")
        )
    )
    trace.set_tracer_provider(provider)
    return provider


def endpoint_type_hash(node: Node, topic: str, *, publishers: bool) -> str:
    endpoints = (
        node.get_publishers_info_by_topic(topic)
        if publishers
        else node.get_subscriptions_info_by_topic(topic)
    )
    hashes = {
        str(endpoint.topic_type_hash)
        for endpoint in endpoints
        if endpoint.topic_type == MESSAGE_TYPE
    }
    if len(hashes) != 1:
        raise RuntimeError(
            f"{topic} must expose one valid {MESSAGE_TYPE} type hash; observed {hashes}"
        )
    value = hashes.pop()
    if not re.fullmatch(r"RIHS01_[0-9a-f]{64}", value):
        raise RuntimeError(f"{topic} exposes invalid type hash {value!r}")
    return value


def write_observation(path: Path, observation: dict[str, Any]) -> None:
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(f"{path.suffix}.tmp")
    temporary.write_text(
        json.dumps(observation, indent=2, sort_keys=True) + "\n",
        encoding="utf-8",
    )
    temporary.replace(path)


def wait_for_subscriber(node: Node, topic: str, timeout_sec: float) -> int:
    deadline = time.monotonic() + timeout_sec
    while time.monotonic() < deadline:
        count = node.count_subscribers(topic)
        if count >= 1:
            return count
        rclpy.spin_once(node, timeout_sec=0.1)
    raise RuntimeError(f"{topic} has no matched subscriber after {timeout_sec} seconds")


def publish(node: Node, tracer: trace.Tracer, topic: str, count: int) -> dict[str, Any]:
    publisher = node.create_publisher(TraceContext, topic, qos_profile())
    started_at = iso8601_now()
    subscriber_count = wait_for_subscriber(node, topic, DISCOVERY_TIMEOUT_SEC)
    traceparents: set[str] = set()
    first_message_at_ns: int | None = None

    for _ in range(count):
        trace_id = secrets.randbits(128) or 1
        parent = SpanContext(
            trace_id=trace_id,
            span_id=secrets.randbits(64) or 1,
            is_remote=False,
            trace_flags=TraceFlags(TraceFlags.SAMPLED),
            trace_state=TraceState([("runtime", "zenoh")]),
        )
        parent_context = set_span_in_context(NonRecordingSpan(parent))
        message_id = f"zenoh-{trace_id:032x}"
        with tracer.start_as_current_span(
            PRODUCER_SPAN,
            context=parent_context,
            kind=SpanKind.PRODUCER,
            attributes={
                "messaging.message.id": message_id,
                "messaging.system": "zenoh",
                "messaging.destination.name": topic,
                "messaging.operation.name": "publish",
                "messaging.operation.type": "send",
            },
        ):
            message = inject_context()
            traceparent = message.traceparent
            tracestate = message.tracestate
            if not TRACEPARENT_PATTERN.fullmatch(traceparent):
                raise RuntimeError(f"invalid injected traceparent {traceparent!r}")
            if tracestate != TRACESTATE:
                raise RuntimeError(f"invalid injected tracestate {tracestate!r}")
            publisher.publish(message)
            if first_message_at_ns is None:
                first_message_at_ns = time.time_ns()
            traceparents.add(traceparent)
        time.sleep(0.02)

    if len(traceparents) != count:
        raise RuntimeError("producer traceparent values are not unique")
    if first_message_at_ns is None:
        raise RuntimeError("publisher emitted no messages")
    return {
        "schema_version": "zenoh-probe-observation.v1",
        "role": "source",
        "started_at": started_at,
        "finished_at": iso8601_now(),
        "topic": topic,
        "message_type": MESSAGE_TYPE,
        "type_hash": endpoint_type_hash(node, topic, publishers=True),
        "publishers": node.count_publishers(topic),
        "subscribers": subscriber_count,
        "published_count": count,
        "received_count": 0,
        "unique_traceparent_count": len(traceparents),
        "matched_tracestate_count": count,
        "first_message_at_ns": first_message_at_ns,
        "clock_identity": clock_identity(),
    }


def subscribe(
    node: Node, tracer: trace.Tracer, topic: str, count: int
) -> dict[str, Any]:
    received = 0
    traceparents: set[str] = set()
    matched_tracestate = 0
    first_message_at_ns: int | None = None
    started_at = iso8601_now()

    def receive(message: TraceContext) -> None:
        nonlocal first_message_at_ns, matched_tracestate, received
        if not TRACEPARENT_PATTERN.fullmatch(message.traceparent):
            raise RuntimeError(f"invalid received traceparent {message.traceparent!r}")
        if message.tracestate != TRACESTATE:
            raise RuntimeError(f"invalid received tracestate {message.tracestate!r}")
        context = extract_context(message)
        parent = trace.get_current_span(context).get_span_context()
        if not parent.is_valid or not parent.is_remote:
            raise RuntimeError("received Trace Context did not produce a remote parent")
        message_id = f"zenoh-{parent.trace_id:032x}"
        with tracer.start_as_current_span(
            CONSUMER_SPAN,
            context=context,
            kind=SpanKind.CONSUMER,
            attributes={
                "messaging.message.id": message_id,
                "messaging.system": "zenoh",
                "messaging.destination.name": topic,
                "messaging.operation.name": "receive",
                "messaging.operation.type": "receive",
            },
        ):
            pass
        received += 1
        traceparents.add(message.traceparent)
        matched_tracestate += 1
        if first_message_at_ns is None:
            first_message_at_ns = time.time_ns()

    subscription = node.create_subscription(
        TraceContext,
        topic,
        receive,
        qos_profile(),
    )
    deadline = time.monotonic() + DISCOVERY_TIMEOUT_SEC
    reached_at: float | None = None
    while time.monotonic() < deadline:
        rclpy.spin_once(node, timeout_sec=0.1)
        if len(traceparents) >= count and reached_at is None:
            reached_at = time.monotonic()
        if reached_at is not None and time.monotonic() - reached_at >= 1.0:
            break

    if received != count:
        raise RuntimeError(f"received {received} messages; expected exactly {count}")
    if len(traceparents) != count:
        raise RuntimeError(
            f"received {len(traceparents)} unique traceparents; expected {count}"
        )
    if matched_tracestate != count:
        raise RuntimeError(
            f"matched {matched_tracestate} tracestate values; expected {count}"
        )
    if first_message_at_ns is None:
        raise RuntimeError("subscriber observed no messages")

    observation = {
        "schema_version": "zenoh-probe-observation.v1",
        "role": "destination",
        "started_at": started_at,
        "finished_at": iso8601_now(),
        "topic": topic,
        "message_type": MESSAGE_TYPE,
        "type_hash": endpoint_type_hash(node, topic, publishers=False),
        "publishers": node.count_publishers(topic),
        "subscribers": node.count_subscribers(topic),
        "published_count": 0,
        "received_count": received,
        "unique_traceparent_count": len(traceparents),
        "matched_tracestate_count": matched_tracestate,
        "first_message_at_ns": first_message_at_ns,
        "clock_identity": clock_identity(),
    }
    node.destroy_subscription(subscription)
    return observation


def parser() -> argparse.ArgumentParser:
    command = argparse.ArgumentParser(
        description="Emit correlated ROS 2 and OpenTelemetry evidence for Zenoh."
    )
    command.add_argument("role", choices=("publish", "subscribe"))
    return command


def main() -> None:
    arguments = parser().parse_args()
    run_id = required_environment("ROBOTICS_RUN_ID")
    domain_id = required_environment("ROBOTICS_DOMAIN_ID")
    topic = required_environment("ROBOTICS_TOPIC")
    count = positive_integer_environment("ROBOTICS_MESSAGE_COUNT")
    output = Path(required_environment("ROBOTICS_OBSERVATION_PATH"))
    provider = configure_telemetry(domain_id, run_id)
    tracer = provider.get_tracer("robotics.zenoh.qualification")
    rclpy.init()
    node: Node | None = None
    observation: dict[str, Any] | None = None
    try:
        node = rclpy.create_node(
            f"zenoh_{arguments.role}_{domain_id.replace('-', '_')}"
        )
        observation = (
            publish(node, tracer, topic, count)
            if arguments.role == "publish"
            else subscribe(node, tracer, topic, count)
        )
        observation["run_id"] = run_id
        observation["domain_id"] = domain_id
    finally:
        if node is not None:
            node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()
        if not provider.force_flush(timeout_millis=10_000):
            raise RuntimeError("OpenTelemetry span flush timed out")
        provider.shutdown()
    if observation is None:
        raise RuntimeError("Zenoh probe produced no observation")
    write_observation(output, observation)


if __name__ == "__main__":
    main()
