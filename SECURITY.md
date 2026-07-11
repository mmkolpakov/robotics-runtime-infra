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
