# Runtime profiles and retained artifacts

Operational details for the retained ROS, playback and observation profiles.
Current release and qualification claims are recorded in [compatibility](compatibility.md);
these instructions do not qualify new hardware or simulator providers.

## Compose Profiles

The base `compose.yaml` is intentionally small. Add one overlay for the runtime
behavior being tested:

| Overlay | Profiles | Behavior |
| --- | --- | --- |
| `compose.playback.yaml` | `playback` | Start-paused, clocked MCAP playback after subscriber readiness |
| `compose.record.yaml` | `record`, `snapshot` | Bounded Zstd MCAP recording; snapshot is diagnostic only |
| `compose.evidence.yaml` | `evidence` | Validate segments and finalize an evidence index locally or in S3 |
| `compose.observability.yaml` | `observability` | Receive OTLP metrics and traces and write bounded evidence files |
| `compose.high-throughput.yaml` | none | Private shared network and IPC namespaces with Fast DDS SHM |
| `compose.benchmark.yaml` | `benchmark` | Measure UDP, SHM, or Data Sharing with `performance_test` |
| `compose.zenoh.yaml` | `zenoh` | Bridge two isolated ROS domains through pinned Zenoh routers |
| `compose.sensor-inference.yaml` | `sensor-inference` | Run the CPU sensor-to-ONNX-to-OTLP qualification probe |
| `compose.nvidia-sim.yaml` | `nvidia-simulation` | Run headless OGRE2/EGL rendering and GPU lidar on NVIDIA hardware |
| `compose.sensor-inference-nvidia.yaml` | `sensor-inference` | Replace the probe with the no-fallback CUDA provider path |
| `compose.sensor-inference-intel.yaml` | `sensor-inference` | Replace the probe with the no-fallback OpenVINO CPU provider path |
| `compose.intel.yaml` | `conformance-intel-*` | Run separate Intel CPU, native GPU, or WSL2 GPU provider gates |
| `compose.security.yaml` | `security*` | SROS2 Enforce, observer-only enclave, positive and denial checks |
| `compose.stepped.yaml` | `stepped` | Advance any conforming simulator through ROS 2 `simulation_interfaces` |
| `compose.simulation-conformance.yaml` | `simulation-conformance` | Verify features, pause, step, resume, and `/clock` through the standard simulator API |
| `compose.edge-attach.yaml` | `edge-attach`, `hil` | Attach-only observation through an external Docker network; HIL is permit-gated and SROS2-enforced |
| `compose.real-observation.yaml` | `real-observation` | Permit-gated SROS2 observation of a real target; layer after `compose.edge-attach.yaml` |
| `compose.time.yaml` | `time-chrony`, `time-ptp` | Export host-owned clock observations as contract-aligned OTLP JSON |
| `compose.serial.yaml` | `serial-preflight` | Verify one exact stable serial device mapping without starting product code |
| `compose.can-observation.yaml` | `can-observation` | Receive a host SocketCAN stream without exposing the bus to the container |

The stepped profile advances one physics iteration every 0.2 seconds through
`simulation_interfaces/StepSimulation`. Set `ROBOTICS_STEP_INTERVAL_SEC` to
change the pace. Set `ROBOTICS_STEPS_PER_TICK` to batch iterations and declare
the matching `time_policy.max_skipped_steps` in the consuming scenario.

The default Gazebo service namespace is `/simulator`. A replacement
`SIMULATION_IMAGE` is accepted only when the conformance probe observes the
required feature flags, pause/step/resume behavior, and an advancing `/clock`:

```bash
docker compose up --detach --wait simulation
docker compose -f compose.yaml -f compose.simulation-conformance.yaml \
  --profile simulation-conformance run --rm simulation-conformance
```

Override `ROBOTICS_SIMULATOR_SERVICE_NAMESPACE` only when the replacement
simulator publishes the standard services under another namespace. Product
code must not call Gazebo Transport control services directly.
`ROBOTICS_CONFORMANCE_STEP_SIZE_NS` must equal the simulator world's declared
fixed step; the probe verifies the exact `steps * step_size` clock advance.

Foundation acceptance uses `/clock` only as the simulation time authority.
Transport age and loss are measured on the separate reliable
`/robotics/runtime_probe` stream, so best-effort clock delivery is not treated
as an application-channel reliability guarantee.

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

The packaged Int32 bag checks readiness and receipt of one message. Canonical
source foundation CI enables a separate UInt64 playback qualification with
`ROBOTICS_FOUNDATION_QUALIFY_PLAYBACK=1`. It replays the successful source phase's
recording in the same job through the existing runner and live observer.

The dataset binds the original capture scenario, runtime and recording bytes.
The signed inventory retains their source metadata, summary and evidence index;
playback has its own scenario, runtime, run context and observer evidence.
Replay clock observations establish the declared time authority. Timing precision
requires separate measurements.

Use a free `ROS_DOMAIN_ID` for each concurrent run. Slow executors can override
`ROBOTICS_PLAYBACK_READY_TIMEOUT_SEC` and
`ROBOTICS_PLAYBACK_PROBE_TIMEOUT_SEC`.

## Run Artifacts

Recording and acceptance profiles use one host-visible run directory:

```text
runs/current/
├── scenario.yaml
├── acceptance-run.json
├── runtime-manifest.json
├── configuration/
│   ├── host-topology.json
│   └── runtime-resources.json
├── bags/
├── evidence/
│   ├── evidence-index.json
│   ├── metrics.otlp.jsonl
│   └── traces.otlp.jsonl
└── results/
    ├── acceptance-result.json
    └── acceptance-aggregate.json
```

