from robotics_observability.measurements import (
    MessageStream,
    source_to_reception_latency_ms,
)


def test_message_stream_measures_age_and_sequence_gaps() -> None:
    stream = MessageStream()

    first = stream.observe(
        {
            "source_timestamp": 1_000_000_000,
            "received_timestamp": 1_002_000_000,
            "publication_sequence_number": 40,
        },
        publisher_count=1,
    )
    second = stream.observe(
        {
            "source_timestamp": 2_000_000_000,
            "received_timestamp": 2_003_000_000,
            "publication_sequence_number": 42,
        },
        publisher_count=1,
    )

    assert first.age_ms == 2
    assert first.received_delta == 1
    assert first.lost_delta == 0
    assert first.sequence_error_delta == 0
    assert second.age_ms == 3
    assert second.received_delta == 1
    assert second.lost_delta == 1
    assert second.sequence_error_delta == 0


def test_message_stream_fails_closed_for_unsupported_metadata() -> None:
    measurement = MessageStream().observe(
        {
            "source_timestamp": 0,
            "received_timestamp": 0,
            "publication_sequence_number": None,
            "reception_sequence_number": None,
        },
        publisher_count=1,
    )

    assert measurement.age_ms is None
    assert measurement.received_delta is None
    assert measurement.lost_delta is None
    assert measurement.sequence_error_delta == 1


def test_message_stream_marks_out_of_order_delivery_as_invalid() -> None:
    stream = MessageStream()

    stream.observe({"publication_sequence_number": 10}, publisher_count=1)
    out_of_order = stream.observe(
        {"publication_sequence_number": 8},
        publisher_count=1,
    )
    measurement = stream.observe(
        {"publication_sequence_number": 11},
        publisher_count=1,
    )

    assert out_of_order.received_delta == 0
    assert out_of_order.lost_delta == 0
    assert out_of_order.sequence_error_delta == 1
    assert measurement.received_delta == 1
    assert measurement.lost_delta == 0
    assert measurement.sequence_error_delta == 0


def test_message_stream_does_not_count_duplicate_as_received() -> None:
    stream = MessageStream()

    first = stream.observe(
        {"publication_sequence_number": 10},
        publisher_count=1,
    )
    duplicate = stream.observe(
        {"publication_sequence_number": 10},
        publisher_count=1,
    )

    assert first.received_delta == 1
    assert first.sequence_error_delta == 0
    assert duplicate.received_delta == 0
    assert duplicate.lost_delta == 0
    assert duplicate.sequence_error_delta == 1


def test_source_to_reception_latency_uses_independent_rmw_timestamps() -> None:
    assert (
        source_to_reception_latency_ms(
            {
                "source_timestamp": 10_000_000,
                "received_timestamp": 12_500_000,
            }
        )
        == 2.5
    )


def test_source_to_reception_latency_fails_closed() -> None:
    unsupported = [
        {"source_timestamp": None, "received_timestamp": 12_500_000},
        {"source_timestamp": 0, "received_timestamp": 12_500_000},
        {"source_timestamp": 12_500_000, "received_timestamp": None},
        {"source_timestamp": 12_500_000, "received_timestamp": 0},
        {"source_timestamp": 12_500_000, "received_timestamp": 10_000_000},
    ]

    assert all(
        source_to_reception_latency_ms(metadata) is None for metadata in unsupported
    )


def test_message_stream_rejects_rmw_unsupported_sequence_sentinel() -> None:
    measurement = MessageStream().observe(
        {
            "publication_sequence_number": (1 << 64) - 1,
            "reception_sequence_number": None,
        },
        publisher_count=1,
    )

    assert measurement.received_delta is None
    assert measurement.lost_delta is None
    assert measurement.sequence_error_delta == 1


def test_message_stream_does_not_treat_reception_sequence_as_loss_evidence() -> None:
    measurement = MessageStream().observe(
        {
            "publication_sequence_number": None,
            "reception_sequence_number": 12,
        },
        publisher_count=1,
    )

    assert measurement.received_delta is None
    assert measurement.lost_delta is None
    assert measurement.sequence_error_delta == 1


def test_message_stream_rejects_a_multi_publisher_channel() -> None:
    measurement = MessageStream().observe(
        {"publication_sequence_number": 1},
        publisher_count=2,
    )

    assert measurement.received_delta is None
    assert measurement.lost_delta is None
    assert measurement.sequence_error_delta == 1
