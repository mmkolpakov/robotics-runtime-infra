# Qualify Native Domain Bridging Before Replacing Zenoh

- Status: proposed; acceptance requires both transport paths to pass CI
- Date: 2026-09-09

## Context and Problem Statement

The two-domain transport stand only needs to forward ROS messages between
domains 31 and 32. Its Zenoh bridge configuration and Cyclone DDS binding add
another middleware path to an execution otherwise using Fast DDS.

## Decision Drivers

- Reuse the maintained ROS domain bridge for the native path.
- Preserve delivery, type identity and W3C Trace Context propagation.
- Retain an executable baseline for comparison.

## Considered Options

- Keep Zenoh as the only stand.
- Replace it immediately with `ros2/domain_bridge`.
- Qualify `domain_bridge` and retain the pinned Zenoh alternative.

## Decision Outcome

Use `compose.transport.yaml` with Fast DDS and
[ros2/domain_bridge](https://github.com/ros2/domain_bridge/tree/0.5.0). Both ROS
domains share a private network namespace, using the UDP-only Fast DDS profile.
The bridge version is read from its installed package, and its configuration is
copied into the run directory before startup. The transport channel binds the
SHA-256 of that retained configuration inventory.

`test/compose/compose.zenoh.yaml` preserves the 1.9.0 bridge image by digest and
the existing router configurations. Its Cyclone DDS dependency remains for this
comparison until a later middleware qualification supports removing it. Renovate
does not update the frozen bridge image. The obsolete generator for the retired
`zenoh-channel.v1` schema is removed; both paths retain the configurations they use.

Both paths run the same probes, evidence sink, `transport-channel.v1`,
`clock-relation.v1`, causal chain and `transport-evaluate`. Passing requires all
messages with no loss, duplication or reordering, matching type hashes, preserved
Trace Context, and qualified cross-domain timing. Collector output is evaluated
only after both exporters have flushed and both Collectors have stopped.

## Consequences

- The replacement is accepted only with passing live tests for both paths.
- The stand qualifies transport within the scenario; it does not qualify physics,
  a physical robot, or another machine's clock.
- The native path and the frozen baseline share their verdict implementation.
- No dependency is removed solely because the new configuration can be parsed.
