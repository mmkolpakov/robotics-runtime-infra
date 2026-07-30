from __future__ import annotations

import os
from collections.abc import Mapping
from typing import Any, Callable

import rclpy
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import Counter, Histogram, MeterProvider
from opentelemetry.sdk.metrics.export import (
    AggregationTemporality,
    PeriodicExportingMetricReader,
)
from opentelemetry.sdk.metrics.view import (
    ExplicitBucketHistogramAggregation,
    View,
)
from opentelemetry.sdk.resources import Resource
from rclpy.node import Node
from rclpy.qos import QoSProfile, ReliabilityPolicy, qos_profile_sensor_data
from rosgraph_msgs.msg import Clock
from std_msgs.msg import UInt64

from robotics_observability.measurements import (
    MessageStream,
    source_to_reception_latency_ms,
)


LATENCY_BUCKETS_MS = (
    0.0,
    0.1,
    0.25,
    0.5,
    1.0,
    1.5,
    2.0,
    2.5,
    5.0,
    10.0,
    25.0,
    50.0,
    100.0,
    250.0,
    500.0,
    1_000.0,
)
RMW_LATENCY_METHOD = "rmw_source_to_reception_latency"
SINGLE_PUBLISHER_SEQUENCE_METHOD = "rmw_publication_sequence_single_publisher"


class RuntimeMetrics(Node):
    """Measure RMW delivery timing and sequence gaps without altering the graph."""

    def __init__(
        self,
        provider: MeterProvider,
        *,
        run_id: str | None = None,
        domain_id: str | None = None,
        publisher_count: Callable[[], int] | None = None,
    ) -> None:
        super().__init__("robotics_runtime_metrics")
        self._data_topic = _required_environment("ROBOTICS_METRICS_TOPIC")
        self._time_topic = _required_environment("ROBOTICS_TIME_TOPIC")
        self._source_id = _required_environment("ROBOTICS_TIME_SOURCE_ID")
        self._common_attributes = {
            "run.id": run_id or _required_environment("ROBOTICS_RUN_ID"),
            "domain.id": domain_id or _required_environment("ROBOTICS_DOMAIN_ID"),
        }
        self._stream = MessageStream()
        self._missing_time_metadata_logged = False
        self._missing_age_logged = False
        self._missing_sequence_logged = False

        meter = provider.get_meter("robotics.runtime.ros", "1.0.0")
        self._delivery_latency = meter.create_histogram(
            "robotics.time_authority.delivery_latency",
            unit="ms",
            description=(
                "DDS/RMW source-to-reception latency for messages from the "
                "declared ROS time authority."
            ),
        )
        self._message_age = meter.create_histogram(
            "robotics.message.age",
            unit="ms",
            description="DDS source-to-reception latency for a ROS message.",
        )
        self._messages_received = meter.create_counter(
            "robotics.message.received",
            unit="{message}",
            description="ROS messages received with supported DDS sequence metadata.",
        )
        self._messages_lost = meter.create_counter(
            "robotics.message.lost",
            unit="{message}",
            description="ROS messages inferred lost from DDS sequence gaps.",
        )
        self._sequence_errors = meter.create_counter(
            "robotics.message.sequence_error",
            unit="{message}",
            description=(
                "ROS messages with unavailable, duplicate, or non-monotonic "
                "DDS publication sequence metadata."
            ),
        )
        self.create_subscription(
            Clock,
            self._time_topic,
            self._observe_clock,
            qos_profile_sensor_data,
        )
        self._data_subscription = self.create_subscription(
            UInt64,
            self._data_topic,
            self._observe_data,
            QoSProfile(depth=100, reliability=ReliabilityPolicy.RELIABLE),
        )
        self._publisher_count = (
            publisher_count
            if publisher_count is not None
            else self._data_subscription.get_publisher_count
        )

    def _observe_clock(
        self,
        _message: Clock,
        metadata: Mapping[str, Any],
    ) -> None:
        latency_ms = source_to_reception_latency_ms(metadata)
        if latency_ms is None:
            if not self._missing_time_metadata_logged:
                self.get_logger().error(
                    "DDS source or reception timestamps are unavailable for the "
                    "declared time authority; time-authority evidence will remain absent"
                )
                self._missing_time_metadata_logged = True
            return
        self._delivery_latency.record(
            latency_ms,
            {
                **self._common_attributes,
                "channel": self._time_topic,
                "time.measurement.method": RMW_LATENCY_METHOD,
                "time.source.id": self._source_id,
            },
        )

    def _observe_data(
        self,
        _message: UInt64,
        metadata: Mapping[str, Any],
    ) -> None:
        measurement = self._stream.observe(
            metadata,
            publisher_count=self._publisher_count(),
        )
        channel_attributes = {
            **self._common_attributes,
            "channel": self._data_topic,
        }
        sequence_attributes = {
            **channel_attributes,
            "sequence.measurement.method": SINGLE_PUBLISHER_SEQUENCE_METHOD,
        }
        if measurement.age_ms is None:
            if not self._missing_age_logged:
                self.get_logger().error(
                    "DDS source or reception timestamps are unavailable; "
                    "message-age evidence will remain absent"
                )
                self._missing_age_logged = True
        else:
            self._message_age.record(measurement.age_ms, channel_attributes)

        self._sequence_errors.add(
            measurement.sequence_error_delta,
            sequence_attributes,
        )
        if measurement.received_delta is None or measurement.lost_delta is None:
            if not self._missing_sequence_logged:
                self.get_logger().error(
                    "DDS publication sequence numbers are unavailable or the "
                    "measured channel does not have exactly one publisher; "
                    "delivery evidence will remain absent"
                )
                self._missing_sequence_logged = True
            return
        self._messages_received.add(
            measurement.received_delta,
            sequence_attributes,
        )
        self._messages_lost.add(
            measurement.lost_delta,
            sequence_attributes,
        )


