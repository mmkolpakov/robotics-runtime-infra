from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping


RMW_UNSUPPORTED_SEQUENCE_NUMBER = (1 << 64) - 1


@dataclass(frozen=True, slots=True)
class MessageMeasurement:
    age_ms: float | None
    received_delta: int | None
    lost_delta: int | None
    sequence_error_delta: int


class MessageStream:
    """Measure sequence gaps when one publisher owns the observed channel."""

    def __init__(self) -> None:
        self._last_sequence: int | None = None

    def observe(
        self,
        metadata: Mapping[str, Any],
        *,
        publisher_count: int,
    ) -> MessageMeasurement:
        age_ms = source_to_reception_latency_ms(metadata)
        sequence = _sequence_number(metadata.get("publication_sequence_number"))
        if publisher_count != 1 or sequence is None:
            return MessageMeasurement(
                age_ms=age_ms,
                received_delta=None,
                lost_delta=None,
                sequence_error_delta=1,
            )

        last_sequence = self._last_sequence
        if last_sequence is not None and sequence <= last_sequence:
            return MessageMeasurement(
                age_ms=age_ms,
                received_delta=0,
                lost_delta=0,
                sequence_error_delta=1,
            )
        lost_delta = 0
        if last_sequence is not None:
            lost_delta = max(sequence - last_sequence - 1, 0)
        self._last_sequence = sequence
        return MessageMeasurement(
            age_ms=age_ms,
            received_delta=1,
            lost_delta=lost_delta,
            sequence_error_delta=0,
        )


def source_to_reception_latency_ms(metadata: Mapping[str, Any]) -> float | None:
    """Return DDS/RMW source-to-reception latency, or no evidence."""

    source_timestamp = _positive_int(metadata.get("source_timestamp"))
    received_timestamp = _positive_int(metadata.get("received_timestamp"))
    if (
        source_timestamp is None
        or received_timestamp is None
        or received_timestamp < source_timestamp
    ):
        return None
    return (received_timestamp - source_timestamp) / 1_000_000


def _positive_int(value: object) -> int | None:
    observed = _optional_int(value)
    return observed if observed is not None and observed > 0 else None


def _optional_int(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


def _sequence_number(value: object) -> int | None:
    sequence = _optional_int(value)
    if sequence is None or sequence < 0 or sequence == RMW_UNSUPPORTED_SEQUENCE_NUMBER:
        return None
    return sequence


__all__ = [
    "MessageMeasurement",
    "MessageStream",
    "source_to_reception_latency_ms",
]
