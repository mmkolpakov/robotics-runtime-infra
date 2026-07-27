{
  kind: "zenoh-trace-context-smoke",
  source_domain_id: 31,
  destination_domain_id: 32,
  topic: "/robotics/trace_context",
  message_type: $message_type,
  expected_traceparent: $traceparent,
  expected_tracestate: $tracestate,
  sent_messages: $sent,
  received_messages: $received,
  matched_tracestate_messages: $states,
  minimum_messages: $minimum,
  status: (
    if $received >= $minimum and $states == $received
    then "passed"
    else "failed"
    end
  )
}
