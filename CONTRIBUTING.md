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

Product Kubernetes packaging has an independent offline check:

```bash
scripts/ci/check-product-helm.sh
```

This builds the pinned project tooling container and runs strict Helm lint/render,
official Kubernetes API schema and identity fixtures without cluster access.
For rootless Podman, use `ROBOTICS_IMAGE_ENGINE=podman` with the same command.

CI is the release gate for the arm64 build, vulnerability policy, supply-chain
checks, and the integration of contracts, acceptance harness, and runtime.

## Foundation integration

`foundation.repos` pins one immutable workspace commit. The imported workspace
owns the joint `uv.lock`; `config/foundation-lock.json` binds the two package
versions and source trees to that commit. Generated runtime locks are exports
of the workspace lock and omit the two packages built into the images.

After changing the commit, import the source and regenerate its derived inputs:

```bash
bash scripts/ci/foundation/import-sources.sh --refresh-pins
python3 scripts/ci/foundation/sync-workspace-pins.py --check
python3 -m unittest discover -s test/ci -p test_workspace_pins.py -v
bash scripts/ci/foundation/validate-foundation.sh
```

The importer refuses to switch a checkout containing tracked local changes.
Build backend dependencies are checked with the existing hash lock as version
constraints. If the workspace changes `build-system.requires`, explicitly
refresh that separate build lock and review the dependency changes:

```bash
python3 scripts/ci/foundation/sync-workspace-pins.py --refresh-build-lock
```

Source integration can pin an immutable candidate commit before package
publication. Add `release: harness-vX.Y.Z` only after the corresponding source
tags exist and the contracts and harness package releases have completed.
The importer checks tag commits and package source trees; it does not verify
PyPI publication or completed GitHub release workflows. Verify those separately
before release adoption. Renovate tracks a release-bound pin from published
GitHub releases and requires regenerating its derived inputs in the update PR.
The obsolete managers for independent repositories and wheel URLs have been
removed.

Keep the migration in one integration PR until producers, fixtures, CLI
arguments, retained evidence and both domain paths pass foundation-integration.
Do not merge only the new source pin into an otherwise legacy infra checkout.
Wheels built from the pinned workspace are source build inputs. Their source
tag binding does not establish publication of package or OCI release assets.

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