Override it with `ROBOTICS_RUN_DIR`, `ROBOTICS_BAG_DIR`, and
`ROBOTICS_EVIDENCE_DIR`. On Linux, pre-create bind-mounted directories writable
by UID 1000; the evidence directory must be writable by UID 10001. Named
volumes avoid host ownership concerns for interactive development.
The sensor-inference qualification overlay runs both report writers as UID 1000
so its isolated report tree has one non-root owner.
Runtime manifests use `runtime-manifest.v1` and bind retained provider profiles,
conformance results, host topology, and container-resource configuration files.
Intel sensor qualification also retains the exact ONNX fixture, observed NPY
inputs, provider report, and a validated `model-artifact-manifest.v1` linking
those artifacts to the runtime manifest.
`ROBOTICS_TIME_EVIDENCE_DIR` is the separate bind mount used by host-owned
Chrony and PTP collectors. Its literal Compose default is
`./runs/current/evidence`; changing `ROBOTICS_RUN_DIR` or `ROBOTICS_EVIDENCE_DIR`
does not change this default. Set it explicitly to a separate directory, such
as `./runs/current/time-evidence`, owned by the host `_chrony` UID/GID with
mode `0770`. Do not change the evidence-sink directory to `_chrony` ownership.
When assembling a qualification bundle, retain the resulting time file in the
run's evidence set and register it with the appropriate owner and checksum.

On Linux, the foundation runner captures host facts and qualifies the running
simulator before producing its runtime manifest and acceptance result. With
Docker Buildx, uv, Bats, and Cosign 3.1.3 available, build and run the source
foundation from the repository root:

```bash
export REGISTRY=local VERSION=foundation ROBOTICS_RUNTIME_MODE=source
export SIMULATION_IMAGE="${REGISTRY}/robotics-runtime-infra/simulation:${VERSION}"
export OBSERVER_IMAGE="${REGISTRY}/robotics-runtime-infra/acceptance-observer:${VERSION}"
export EVIDENCE_IMAGE="${REGISTRY}/robotics-runtime-infra/evidence-sink:${VERSION}"
export POLICY_TOOLING_IMAGE="${REGISTRY}/robotics-runtime-infra/policy-tooling:${VERSION}"
export VCS_REF IMAGE_CREATED SOURCE_DATE_EPOCH
VCS_REF="$(git rev-parse HEAD)"
IMAGE_CREATED="$(git show --no-patch --format=%cI HEAD)"
SOURCE_DATE_EPOCH="$(git show --no-patch --format=%ct HEAD)"
bash scripts/ci/foundation/import-sources.sh
bash scripts/ci/foundation/validate-foundation.sh
docker buildx bake --file docker-bake.hcl \
  simulation acceptance-observer evidence-sink policy-tooling \
  --load --set '*.platform=linux/amd64'
bash scripts/ci/foundation/run-acceptance.sh
```

The runner creates a canonical run ID, retains the provider probe and world
under `artifacts/<project>/provider/`, and supplies the manifest's host platform
and provider bindings. Direct use of the `runtime-manifest` service requires
those inputs to exist in the mounted run directory. The image supplies
`ROBOTICS_INFRA_REVISION`; `ROBOTICS_RUNTIME_ID` defaults to
`org.example.local-runtime`. Set that ID for a consuming runtime.
Released mode uses reviewed `release.env` image references and independently
verified registry manifest digests. `--env-file` supplies Compose interpolation;
it does not export shell variables.
`ROBOTICS_RUN_ID` and `ROBOTICS_DOMAIN_ID` must match the acceptance run and
scenario when an observer is attached. `ROBOTICS_DOMAIN_ID` is a contract
domain identifier; it is separate from the numeric DDS `ROS_DOMAIN_ID`.
Evidence, recording, sensor-inference, and transport overlays require a run ID
during Compose interpolation; sensor-inference also requires a domain ID.
The base simulation model remains usable without an acceptance run. Its observer
command validates both identifiers when invoked.

The `robotics.*` metric namespace is reserved by the foundation. It includes
clock, message delivery, inference latency, and
`robotics.simulation.deadline_miss_ratio`. Scenarios declare every metric they
consume in `metric_definitions`; product metrics use a reverse-domain prefix.

In S3 mode, `policy_observation.upload_lag_max_sec` is the largest whole-second
age of any MCAP spool file observed during a sink scan: scan time minus the
file's modification time, clamped to zero. It is not network transfer duration
or object-store acknowledgement latency. Local-only runs report zero.
The watcher follows nested recording directories recursively and retains a
periodic rescan to handle directory creation races and missed filesystem events.

## Physical Host Preflight

Host time, serial identity, CAN observation and permit preparation belong to the
[attached-observation operator reference](edge-attach.md#physical-host-preflight).
It defines the host prerequisites, directory ownership, collectors and separate
physical qualification requirements.

## Recorded playback completion

The foundation runner defaults to `controlled-stop`: it seals the observation
recorder and intentionally stops the player after measurement. This route does
not claim natural EOF.

For the source isolation recipe, select natural completion for its recorded
playback phase:

```bash
ROBOTICS_FOUNDATION_QUALIFY_PLAYBACK=1 \
ROBOTICS_FOUNDATION_PLAYBACK_COMPLETION=natural-eof \
bash scripts/ci/foundation/run-acceptance-isolation.sh
```

The live capture phases keep controlled shutdown. Recorded playback waits for
the same admitted player to exit after measurement and recorder drain, using
`ROBOTICS_PLAYBACK_PROBE_TIMEOUT_SEC` (default 75 seconds, maximum 300).
The runner retains the original inspect/wait/log bytes and validates successful
exit without OOM or restart before adding them to the signed qualification.
Timeout or changed identity fails qualification; cleanup preserves the failure.
This option does not define a large-recording profile or prove multi-member
coverage on its own.
