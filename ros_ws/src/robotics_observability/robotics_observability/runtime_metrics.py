from __future__ import annotations

import os
from collections.abc import Mapping
from typing import Any

import rclpy
from opentelemetry.exporter.otlp.proto.http.metric_exporter import OTLPMetricExporter
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import PeriodicExportingMetricReader
from opentelemetry.sdk.resources import Resource
from rclpy.node import Node
from rclpy.parameter import Parameter
from rclpy.qos import QoSProfile, ReliabilityPolicy, qos_profile_sensor_data
from rosgraph_msgs.msg import Clock
from std_msgs.msg import UInt64

from robotics_observability.measurements import MessageStream, clock_offset_ms


class RuntimeMetrics(Node):
    """Measure the active ROS clock and transport without altering the graph."""

    def __init__(self, provider: MeterProvider) -> None:
        super().__init__(
            "robotics_runtime_metrics",
            parameter_overrides=[Parameter("use_sim_time", value=True)],
            automatically_declare_parameters_from_overrides=True,
        )
        self._data_topic = _required_environment("ROBOTICS_METRICS_TOPIC")
        self._time_topic = _required_environment("ROBOTICS_TIME_TOPIC")
        self._source_id = _required_environment("ROBOTICS_TIME_SOURCE_ID")
        self._stream = MessageStream()
        self._missing_age_logged = False
        self._missing_sequence_logged = False

        meter = provider.get_meter("robotics.runtime.ros", "1.0.0")
        self._offset = meter.create_gauge(
            "robotics.time_authority.offset",
            unit="ms",
            description="Absolute offset from the declared ROS time authority.",
        )
        self._message_age = meter.create_gauge(
            "robotics.message.age",
            unit="ms",
            description="DDS source-to-reception latency for a ROS message.",
        )
        self._loss_ratio = meter.create_gauge(
            "robotics.message.loss_ratio",
            unit="1",
            description="Cumulative sequence-gap ratio for a ROS message stream.",
        )
        self.create_subscription(
            Clock,
            self._time_topic,
            self._observe_clock,
            qos_profile_sensor_data,
        )
        self.create_subscription(
            UInt64,
            self._data_topic,
            self._observe_data,
            QoSProfile(depth=100, reliability=ReliabilityPolicy.RELIABLE),
        )

    def _observe_clock(
        self,
        message: Clock,
        _metadata: Mapping[str, Any],
    ) -> None:
        authority_time_ns = message.clock.sec * 1_000_000_000 + message.clock.nanosec
        ros_clock = self.get_clock()
        if ros_clock.ros_time_is_active:
            self._offset.set(
                clock_offset_ms(authority_time_ns, ros_clock.now().nanoseconds),
                {"time.source.id": self._source_id},
            )

    def _observe_data(
        self,
        _message: UInt64,
        metadata: Mapping[str, Any],
    ) -> None:
        measurement = self._stream.observe(metadata)
        channel_attributes = {"channel": self._data_topic}
        if measurement.age_ms is None:
            if not self._missing_age_logged:
                self.get_logger().error(
                    "DDS source or reception timestamps are unavailable; "
                    "message-age evidence will remain absent"
                )
                self._missing_age_logged = True
        else:
            self._message_age.set(measurement.age_ms, channel_attributes)

        if measurement.loss_ratio is None:
            if not self._missing_sequence_logged:
                self.get_logger().error(
                    "DDS publication and reception sequence numbers are unavailable; "
                    "loss evidence will remain absent"
                )
                self._missing_sequence_logged = True
        else:
            self._loss_ratio.set(measurement.loss_ratio, channel_attributes)


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
    exporter = OTLPMetricExporter(
        endpoint=_required_environment("OTEL_EXPORTER_OTLP_METRICS_ENDPOINT"),
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
        resource=Resource.create({"service.name": "robotics-runtime-metrics"}),
        metric_readers=[reader],
    )
    rclpy.init()
    node = RuntimeMetrics(provider)
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
