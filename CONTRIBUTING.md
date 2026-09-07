# Contributing

## Prerequisites

- Docker Engine or Docker Desktop with Buildx
- Docker Compose 2.35.1 or newer
- Git
- Python 3.12 and `uv` for repository hooks

No host ROS or Gazebo installation is required.

## Local checks

Create a branch and run the static checks before building images:

```bash
uvx --from pre-commit==4.6.0 pre-commit run --all-files
docker buildx bake --print cpu
docker compose --profile test --profile acceptance config --quiet
```

Build and test the amd64 CPU product:

```bash
docker buildx bake cpu --load --set '*.platform=linux/amd64'
docker compose up --detach --no-build --wait simulation
docker compose --profile test run --rm --no-deps test
docker compose --profile test --profile acceptance \
  down --volumes --remove-orphans
```

CI is the release gate for the arm64 build, vulnerability policy, supply-chain
checks, and the integration of contracts, acceptance harness, and runtime.

## Foundation integration

`foundation.repos` selects exact contracts and harness commits. The runtime
repository owns their joint Python resolution in `tooling/foundation/uv.lock`;
the imported repositories keep independent development locks.

After changing a revision in `foundation.repos`, refresh and validate the
integration environment:

```bash
bash scripts/ci/foundation/import-sources.sh
uv lock --project tooling/foundation
bash scripts/ci/foundation/validate-foundation.sh
```

Only the runtime repository changes for a compatible foundation upgrade. A
contracts release does not require a harness release unless the harness code or
its declared compatibility range changes.

Renovate custom managers track the release-tag comments and commit hashes in
`foundation.repos`, the wheel URLs in `docker/python/acceptance-observer.in`
and `permit-preflight.in`, and the wheel URL/checksum in the CI environment.
The CI checksum uses the `github-release-attachments` datasource. Foundation
updates are grouped for review and never auto-merged. This config does not
itself prove the hosted Renovate app is enabled or has opened a PR.

Before merging an update, verify the proposed release tags resolve to the
recorded commits, regenerate the two Python hash locks with the `uv pip compile`
commands recorded in their headers, refresh `tooling/foundation/uv.lock`,
and regenerate `docs/foundation-compatibility.md`. Update the README baseline
as part of the same review. The regex managers do not generate those derived
files. Check the CI wheel hash against the downloaded release asset; a missing
or unchanged digest for a changed wheel is a blocker. Run
`foundation-integration` before merging. Contracts 0.16 / harness 0.18 require
the coordinated migration described in `docs/compatibility.md`.

Validate config syntax using the pinned CI Renovate version:

```bash
renovate-config-validator --strict renovate.json
node test/renovate/check-pins.mjs /path/to/node_modules/renovate
```

The extraction check loads Renovate's real regex manager and template renderer.
It verifies all nine custom-managed pins, both wheel-version positions,
commit/checksum replacement, preservation of other dependencies, rejection of
unrelated repositories, and LF/CRLF input. Use Node 24 and Renovate 43.257.5,
matching the current `RENOVATE_IMAGE`; the test rejects a version mismatch.

External activation remains unverified until a real Renovate run opens a
reviewable update PR. Local extraction and replacement checks demonstrate
config behavior only. No external PR is created by these local checks.

## Change boundaries

Keep this repository domain-neutral. A change may add reusable ROS, simulation,
data-plane, evidence, security, or packaging capability. Product scenes, mission
logic, sorting rules, trained models, vendor deployment credentials, and robot
hardware descriptions belong in consuming repositories.

Declare ROS dependencies in a package manifest and resolve them with `rosdep`.
Lock Python dependencies with hashes. Pin base images and GitHub Actions by
immutable digest or commit. Do not add host-mutating setup scripts or broad
device, network, capability, or privileged access.

Every behavior change needs a positive test and, for a safety or policy
invariant, a negative test. Hardware support remains release-gated until a
named platform produces retained qualification evidence.

## Pull requests

Describe the user-visible behavior, compatibility impact, tests run, and any
remaining qualification boundary. Keep commits focused and use imperative
subjects. Do not commit generated run data, credentials, local overrides, or
private project material.
