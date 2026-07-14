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
CI also builds the non-release `host-io-fixture` image for amd64 and arm64 to
validate host time, udev, systemd, and SocketCAN assets reproducibly.

## Version baseline

| Component | Release baseline |
| --- | --- |
| OS | Ubuntu 24.04 packages from snapshot `20260701T000000Z` |
| ROS | ROS 2 Jazzy packages from snapshot `2026-06-18` |
| Simulator | Gazebo Harmonic from the pinned Jazzy simulation image |
| CPU inference | ONNX Runtime 1.27.0 |
| Intel inference candidate | ONNX Runtime OpenVINO 1.24.1 with OpenVINO 2025.4.1 |
| NVIDIA inference candidate | ONNX Runtime GPU 1.27.0, CUDA 13.3.0 and cuDNN 9 |
| AMD inference candidate | ONNX Runtime MIGraphX 1.23.2 with ROCm 7.2.4 |
| Jetson inference candidate | JetPack 7.2 host; source-built ONNX Runtime 1.27.0, CUDA 13.3 and TensorRT 11 |
| RK3588 inference candidate | RKNN Toolkit2 and RKNN Runtime 2.3.2 |
| Evidence format | rosbag2 MCAP and MCAP CLI 0.2.0 |
| Time evidence | OpenTelemetry Collector Contrib 0.153.0; Chrony 4.5; linuxptp 4.0 |
| CAN observation | Ubuntu `can-utils` 2023.03; upstream behavior checked against v2025.01 |
| Compose | CI floor 2.35.1; CI current 5.3.1 |
| Contracts | `robotics-runtime-contracts` 0.5.0 |
| Acceptance harness | `robotics-acceptance-harness` 0.6.0 |

Base images, package snapshots, Python hashes, and foundation revisions are
pinned in `Dockerfile`, `docker-bake.hcl`, lock files, and `foundation.repos`.
Every released image contains exact Debian and Python package manifests under
`/usr/share/robotics-runtime/`. GitHub Releases record the image digests; each
image is published with an SBOM, BuildKit provenance, and an artifact
attestation.

Candidate versions are reproducible build inputs, not hardware support claims.

## Support status

Support is scoped to an immutable source revision and image digest. The status
terms are normative:

- **Released**: an artifact was published from a Git tag after the standard CI
  gates passed. This does not imply validation on every compatible device.
- **CI-verified**: the artifact builds and its software-only checks pass on a
  GitHub-hosted runner; target hardware was not exercised.
- **Qualification-gated**: the implementation exists, but support requires a
  passing protected workflow on the named hardware and retained evidence.
- **Qualified**: a named device passed the protected workflow for the exact
  source revision and image digest, and the qualification record is published.
- **Unsupported**: the repository intentionally makes no runtime or safety
  claim for that target.

### Compute matrix

| Target | Runtime path | Current evidence | Status |
| --- | --- | --- | --- |
| amd64 CPU | `simulation`, `inference-cpu` | Native integration and provider-conformance CI; images in `v0.5.0` | Released |
| arm64 CPU | Portable runtime images | Multi-platform BuildKit gate; images in `v0.5.0`; no native board claim | Released |
| Intel CPU on amd64 Linux | `inference-intel` | Image build and OpenVINO CPU provider conformance in hosted CI | CI-verified |
| Intel GPU on native Linux | `compose.intel.yaml` | Device-specific provider, no-fallback and tensor-parity gate defined | Qualification-gated |
| Intel GPU through WSL2 | `compose.intel.yaml` | `/dev/dxg` route and a separate protected runner gate defined | Qualification-gated |
| NVIDIA GPU on amd64 Linux | `compose.nvidia.yaml` | CUDA image builds; protected CDI/provider/parity gate defined | Qualification-gated |
| NVIDIA Jetson Orin or Thor | `compose.nvidia-jetson.yaml` | Pinned source and ARM64 build graph; protected device gate defined | Qualification-gated |
| AMD GPU on native Linux | `compose.amd.yaml` | ROCm/MIGraphX image builds; protected provider/parity gate defined | Qualification-gated |
| RK3588, including Orange Pi 5 Plus | `compose.rknn.yaml` | Converter and ARM64 runtime build; dedicated RKNN device gate defined | Qualification-gated |
| Apple silicon acceleration | Portable CPU image in a Linux VM only | No macOS-native, Metal, CoreML, or device qualification path | Unsupported |

