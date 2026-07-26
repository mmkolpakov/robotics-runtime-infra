# Record Telemetry as Verifiable Evidence

- Status: accepted
- Date: 2026-07-26

## Context and Problem Statement

Container exit codes and screenshots cannot prove which runtime, ROS graph,
sensor stream, or cross-domain message path was evaluated.

## Decision Drivers

- Keep evidence machine-readable and independently hashable.
- Use standard telemetry and robotics recording formats.
- Separate evidence collection from verdict calculation.

## Considered Options

- Parse service logs into a custom report.
- Store only rosbag2 recordings.
- Combine MCAP, OTLP, runtime manifests, and versioned evidence indexes.

## Decision Outcome

rosbag2 uses MCAP with Zstd for ROS data. The official OpenTelemetry Collector
receives OTLP metrics and traces and writes separate files. The evidence sink
validates MCAP, computes summaries through the MCAP API, registers all
artifacts by digest, and finalizes a versioned evidence index. The acceptance
harness reads evidence but does not control the running graph.

Trace propagation uses W3C Trace Context through a dedicated ROS message and
the OpenTelemetry propagator. Cross-domain messaging supports both parent and
link relationships according to OpenTelemetry messaging semantics.

## Consequences

- Missing or dropped mandatory evidence produces `incomplete`, not `passed`.
- Artifact retention and remote storage remain external lifecycle policies.
- The evidence index is finalized before a verdict is accepted.
