from __future__ import annotations

from collections.abc import Mapping

from opentelemetry.context import Context
from opentelemetry.propagators.textmap import Getter
from opentelemetry.trace.propagation.tracecontext import TraceContextTextMapPropagator
from robotics_observability_msgs.msg import TraceContext

_PROPAGATOR = TraceContextTextMapPropagator()


class _MessageGetter(Getter[TraceContext]):
    def get(self, carrier: TraceContext, key: str) -> list[str] | None:
        value = getattr(carrier, key, "")
        return [value] if value else None

    def keys(self, carrier: TraceContext) -> list[str]:
        return [
            key for key in ("traceparent", "tracestate") if getattr(carrier, key, "")
        ]


def inject_context(context: Context | None = None) -> TraceContext:
    """Serialize the selected OpenTelemetry context into a bounded ROS message."""

    carrier: dict[str, str] = {}
    _PROPAGATOR.inject(carrier, context=context)
    return TraceContext(
        traceparent=carrier.get("traceparent", ""),
        tracestate=carrier.get("tracestate", ""),
    )


def extract_context(message: TraceContext, context: Context | None = None) -> Context:
    """Extract W3C Trace Context from a ROS message without changing ambient state."""

    return _PROPAGATOR.extract(
        carrier=message,
        context=context,
        getter=_MessageGetter(),
    )


def as_mapping(message: TraceContext) -> Mapping[str, str]:
    """Return the non-empty wire fields for diagnostics and tests."""

    return {
        key: value
        for key, value in (
            ("traceparent", message.traceparent),
            ("tracestate", message.tracestate),
        )
        if value
    }


__all__ = ["as_mapping", "extract_context", "inject_context"]
