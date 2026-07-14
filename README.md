# robotics-runtime-infra

[![CI](https://github.com/mmkolpakov/robotics-runtime-infra/actions/workflows/ci.yml/badge.svg)](https://github.com/mmkolpakov/robotics-runtime-infra/actions/workflows/ci.yml)
[![Foundation integration](https://github.com/mmkolpakov/robotics-runtime-infra/actions/workflows/foundation-integration.yml/badge.svg)](https://github.com/mmkolpakov/robotics-runtime-infra/actions/workflows/foundation-integration.yml)
[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)

Domain-neutral OCI runtimes and Docker Compose profiles for ROS 2 simulation,
portable edge workloads, repeatable playback, recording, and acceptance evidence.
Product scenes, robot descriptions, models, hardware drivers, and control logic
belong in consuming repositories.

## Quick start

The headless simulation requires Docker Engine or Docker Desktop, the Compose
plugin 2.35.1 or newer, and an amd64 host. It does not require a host ROS
installation or a display server.

```bash
docker compose pull simulation
docker compose up --detach --wait simulation
docker compose ps
docker compose exec -T simulation \
  robotics-entrypoint timeout 20 ros2 topic echo /clock --once
docker compose logs --follow simulation
docker compose down --volumes --remove-orphans
```

`simulation` is healthy only after Gazebo publishes `/clock`. Run the packaged
ROS/Gazebo acceptance tests with:

```bash
docker compose --profile test run --rm --no-deps test
```

## Runtime images

Release tags publish immutable digests for these images under
`ghcr.io/mmkolpakov/robotics-runtime-infra/`:

| Image | Platforms | Purpose |
| --- | --- | --- |
| `simulation` | amd64 | ROS 2, Gazebo, ros2_control, MoveIt 2, MAVROS, camera and MCAP tests |
| `edge` | amd64, arm64 | ROS 2, MAVLink/MAVROS and standard robotics messages without Gazebo |
| `sensor` | amd64, arm64 | `edge` plus OpenCV, `cv_bridge`, `image_transport`, GStreamer and V4L2 |
| `inference-cpu` | amd64, arm64 | ONNX Runtime CPU execution provider |
| `acceptance-observer` | amd64, arm64 | Attach-only acceptance verification and JSON/JUnit results |
| `benchmark` | amd64, arm64 | Apex.AI `performance_test` for ROS 2 transport measurements |
| `evidence-sink` | amd64, arm64 | MCAP validation, checksums, S3-compatible upload and evidence finalization |

The simulation image is tested by running Gazebo and ROS 2 tests on amd64. The
portable images are built for amd64 and arm64; hardware-specific accelerators
and device drivers are not qualified by the 0.5 release.

## Version baseline

| Component | Release baseline |
| --- | --- |
| OS | Ubuntu 24.04 packages from snapshot `20260701T000000Z` |
| ROS | ROS 2 Jazzy packages from snapshot `2026-06-18` |
| Simulator | Gazebo Harmonic from the pinned Jazzy simulation image |
| CPU inference | ONNX Runtime 1.26.0 |
| Evidence format | rosbag2 MCAP and MCAP CLI 0.2.0 |
| Compose | CI floor 2.35.1; CI current 5.3.1 |
| Contracts | `robotics-runtime-contracts` 0.4.3 |
| Acceptance harness | `robotics-acceptance-harness` 0.5.1 |

Base images, package snapshots, Python hashes, and foundation revisions are
pinned in `Dockerfile`, `docker-bake.hcl`, lock files, and `foundation.repos`.
Every released image contains exact Debian and Python package manifests under
`/usr/share/robotics-runtime/`. GitHub Releases record the image digests; each
image is published with an SBOM, BuildKit provenance, and an artifact
attestation.

## Compose profiles

The base `compose.yaml` is intentionally small. Add one overlay for the runtime
behavior being tested:

| Overlay | Profiles | Behavior |
| --- | --- | --- |
| `compose.playback.yaml` | `playback` | Start-paused, clocked MCAP playback after subscriber readiness |
| `compose.record.yaml` | `record`, `snapshot` | Bounded Zstd MCAP recording; snapshot is diagnostic only |
| `compose.evidence.yaml` | `evidence` | Validate segments and finalize an evidence index locally or in S3 |
| `compose.high-throughput.yaml` | none | Private shared network and IPC namespaces with Fast DDS SHM |
| `compose.benchmark.yaml` | `benchmark` | Measure UDP, SHM, or Data Sharing with `performance_test` |
| `compose.security.yaml` | `security*` | SROS2 Enforce, enclave generation, positive and negative checks |
| `compose.stepped.yaml` | `stepped` | Run Gazebo paused and advance it through `WorldControl` |

For example, verify the packaged golden MCAP without starting Gazebo:

```bash
export ROS_DOMAIN_ID=87
docker compose \
  -f compose.yaml \
  -f compose.playback.yaml \
  --profile playback --profile test \
  up --detach \
  playback playback-gate playback-probe
docker compose \
  -f compose.yaml \
  -f compose.playback.yaml \
  --profile playback --profile test \
  wait playback-gate playback-probe
docker compose \
  -f compose.yaml \
  -f compose.playback.yaml \
  --profile playback --profile test \
  down --volumes --remove-orphans
```

Use a free `ROS_DOMAIN_ID` for each concurrent run. Slow executors can override
`ROBOTICS_PLAYBACK_READY_TIMEOUT_SEC` and
`ROBOTICS_PLAYBACK_PROBE_TIMEOUT_SEC`.

## Run artifacts

Recording and acceptance profiles use one host-visible run directory:

```text
runs/current/
├── scenario.yaml
├── runtime-manifest.json
├── bags/
├── evidence/evidence-index.json
└── results/
```

Override it with `ROBOTICS_RUN_DIR`, `ROBOTICS_BAG_DIR`, and
`ROBOTICS_EVIDENCE_DIR`. On Linux, pre-create bind-mounted directories writable
by UID 1000; the evidence directory must be writable by UID 10001. Named
volumes avoid host ownership concerns for interactive development.

## Add a product repository

Do not add product code to this repository. Copy
`compose.override.yaml.example` to the consuming repository, set
`ROBOTICS_PROJECT_DIR`, and run Compose from this repository with the consumer
override:

```bash
ROBOTICS_PROJECT_DIR=../my-robotics-project \
  docker compose -f compose.yaml -f ../my-robotics-project/compose.override.yaml \
  up --detach --wait simulation
```

Production consumers should inherit released images by digest, add their own
ROS packages in a product Dockerfile, and keep worlds, models, parameters, and
hardware access in their own Compose overlays. Set a distinct `ROS_DOMAIN_ID`,
`GZ_PARTITION`, and Compose project name for each concurrent run.

## Build and verify changes

```bash
docker buildx bake --print cpu
docker buildx bake cpu --load --set '*.platform=linux/amd64'
docker compose --profile test --profile acceptance config --quiet
docker compose up --detach --no-build --wait simulation
docker compose --profile test run --rm --no-deps test
```

CI also validates every Compose overlay on the supported Compose floor and
current version, enforces OPA policies, builds all portable targets for
arm64, scans every image, and runs the three-repository acceptance path.
Contribution setup and required checks are in [CONTRIBUTING.md](CONTRIBUTING.md).

## Scope and safety

The 0.5 release supports CPU simulation, playback, recording, transport
benchmarks, and acceptance observation. It does not claim qualification for GPU,
HIL, real hardware, or physical actuation. Mock hardware may verify interfaces,
but policy forbids using it as evidence for physical behavior.

Report security issues through GitHub private vulnerability reporting as
described in [SECURITY.md](SECURITY.md). This project is licensed under the
[MIT License](LICENSE).
