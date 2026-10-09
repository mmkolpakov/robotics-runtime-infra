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

Physical profiles additionally require `authorization-output` to be owned by
UID/GID `10002:10002` with mode `0755`, and the persistent nonce store to be
owned by the same identity with mode `0700`. The nonce store is a security
boundary: do not place it on a shared or group-writable mount.

## Physical Host Preflight

The canonical physical host is Ubuntu 24.04 with systemd 255 or newer. The CI
fixture qualifies Chrony 4.5, linuxptp 4.0, systemd/udev 255.4, and the Ubuntu
`can-utils` package from the pinned snapshot. Time-source selection,
interfaces, PTP domain, and acceptance thresholds remain site configuration.

Install `config/time/chrony-command-socket.conf` as
`/etc/chrony/conf.d/robotics-command-socket.conf` and
`tmpfiles.d/robotics-time.conf` as `/etc/tmpfiles.d/robotics-time.conf`. Run
`systemd-tmpfiles --create` and restart Chrony. Install the sampler (requires
host `bash`, `jq`, `chronyc`, and coreutils) and both
`systemd/robotics-chrony-sample.*` units under `/etc/systemd/system`:

```bash
sudo install -d /usr/local/libexec/robotics-time
sudo install -m 0755 scripts/time/sample.sh /usr/local/libexec/robotics-time/
sudo install -m 0644 scripts/time/normalize-sample.jq /usr/local/libexec/robotics-time/
sudo install -m 0644 systemd/robotics-chrony-sample.* /etc/systemd/system/
sudo systemctl daemon-reload
sudo systemctl enable --now robotics-chrony-sample.timer
```

Start the evidence collector:

```bash
export ROBOTICS_CHRONY_IDENTITY="$(id -u _chrony):$(id -g _chrony)"
export ROBOTICS_TIME_EVIDENCE_DIR=./runs/current/time-evidence
sudo install -d -o "$(id -u _chrony)" -g "$(id -g _chrony)" \
  -m 0770 "${ROBOTICS_TIME_EVIDENCE_DIR}"
sudo chronyc -h /run/robotics-time/chronyd.sock tracking
sudo chronyc -h /run/robotics-time/chronyd.sock sources
docker compose -f compose.yaml -f compose.time.yaml \
  --profile time-chrony up -d time-evidence-chrony
```

