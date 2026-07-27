from __future__ import annotations

from dataclasses import dataclass
from typing import Any, Mapping


@dataclass(frozen=True, slots=True)
class MessageMeasurement:
    age_ms: float | None
    loss_ratio: float | None


class MessageStream:
    """Measure transport age and sequence gaps from ROS subscription metadata."""

    def __init__(self) -> None:
        self._last_sequence: int | None = None
        self._received_count = 0
        self._lost_count = 0

    def observe(self, metadata: Mapping[str, Any]) -> MessageMeasurement:
        source_timestamp = _positive_int(metadata.get("source_timestamp"))
        received_timestamp = _positive_int(metadata.get("received_timestamp"))
        age_ms = None
        if (
            source_timestamp is not None
            and received_timestamp is not None
            and received_timestamp >= source_timestamp
        ):
            age_ms = (received_timestamp - source_timestamp) / 1_000_000

        sequence = _optional_int(metadata.get("publication_sequence_number"))
        if sequence is None:
            sequence = _optional_int(metadata.get("reception_sequence_number"))

        loss_ratio = None
        if sequence is not None:
            if self._last_sequence is not None and sequence > self._last_sequence:
                self._lost_count += max(sequence - self._last_sequence - 1, 0)
            if self._last_sequence is None or sequence > self._last_sequence:
                self._last_sequence = sequence
            self._received_count += 1
            loss_ratio = self._lost_count / (self._received_count + self._lost_count)

        return MessageMeasurement(age_ms=age_ms, loss_ratio=loss_ratio)


def clock_offset_ms(authority_time_ns: int, observed_time_ns: int) -> float:
    return abs(observed_time_ns - authority_time_ns) / 1_000_000


def _positive_int(value: object) -> int | None:
    observed = _optional_int(value)
    return observed if observed is not None and observed > 0 else None


def _optional_int(value: object) -> int | None:
    if isinstance(value, bool) or not isinstance(value, int):
        return None
    return value


__all__ = ["MessageMeasurement", "MessageStream", "clock_offset_ms"]
