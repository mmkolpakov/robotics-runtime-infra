# Fail Closed for Physical Execution

- Status: accepted
- Date: 2026-07-26

## Context and Problem Statement

HIL and real-target observation cross a physical safety boundary. A software
workload identity does not identify the attached controller, and a readable
ROS graph does not authorize command publication.

## Decision Drivers

- Make accidental actuation impossible from the observer profile.
- Bind authorization to one target, scenario, image digest, time window, and
  nonce.
- Keep operator and safety approval independent.

## Considered Options

- Trust network isolation and ROS domain IDs.
- Treat a workload certificate as target identity.
- Require a two-role signed permit, target evidence, and SROS2 enforcement.

## Decision Outcome

Physical profiles fail closed unless `permit-preflight` verifies both operator
and safety signatures against independent identity and issuer policy. The
permit binds target identity, scenario, image, time, and nonce. SROS2 Enforce
uses a read-only observer enclave; command publication is denied by policy and
tested negatively.

The nonce store is owned exclusively by the fixed unprivileged preflight
identity and is not group- or world-writable. A successful report is published
only after all run-owned host and container resources have been removed.

A SPIFFE SVID may identify a software workload, but it does not replace
physical controller identity or preflight evidence. SPIFFE defines an SVID as
the identity document of a workload:
<https://spiffe.io/docs/latest/spiffe-about/spiffe-concepts/>.

## Consequences

- Hosted CI uses synthetic PTY and `vcan` devices plus the generated SROS2
  telemetry-source SPKI only to prove the boundary; it does not claim a
  hardware identity.
- Hardware qualification still requires a protected lab runner and interlock.
- Real actuation is outside this repository.
