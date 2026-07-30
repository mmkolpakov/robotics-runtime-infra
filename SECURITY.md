# Security Policy

## Supported versions

Security fixes are applied to the latest released minor version. Older releases
may be used through immutable digests but do not receive backports unless a
release notice states otherwise.

## Reporting a vulnerability

Use GitHub private vulnerability reporting for this repository. Do not open a
public issue with exploit details, credentials, private keys, device addresses,
or safety-sensitive reproduction steps.

Include the affected image digest or commit, deployment environment, impact,
and the smallest safe reproduction. Maintainers will acknowledge the report,
coordinate a fix and disclosure, and publish replacement image digests when
required.

## Operational boundary

Published containers are building blocks, not a physical safety system. HIL,
real hardware, actuator enablement, host device access, network segmentation,
and key management require a separate reviewed deployment and safety case.

The acceptance observer is independent from the system under observation. Its
SROS2 enclave is read-only for product interfaces, uses Enforce mode, and is
tested to reject command publication. A verdict is not accepted when required
evidence, target identity, or authorization is missing.

Physical execution authorization binds two independent roles, a target
identity, scenario digest, image digest, validity window, and nonce. A workload
identity such as a SPIFFE SVID may authenticate the software process but does
not replace the physical controller identity or preflight evidence.
