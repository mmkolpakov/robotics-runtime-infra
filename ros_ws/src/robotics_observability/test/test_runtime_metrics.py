from __future__ import annotations

from collections.abc import Iterator

import pytest
import rclpy
from opentelemetry.sdk.metrics import MeterProvider
from opentelemetry.sdk.metrics.export import (
    AggregationTemporality,
    Histogram,
    InMemoryMetricReader,
    MetricsData,
    Sum,
)
from opentelemetry.sdk.resources import Resource
from rosgraph_msgs.msg import Clock
from std_msgs.msg import UInt64

from robotics_observability.runtime_metrics import (
    LATENCY_BUCKETS_MS,
    RMW_LATENCY_METHOD,
    SINGLE_PUBLISHER_SEQUENCE_METHOD,
    RuntimeMetrics,
    metric_temporality,
    metric_views,
)


@pytest.fixture
def runtime_metrics(
    monkeypatch: pytest.MonkeyPatch,
) -> Iterator[tuple[RuntimeMetrics, MeterProvider, InMemoryMetricReader]]:
    monkeypatch.setenv("ROBOTICS_METRICS_TOPIC", "/robotics/runtime_probe")
    monkeypatch.setenv("ROBOTICS_TIME_TOPIC", "/clock")
    monkeypatch.setenv("ROBOTICS_TIME_SOURCE_ID", "gazebo-clock")
    reader = InMemoryMetricReader(
        preferred_temporality=metric_temporality(),
    )
    provider = MeterProvider(
        resource=Resource.create(
            {
                "service.name": "robotics-runtime-metrics-test",
                "run.id": "run-test",
                "domain.id": "primary",
            }
        ),
        metric_readers=[reader],
        shutdown_on_exit=False,
        views=metric_views(),
    )
    rclpy.init()
    node = RuntimeMetrics(
        provider,
        run_id="run-test",
        domain_id="primary",
        publisher_count=lambda: 1,
    )
    try:
        yield node, provider, reader
    finally:
        node.destroy_node()
        provider.shutdown()
        if rclpy.ok():
            rclpy.shutdown()


def _metrics_by_name(metrics_data: MetricsData) -> dict[str, object]:
    return {
        metric.name: metric.data
        for resource_metrics in metrics_data.resource_metrics
        for scope_metrics in resource_metrics.scope_metrics
        for metric in scope_metrics.metrics
        if metric.name.startswith("robotics.")
    }


def _attributes(point: object) -> dict[str, object]:
    return dict(getattr(point, "attributes"))


