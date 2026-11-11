# 0010. Supplier update policy and snapshot discipline

Status: accepted

## Context

Release images build against a frozen Ubuntu snapshot so that a given release
reproduces byte-for-byte. Distro-owned vulnerabilities appear in the base over
time and must be handled without breaking reproducibility or weakening the
vulnerability gate.

## Decision

The Ubuntu base advances only by a deliberate `UBUNTU_SNAPSHOT` update that is
re-qualified end to end. The base digest is frozen between such updates and is
excluded from digest-renovate; a blind digest refresh of the base is rejected.

Residual distro CVEs are accepted only as exact Canonical `not_affected` OpenVEX
records (package version, architecture, distro) backed by evidence, and are
reviewed on any version change. Uncovered HIGH/CRITICAL findings remain
blocking. A supplier rebuild is scheduled within the rebuild SLA and re-scanned
before release.

Cosign is consumed as the publisher-verified, digest-pinned Chainguard image;
version and digest move together in one reviewed update with negative tests.
There is no blanket VEX and no red merge. Source and released identities stay
separate; a released lock is never edited in the source tree.

## Consequences

Reproducibility is preserved while distro risk is handled explicitly. The
security gate stays fail-closed: a snapshot update or a VEX record is a reviewed,
evidenced change, not a scanner shortcut. The mirror base is configurable for
resilience but defaults to the official snapshot service, and package signatures
are verified against the Ubuntu archive keyring regardless of mirror.
