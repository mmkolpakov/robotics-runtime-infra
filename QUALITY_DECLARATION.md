# Quality Declaration

This repository contains the `robotics_runtime_infra`,
`robotics_observability`, and `robotics_observability_msgs` ROS packages and
their container runtime. It claims **REP-2004 Quality Level 4**.

The claim is intentionally conservative. The packages are pre-1.0, have no
established compatibility history across multiple minor releases, and do not
yet publish coverage and performance-regression records sufficient for a
higher REP-2004 claim.

## Version and Change Control

The repository uses Semantic Versioning and the compatibility policy in
[`docs/compatibility.md`](docs/compatibility.md). Changes are reviewed through
pull requests and gated by GitHub Actions. Architecture decisions are recorded
under [`docs/decisions`](docs/decisions/README.md).

## Documentation and License

Features and support boundaries are documented in `README.md`. Public runtime
surfaces and compatibility rules are explicit. The repository is MIT licensed.

## Testing

CI performs linting, policy tests, Docker build checks, multi-platform builds,
ROS launch tests, Compose integration, vulnerability scanning, SBOM
generation, and three-repository acceptance tests. Hardware-specific paths are
promoted only by protected qualification workflows. These controls exceed
Level 4 requirements but do not change the declared level.

## Dependencies and Platforms

Build inputs are locked by digest, package snapshot, revision, or hash.
Supported platforms and qualification status are listed in `README.md`.
Unsupported targets are stated explicitly.

## Security

[`SECURITY.md`](SECURITY.md) defines vulnerability reporting and the physical
safety boundary. Published artifacts carry provenance and SBOM attestations.

REP-2004 is the normative basis:
<https://ros.org/reps/rep-2004.html>.
