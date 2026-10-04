# Robotics Runtime Infra

[![CI](https://github.com/mmkolpakov/robotics-runtime-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/mmkolpakov/robotics-runtime-infra/actions/workflows/ci.yml)
[![Foundation integration](https://github.com/mmkolpakov/robotics-runtime-infra/actions/workflows/foundation-integration.yml/badge.svg)](https://github.com/mmkolpakov/robotics-runtime-infra/actions/workflows/foundation-integration.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Worker environments, deployment and qualification for
[robotics-runtime](https://github.com/mmkolpakov/robotics-runtime).
Use this repository to launch a composition, record the actual runtime and
retain evidence for independent verification.

Product repositories supply scenes, robot descriptions, control logic, cameras
and vision models. Contracts validate documents; the attach-only harness
observes and evaluates executions. They do not launch this repository's services.

## Current scope

The published OCI release is `v0.10.0-rc.1`. It supplies the retained ROS 2
Jazzy/Gazebo Harmonic and portable worker profiles. The source foundation and
released image lock have separate identities:
[compatibility](docs/compatibility.md) and
[foundation lock](docs/foundation-compatibility.md).

The neutral-robot released consumer currently has an open time/readiness
failure. Native model presence passed, but the complete consumer did not
qualify. Source CI, image provenance and one healthy service do not close that
failure.

The plugin-host line selects independent Gazebo, Webots and Isaac providers.
Their native APIs, assets and environments are separate. New providers remain
development candidates until their execution, rendering and published-consumer
gates pass. Simulator support does not imply the same autopilot support in
each engine.

## Architecture

```mermaid
flowchart LR
    profile["Consumer-owned profile / workload"]
    host["Cordis host<br/>composition, ownership, readiness"]
    executor["Compose / Execa<br/>workers and resources"]
    providers["Native providers<br/>Gazebo / Webots / Isaac"]
    facts["Observed identity / time / payloads"]
    contracts["Contracts<br/>exact documents and references"]
    harness["Harness<br/>evaluation and reports"]

    profile -. trusted configuration .-> host
    host -. lifecycle .-> executor
    executor -. ownership .-> providers
    providers --> facts --> contracts --> harness
```

Host lifecycle is separate from native control and video connections. The
common document/evaluator environment does not require a simulator SDK or ROS.
[Architecture](docs/architecture.md) describes native API boundaries and
evidence-before-reset ordering.

## Run the published simulation

Use an amd64 host with Docker Engine/Desktop and Compose 2.35.1 or newer.
This retained headless ROS profile does not require host ROS or a display.

Run from this checkout; download its published image lock:

```bash
gh release download v0.10.0-rc.1 \
  --repo mmkolpakov/robotics-runtime-infra \
  --pattern release.env
docker compose --project-name robotics-example --env-file release.env pull simulation
docker compose --project-name robotics-example --env-file release.env \
  up --detach --no-build --wait simulation
docker compose --project-name robotics-example --env-file release.env exec -T simulation \
  robotics-entrypoint timeout 20 ros2 topic echo /clock --once
```

A printed clock sample confirms that observation, not a full workload verdict.
Inspect logs and stop only this example's resources:

```bash
docker compose --project-name robotics-example --env-file release.env logs --tail 100 simulation
docker compose --project-name robotics-example --env-file release.env down --volumes --remove-orphans
```

Released mode uses immutable `tag@sha256` references and rejects local-image
fallbacks. Source mode builds the checkout and has no release qualification
claim. Follow [image locks](docs/runtime-lock.md) for both modes.

For playback, sensor, recording and physical observation settings, use
[Runtime profiles](docs/runtime-profiles.md).

## Consumer integration

Use the
[minimal consumer](examples/minimal-consumer/README.md) and
[neutral-robot consumer](examples/neutral-robot/README.md) as scoped examples.

Consumers retain product sources and configuration in their own repository.
Images inherit the released foundation by digest and preserve its exact
source lock. Every run has its own Compose project, ROS domain/Gz partition
when applicable, and resource owner.

Three reusable workflows accept an immutable infra commit:

- `reusable-validate-documents.yml` validates explicitly selected document roles;
- `reusable-qualify.yml` runs the locked foundation and emits a signed package;
- `reusable-verify-qualification.yml` independently verifies a retained package.

[Qualification](docs/qualification.md) describes evidence, signatures and
consumer inputs. [Evidence producers](docs/evidence-producers.md) describes the
native formats and authorities. Workflow success is scoped to its actual
source, image, workload and environment.

## Platforms and development

[Compatibility](docs/compatibility.md) records software and hardware boundaries.
[Edge attachment](docs/edge-attach.md) describes observation-only physical
profiles; [WSL2](docs/wsl2.md) records host limitations. Image builds and
accelerator imports are not device qualification. Real actuation is outside
the retained profile's supported scope.

Build and verify the source checkout:

```bash
docker buildx bake --file docker-bake.hcl --print cpu
docker buildx bake --file docker-bake.hcl cpu --load --set '*.platform=linux/amd64'
docker compose --profile test --profile acceptance config --quiet
docker compose up --detach --no-build --wait simulation
docker compose --profile test run --rm --no-deps test
```

[CONTRIBUTING](CONTRIBUTING.md) contains required checks, foundation updates and
deployment setup. [Supply-chain](docs/supply-chain.md),
[quality](QUALITY_DECLARATION.md) and
[architecture decisions](docs/decisions/README.md) define the claims attached
to published artifacts. Report vulnerabilities through
[SECURITY](SECURITY.md).