The fragment changes the Unix command socket to
`/run/robotics-time/chronyd.sock` and disables the UDP command port with
`cmdport 0`; it does not add a second Unix socket. Host monitoring and any
`chrony-wait.service` or site script using `chronyc` must use this path as
well. Review those commands before restarting Chrony. See the
[Chrony 4.5 command-access documentation](https://chrony-project.org/doc/4.5/chrony.conf.html#bindcmdaddress).
`ROBOTICS_TIME_SOCKET_DIR` defaults to `/run/robotics-time`; the collector runs
as `ROBOTICS_CHRONY_IDENTITY` and reads the sampler's `chrony.log` in that
directory. The sampler obtains the original reference timestamp from
[`chronyc -c tracking`](https://chrony-project.org/doc/4.5/chronyc.html#tracking);
the Collector chrony receiver does not expose that timestamp.

For PTP, install `config/time/ptp4l.conf` through host configuration
management and install both `systemd/robotics-ptp-sample.*` units under
`/etc/systemd/system`, using the same sampler installed above. The timer
queries `TIME_STATUS_NP` and `TIME_PROPERTIES_DATA_SET` through the read-only
`ptp4lro` socket. Hardware timestamps use the reported, valid UTC offset to
convert `ingress_time` from the PTP timescale; software timestamping is not
supported by this sampler. Unknown timescales are rejected.

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now robotics-ptp-sample.timer
export ROBOTICS_CHRONY_IDENTITY="$(id -u _chrony):$(id -g _chrony)"
export ROBOTICS_TIME_EVIDENCE_DIR=./runs/current/time-evidence
sudo install -d -o "$(id -u _chrony)" -g "$(id -g _chrony)" \
  -m 0770 "${ROBOTICS_TIME_EVIDENCE_DIR}"
docker compose -f compose.yaml -f compose.time.yaml \
  --profile time-ptp up -d time-evidence-ptp
```

Both examples write `runs/current/time-evidence/hardware-time.otlp.json` with clock
offset in milliseconds, drift in ppm, message age in milliseconds, and a
monotonic-clock flag. `ptp4l` and `phc2sys` remain host services; the collectors
receive no network device, PHC device, or Linux capability.
Use one time collector per output directory: both use the same filename.
Message age is measured from the source timestamp, which is retained in the
`robotics.clock.sample_unix_ms` metric attribute. The physical-attach verifier
cross-checks that timestamp against reported age and rejects old or future
samples. Re-reading an old log cannot refresh its age. The one-second age
limit requires a source update interval suitable for that limit; a normal
long-poll NTP configuration may fail it legitimately.

Each sampler keeps its latest two complete records (`chrony.log[.1]` or
`pmc.log[.1]`) by atomic replacement. PTP Compose therefore mounts
`ROBOTICS_PTP_SAMPLE_DIR` (default `/run/robotics-time`), replacing the former
single-file `ROBOTICS_PTP_SAMPLE_FILE` mount. Use only one sampler per output
file. The monotonic flag still represents synchronization status, not proof
of hardware clock monotonicity. Linux collector/rotation integration and
physical timing qualification require CI and a live host run.

The hosted physical-attach test binds its synthetic target to the SPKI digest
of the generated SROS2 telemetry-source certificate. That identity proves the
CI authorization path only; it is not a hardware identity. Lab qualification
must instead bind the permit to the reviewed hardware identity kind and its
independently captured preflight evidence.

The positive synthetic authorization uses two ephemeral CI keys and real Rekor
entries. The CI-only `authorize-logged-test` command verifies the signatures and
log proofs against the embedded Sigstore trusted root, then applies the unchanged
execution policy and consumes the nonce. Its principals are limited to
`ci.operator` and `ci.approver` with the Cosign key issuer; they are not OIDC
identities. Signing requires access to public Rekor and publishes the synthetic
attestations. The explicit offline-bypass case must be denied without an output
or nonce consumption; it never substitutes for the positive path.

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

Create a structurally valid permit draft with the workspace's pinned contracts CLI,
review every
target and digest, then sign it with the documented Cosign flow:

```bash
scenario_sha256="$(sha256sum runs/current/input/scenario.yaml | cut -d' ' -f1)"
robotics-contracts permit init \
  --scenario-sha256 "${scenario_sha256}" \
  --subject-digest "${ROBOTICS_TARGET_IMAGE_DIGEST}" \
  --trust-policy-sha256 "${ROBOTICS_TRUST_POLICY_SHA256}" \
  --environment hil \
  --target-id controller-alpha \
  --identity-kind udev_serial \
  --identity-sha256 "${ROBOTICS_TARGET_IDENTITY_SHA256}" \
  --hardware-scope controller \
  --operator-id operator@example.org \
  --approver-id safety@example.org \
  --interlock-reference "${ROBOTICS_INTERLOCK_REFERENCE}" \
  --interlock-sha256 "${ROBOTICS_INTERLOCK_SHA256}" \
  --output runs/current/authorization/execution-permit.json
```

The command does not authorize execution and does not create or hold signing
keys. Physical profiles still require independent operator and safety-approver
attestations.

The `edge-attach`, `hil`, and `real-observation` services invoke the full verifier
with explicit run/domain identities, an acceptance run context and a writable
measurement-completion marker. Inputs and evidence are mounted read-only. Follow
the [attach run lifecycle](../docs/edge-attach.md) when preparing these files.
Foundation CI runs the default `edge-attach-observer` command against real Gazebo
and ROS, then requires a live `passed` result and verified qualification bundle.

Physical profiles remain preflight and observation candidates. Their separate
hosted test uses a ROS telemetry probe to exercise synthetic authorization and
SROS2 transport; it does not produce a full physical acceptance verdict. That
needs an approved scenario bound to the permit and hardware timing evidence
collected during the actual observation window. Preflight success is not product
or hardware qualification.

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

### Recorded playback completion

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