def metric_temporality() -> dict[type, AggregationTemporality]:
    return {
        Counter: AggregationTemporality.DELTA,
        Histogram: AggregationTemporality.DELTA,
    }


def metric_views() -> tuple[View, ...]:
    latency_aggregation = ExplicitBucketHistogramAggregation(
        boundaries=LATENCY_BUCKETS_MS,
        record_min_max=True,
    )
    return (
        View(
            instrument_name="robotics.time_authority.delivery_latency",
            aggregation=latency_aggregation,
        ),
        View(
            instrument_name="robotics.message.age",
            aggregation=ExplicitBucketHistogramAggregation(
                boundaries=LATENCY_BUCKETS_MS,
                record_min_max=True,
            ),
        ),
    )


def _required_environment(name: str) -> str:
    value = os.environ.get(name, "").strip()
    if not value:
        raise ValueError(f"{name} is required")
    return value


def _positive_environment_integer(name: str, default: int) -> int:
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError as error:
        raise ValueError(f"{name} must be an integer") from error
    if value <= 0:
        raise ValueError(f"{name} must be positive")
    return value


def main() -> int:
    run_id = _required_environment("ROBOTICS_RUN_ID")
    domain_id = _required_environment("ROBOTICS_DOMAIN_ID")
    exporter = OTLPMetricExporter(
        endpoint=_required_environment("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"),
        preferred_temporality=metric_temporality(),
    )
    reader = PeriodicExportingMetricReader(
        exporter,
        export_interval_millis=_positive_environment_integer(
            "ROBOTICS_METRICS_EXPORT_INTERVAL_MS",
            100,
        ),
        export_timeout_millis=5_000,
    )
    provider = MeterProvider(
        resource=Resource.create(
            {
                "service.name": "robotics-runtime-metrics",
                "run.id": run_id,
                "domain.id": domain_id,
            }
        ),
        metric_readers=[reader],
        views=metric_views(),
    )
    rclpy.init()
    node = RuntimeMetrics(provider, run_id=run_id, domain_id=domain_id)
    try:
        rclpy.spin(node)
    finally:
        node.destroy_node()
        if rclpy.ok():
            rclpy.shutdown()
        provider.shutdown()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