def test_runtime_metrics_records_distributions_and_delivery_deltas(
    runtime_metrics: tuple[RuntimeMetrics, MeterProvider, InMemoryMetricReader],
) -> None:
    node, _provider, reader = runtime_metrics
    node._observe_clock(
        Clock(),
        {
            "source_timestamp": 1_000_000_000,
            "received_timestamp": 1_002_000_000,
        },
    )
    node._observe_clock(
        Clock(),
        {
            "source_timestamp": 2_000_000_000,
            "received_timestamp": 2_004_000_000,
        },
    )
    node._observe_data(
        UInt64(data=1),
        {
            "source_timestamp": 3_000_000_000,
            "received_timestamp": 3_003_000_000,
            "publication_sequence_number": 40,
        },
    )
    node._observe_data(
        UInt64(data=2),
        {
            "source_timestamp": 4_000_000_000,
            "received_timestamp": 4_005_000_000,
            "publication_sequence_number": 42,
        },
    )

    metrics_data = reader.get_metrics_data()
    assert metrics_data is not None
    metrics = _metrics_by_name(metrics_data)

    delivery_latency = metrics["robotics.time_authority.delivery_latency"]
    assert isinstance(delivery_latency, Histogram)
    assert delivery_latency.aggregation_temporality is AggregationTemporality.DELTA
    delivery_latency_point = delivery_latency.data_points[0]
    assert delivery_latency_point.count == 2
    assert delivery_latency_point.sum == 6
    assert delivery_latency_point.min == 2
    assert delivery_latency_point.max == 4
    assert tuple(delivery_latency_point.explicit_bounds) == LATENCY_BUCKETS_MS
    assert _attributes(delivery_latency_point) == {
        "channel": "/clock",
        "domain.id": "primary",
        "run.id": "run-test",
        "time.measurement.method": RMW_LATENCY_METHOD,
        "time.source.id": "gazebo-clock",
    }

    message_age = metrics["robotics.message.age"]
    assert isinstance(message_age, Histogram)
    assert message_age.aggregation_temporality is AggregationTemporality.DELTA
    age_point = message_age.data_points[0]
    assert age_point.count == 2
    assert age_point.sum == 8
    assert age_point.min == 3
    assert age_point.max == 5
    assert tuple(age_point.explicit_bounds) == LATENCY_BUCKETS_MS
    assert _attributes(age_point) == {
        "channel": "/robotics/runtime_probe",
        "domain.id": "primary",
        "run.id": "run-test",
    }

    received = metrics["robotics.message.received"]
    lost = metrics["robotics.message.lost"]
    sequence_errors = metrics["robotics.message.sequence_error"]
    assert isinstance(received, Sum)
    assert isinstance(lost, Sum)
    assert isinstance(sequence_errors, Sum)
    assert received.aggregation_temporality is AggregationTemporality.DELTA
    assert lost.aggregation_temporality is AggregationTemporality.DELTA
    assert received.is_monotonic
    assert lost.is_monotonic
    assert received.data_points[0].value == 2
    assert lost.data_points[0].value == 1
    assert sequence_errors.data_points[0].value == 0
    assert _attributes(received.data_points[0]) == {
        "channel": "/robotics/runtime_probe",
        "domain.id": "primary",
        "run.id": "run-test",
        "sequence.measurement.method": SINGLE_PUBLISHER_SEQUENCE_METHOD,
    }
    assert "robotics.message.loss_ratio" not in metrics


def test_invalid_clock_metadata_never_emits_synthetic_zero(
    runtime_metrics: tuple[RuntimeMetrics, MeterProvider, InMemoryMetricReader],
) -> None:
    node, _provider, reader = runtime_metrics
    node._observe_clock(
        Clock(),
        {"source_timestamp": 0, "received_timestamp": 0},
    )
    node._observe_clock(
        Clock(),
        {"source_timestamp": None, "received_timestamp": None},
    )
    node._observe_clock(
        Clock(),
        {
            "source_timestamp": 10_000_000,
            "received_timestamp": 12_000_000,
        },
    )

    metrics_data = reader.get_metrics_data()
    assert metrics_data is not None
    delivery_latency = _metrics_by_name(metrics_data)[
        "robotics.time_authority.delivery_latency"
    ]
    assert isinstance(delivery_latency, Histogram)
    point = delivery_latency.data_points[0]
    assert point.count == 1
    assert point.sum == 2
    assert point.min == 2
    assert point.max == 2


def test_high_rate_measurements_preserve_event_count(
    runtime_metrics: tuple[RuntimeMetrics, MeterProvider, InMemoryMetricReader],
) -> None:
    node, _provider, reader = runtime_metrics
    message_count = 50_000
    for sequence in range(message_count):
        source_timestamp = 1_000_000_000 + sequence * 10_000
        node._observe_data(
            UInt64(data=sequence),
            {
                "source_timestamp": source_timestamp,
                "received_timestamp": source_timestamp + (sequence % 5 + 1) * 100_000,
                "publication_sequence_number": sequence,
            },
        )

    metrics_data = reader.get_metrics_data()
    assert metrics_data is not None
    metrics = _metrics_by_name(metrics_data)
    age = metrics["robotics.message.age"]
    received = metrics["robotics.message.received"]
    lost = metrics["robotics.message.lost"]
    sequence_errors = metrics["robotics.message.sequence_error"]
    assert isinstance(age, Histogram)
    assert isinstance(received, Sum)
    assert isinstance(lost, Sum)
    assert isinstance(sequence_errors, Sum)
    assert len(age.data_points) == 1
    assert age.data_points[0].count == message_count
    assert received.data_points[0].value == message_count
    assert lost.data_points[0].value == 0
    assert sequence_errors.data_points[0].value == 0


