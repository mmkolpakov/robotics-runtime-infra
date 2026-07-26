from opentelemetry import trace
from opentelemetry.trace import (
    NonRecordingSpan,
    SpanContext,
    TraceFlags,
    TraceState,
    set_span_in_context,
)
from robotics_observability import extract_context, inject_context


def test_w3c_trace_context_round_trip() -> None:
    source = SpanContext(
        trace_id=int("0123456789abcdef0123456789abcdef", 16),
        span_id=int("0123456789abcdef", 16),
        is_remote=False,
        trace_flags=TraceFlags.SAMPLED,
        trace_state=TraceState([("vendor", "value")]),
    )
    message = inject_context(set_span_in_context(NonRecordingSpan(source)))

    assert message.traceparent == (
        "00-0123456789abcdef0123456789abcdef-0123456789abcdef-01"
    )
    assert message.tracestate == "vendor=value"

    extracted = trace.get_current_span(extract_context(message)).get_span_context()
    assert extracted.trace_id == source.trace_id
    assert extracted.span_id == source.span_id
    assert extracted.is_remote
    assert extracted.trace_state == source.trace_state
