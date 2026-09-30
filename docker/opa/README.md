# OPA runtime artifact

`Dockerfile` pins the official multi-platform `openpolicyagent/opa` static image
and copies its binary unchanged into policy tooling and permit-preflight images.
The license is fetched from the pinned upstream source commit with a checksum.

Renovate preserves the `-static` variant using
[version compatibility](https://docs.renovatebot.com/configuration-options/#versioncompatibility).
The version minimum is applied to the numeric part of the tag so future static
releases are not mistaken for prereleases. Each update must pass policy tests
and the image vulnerability scans on both supported architectures.

Run policy checks with `scripts/ci/static-analysis/verify-policy-format-and-tests.sh`.