def test_delta_metrics_do_not_replay_events_across_exports(
    runtime_metrics: tuple[RuntimeMetrics, MeterProvider, InMemoryMetricReader],
) -> None:
    node, _provider, reader = runtime_metrics
    node._observe_data(
        UInt64(data=1),
        {
            "source_timestamp": 1_000_000_000,
            "received_timestamp": 1_001_000_000,
            "publication_sequence_number": 1,
        },
    )
    first_data = reader.get_metrics_data()
    assert first_data is not None
    first = _metrics_by_name(first_data)

    node._observe_data(
        UInt64(data=2),
        {
            "source_timestamp": 2_000_000_000,
            "received_timestamp": 2_001_000_000,
            "publication_sequence_number": 2,
        },
    )
    second_data = reader.get_metrics_data()
    assert second_data is not None
    second = _metrics_by_name(second_data)

    first_age_metric = first["robotics.message.age"]
    second_age_metric = second["robotics.message.age"]
    first_received = first["robotics.message.received"]
    second_received = second["robotics.message.received"]
    assert isinstance(first_age_metric, Histogram)
    assert isinstance(second_age_metric, Histogram)
    assert isinstance(first_received, Sum)
    assert isinstance(second_received, Sum)
    first_age = first_age_metric.data_points[0]
    second_age = second_age_metric.data_points[0]
    assert first_age.count == 1
    assert second_age.count == 1
    assert first_received.data_points[0].value == 1
    assert second_received.data_points[0].value == 1
    assert first_age.time_unix_nano <= second_age.start_time_unix_nano
    assert second_age.start_time_unix_nano <= second_age.time_unix_nano


def test_runtime_metrics_records_unsupported_sequence_as_integrity_error(
    runtime_metrics: tuple[RuntimeMetrics, MeterProvider, InMemoryMetricReader],
) -> None:
    node, _provider, reader = runtime_metrics
    node._observe_data(
        UInt64(data=1),
        {
            "source_timestamp": 1_000_000_000,
            "received_timestamp": 1_001_000_000,
            "publication_sequence_number": None,
        },
    )

    metrics_data = reader.get_metrics_data()
    assert metrics_data is not None
    metrics = _metrics_by_name(metrics_data)
    assert metrics["robotics.message.sequence_error"].data_points[0].value == 1
    assert "robotics.message.received" not in metrics
    assert "robotics.message.lost" not in metrics


def test_runtime_metrics_does_not_count_duplicate_as_received(
    runtime_metrics: tuple[RuntimeMetrics, MeterProvider, InMemoryMetricReader],
) -> None:
    node, _provider, reader = runtime_metrics
    for received_timestamp in (1_001_000_000, 1_002_000_000):
        node._observe_data(
            UInt64(data=1),
            {
                "source_timestamp": 1_000_000_000,
                "received_timestamp": received_timestamp,
                "publication_sequence_number": 7,
            },
        )

    metrics_data = reader.get_metrics_data()
    assert metrics_data is not None
    metrics = _metrics_by_name(metrics_data)
    assert metrics["robotics.message.received"].data_points[0].value == 1
    assert metrics["robotics.message.lost"].data_points[0].value == 0
    assert metrics["robotics.message.sequence_error"].data_points[0].value == 1


def test_runtime_metrics_rejects_multi_publisher_loss_inference(
    runtime_metrics: tuple[RuntimeMetrics, MeterProvider, InMemoryMetricReader],
) -> None:
    node, _provider, reader = runtime_metrics
    node._publisher_count = lambda: 2
    node._observe_data(
        UInt64(data=1),
        {
            "source_timestamp": 1_000_000_000,
            "received_timestamp": 1_001_000_000,
            "publication_sequence_number": 1,
        },
    )

    metrics_data = reader.get_metrics_data()
    assert metrics_data is not None
    metrics = _metrics_by_name(metrics_data)
    sequence_error = metrics["robotics.message.sequence_error"].data_points[0]
    assert sequence_error.value == 1
    assert (
        _attributes(sequence_error)["sequence.measurement.method"]
        == SINGLE_PUBLISHER_SEQUENCE_METHOD
    )
    assert "robotics.message.received" not in metrics
    assert "robotics.message.lost" not in metrics
