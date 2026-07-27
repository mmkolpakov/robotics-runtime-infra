from robotics_observability.measurements import MessageStream, clock_offset_ms


def test_message_stream_measures_age_and_sequence_gaps() -> None:
    stream = MessageStream()

    first = stream.observe(
        {
            "source_timestamp": 1_000_000_000,
            "received_timestamp": 1_002_000_000,
            "publication_sequence_number": 40,
        }
    )
    second = stream.observe(
        {
            "source_timestamp": 2_000_000_000,
            "received_timestamp": 2_003_000_000,
            "publication_sequence_number": 42,
        }
    )

    assert first.age_ms == 2
    assert first.loss_ratio == 0
    assert second.age_ms == 3
    assert second.loss_ratio == 1 / 3


def test_message_stream_fails_closed_for_unsupported_metadata() -> None:
    measurement = MessageStream().observe(
        {
            "source_timestamp": 0,
            "received_timestamp": 0,
            "publication_sequence_number": None,
            "reception_sequence_number": None,
        }
    )

    assert measurement.age_ms is None
    assert measurement.loss_ratio is None


def test_message_stream_does_not_inflate_loss_after_out_of_order_delivery() -> None:
    stream = MessageStream()

    stream.observe({"publication_sequence_number": 10})
    stream.observe({"publication_sequence_number": 8})
    measurement = stream.observe({"publication_sequence_number": 11})

    assert measurement.loss_ratio == 0


def test_clock_offset_is_absolute_milliseconds() -> None:
    assert clock_offset_ms(10_000_000, 12_500_000) == 2.5
    assert clock_offset_ms(12_500_000, 10_000_000) == 2.5
