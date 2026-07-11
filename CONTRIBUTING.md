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