No accelerated target is qualified by the current revision. The generic
hardware workflow covers NVIDIA, Intel, AMD, and Jetson; RK3588 uses its own
workflow. A successful image build or provider import cannot promote a row to
Qualified.

### Physical execution matrix

| Environment | Allowed physical effect | Current evidence | Status |
| --- | --- | --- | --- |
| Gazebo simulation | Simulated actuation | ROS/Gazebo integration and acceptance CI; images in `v0.5.0` | Released |
| MCAP playback | None | Clocked playback, readiness, evidence, and acceptance CI | Released |
| HIL attach | None | Signed permit, target identity, SROS2, time, serial, and CAN software gates | Qualification-gated |
| Real target observation | Observation only | Permit policy and live SROS2 telemetry/command-denial CI | Qualification-gated |
| Real target actuation | Actuation | Rejected by contracts, OPA policy, and the observer enclave | Unsupported |

HIL and real-observation qualification additionally requires an isolated lab,
named controller or sensor, operator and safety approvals, interlock evidence,
and target-specific timing limits. Synthetic devices, `vcan`, and software DDS
tests prove the boundary but do not qualify physical equipment.

The compatibility basis is ROS 2 Jazzy on Ubuntu 24.04
([REP-2000](https://docs.ros.org/independent/api/rep/html/rep-2000.html)), the
[ONNX Runtime execution-provider model](https://onnxruntime.ai/docs/execution-providers/),
[OpenVINO EP 1.24.1](https://onnxruntime.ai/docs/execution-providers/OpenVINO-ExecutionProvider.html),
[ROCm 7.2.4](https://rocm.docs.amd.com/en/docs-7.2.4/compatibility/compatibility-matrix.html),
[JetPack 7.2](https://developer.nvidia.com/embedded/jetpack/downloads),
[CUDA 13 minor-version compatibility](https://docs.nvidia.com/deploy/cuda-compatibility/minor-version-compatibility.html),
and [RKNN Toolkit2 2.3.2](https://github.com/airockchip/rknn-toolkit2/releases/tag/v2.3.2).

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
| `compose.security.yaml` | `security*` | SROS2 Enforce, observer-only enclave, positive and denial checks |
| `compose.stepped.yaml` | `stepped` | Run Gazebo paused and advance it through `WorldControl` |
| `compose.edge-attach.yaml` | `edge-attach`, `hil` | Attach-only observation through an external Docker network; HIL is permit-gated and SROS2-enforced |
| `compose.real-observation.yaml` | `real-observation` | Permit-gated SROS2 observation of a real target; layer after `compose.edge-attach.yaml` |
| `compose.time.yaml` | `time-chrony`, `time-ptp` | Export host-owned clock observations as contract-aligned OTLP JSON |
| `compose.serial.yaml` | `serial-preflight` | Verify one exact stable serial device mapping without starting product code |
| `compose.can-observation.yaml` | `can-observation` | Receive a host SocketCAN stream without exposing the bus to the container |

Containers only observe host time, serial identity, and CAN frames; they cannot
configure the host clock, udev, PTP interface, or physical bus.
The real-observation profile has no device mapping or command-capable ROS
identity. Sensor drivers remain in the separately managed target deployment.

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
The host time profiles are the exception: their evidence directory is owned by
the host `_chrony` UID/GID.

## Physical host preflight

The canonical physical host is Ubuntu 24.04 with systemd 255 or newer. The CI
fixture qualifies Chrony 4.5, linuxptp 4.0, systemd/udev 255.4, and the Ubuntu
`can-utils` package from the pinned snapshot. Time-source selection,
interfaces, PTP domain, and acceptance thresholds remain site configuration.

Install `config/time/chrony-command-socket.conf` as
`/etc/chrony/conf.d/robotics-command-socket.conf` and
`tmpfiles.d/robotics-time.conf` as `/etc/tmpfiles.d/robotics-time.conf`. Run
`systemd-tmpfiles --create`, restart Chrony, and start the evidence collector:

```bash
export ROBOTICS_CHRONY_IDENTITY="$(id -u _chrony):$(id -g _chrony)"
install -d -o "$(id -u _chrony)" -g "$(id -g _chrony)" \
  -m 0770 runs/current/evidence
docker compose -f compose.yaml -f compose.time.yaml \
  --profile time-chrony up -d time-evidence-chrony
```

For PTP, install `config/time/ptp4l.conf` through host configuration
management and install both `systemd/robotics-ptp-sample.*` units under
`/etc/systemd/system`. The timer only queries the read-only `ptp4lro` socket:

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now robotics-ptp-sample.timer
export ROBOTICS_CHRONY_IDENTITY="$(id -u _chrony):$(id -g _chrony)"
docker compose -f compose.yaml -f compose.time.yaml \
  --profile time-ptp up -d time-evidence-ptp
```

Both profiles write `runs/current/evidence/hardware-time.otlp.json` with clock
offset in milliseconds, drift in ppm, message age in milliseconds, and a
monotonic-clock flag. `ptp4l` and `phc2sys` remain host services; the collectors
receive no network device, PHC device, or Linux capability.

For a serial controller, prefer `/dev/serial/by-id/...`. Sites that need a
contract name may install a reviewed copy of
`config/udev/99-robotics-serial.rules` after replacing every example USB
identifier. Validate and reload it before use:

```bash
sudo udevadm verify config/udev/99-robotics-serial.rules
sudo udevadm control --reload
sudo udevadm trigger --subsystem-match=tty --settle
export ROBOTICS_SERIAL_DEVICE=/dev/robotics/controller-alpha
docker compose -f compose.yaml -f compose.serial.yaml \
  --profile serial-preflight run --rm serial-device-preflight
```

Capture the stable identity and structured udev observation before issuing a
physical execution permit:

```bash
device=/dev/robotics/controller-alpha
udevadm info --query=property \
  --property=DEVLINKS,ID_BUS,ID_MODEL_ID,ID_SERIAL,ID_SERIAL_SHORT,ID_VENDOR_ID \
  --json=short --name="${device}" | jq --sort-keys --compact-output \
  > runs/current/authorization-output/serial-preflight.json
udevadm info --query=property --property=ID_SERIAL --value \
  --name="${device}" > runs/current/authorization-output/serial-identity.txt
sha256sum runs/current/authorization-output/serial-identity.txt
sha256sum runs/current/authorization-output/serial-preflight.json
```

Use the first digest as `identity_sha256` and the second as
`preflight_evidence_sha256`.

The Compose policy rejects `/dev/ttyUSB*`, `/dev/ttyACM*`, wildcards, and a
complete `/dev` mapping. Runtime manifests carry the reviewed stable identity
and preflight evidence digests.

For read-only CAN observation, install the template unit and create the
dedicated internal Compose network before starting the gateway:

```bash
sudo apt-get install can-utils
sudo install -m 0644 systemd/robotics-can-observation@.service \
  /etc/systemd/system/
docker compose -f compose.yaml -f compose.can-observation.yaml \
  --profile can-observation create can-observation-client
sudo systemctl daemon-reload
sudo systemctl enable --now robotics-can-observation@can0.service
docker compose -f compose.yaml -f compose.can-observation.yaml \
  --profile can-observation up -d can-observation-client
docker compose -f compose.yaml -f compose.can-observation.yaml \
  --profile can-observation logs -f can-observation-client
```

The host owns link state, bitrate, termination, and frame transmission. The
gateway serves the fixed TCP port `28700` only to the internal
`172.30.247.0/28` network; its deterministic host endpoint is the bridge gateway
`172.30.247.1:28700`. The systemd unit has no capabilities and applies a
cgroup-BPF IP allow-list. Qualify this profile on a cgroup v2 host before using
physical CAN; WSL2 kernels without `vcan` can validate only the static profile.
The container has no CAN network interface or transmit utility. Command-capable
CAN belongs to a separately authorized control profile and is not provided by
this repository.

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
