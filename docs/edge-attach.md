# Attached acceptance observation

`compose.edge-attach.yaml` connects an observer to an existing Docker network.
It does not start a simulator or control a target. Set `ROBOTICS_ATTACH_NETWORK`
to that network and `ROS_DOMAIN_ID` to the target's ROS domain. The observer uses
the repository's Fast DDS UDP-only profile. `hil` and `real-observation` also
require the existing permit preflight, runtime materialization and SROS2 files.

An orchestration process owns this lifecycle:

1. Prepare the scenario in `ROBOTICS_RUN_INPUT_DIR/scenario.yaml`. Create its
   acceptance run with `robotics-acceptance create-run` before producing the
   runtime manifest and evidence. Save `acceptance-run.json` beside the scenario,
   export the returned `ROBOTICS_RUN_ID`, and set `ROBOTICS_DOMAIN_ID` to the
   declared acceptance domain. This identifier is distinct from `ROS_DOMAIN_ID`.
2. Produce the matching runtime manifest. Edge attach reads
   `ROBOTICS_RUN_INPUT_DIR/runtime-manifest.json`; physical profiles read the
   manifest materialized in `ROBOTICS_AUTHORIZATION_OUTPUT_DIR` after preflight.
   The physical permit must bind the exact scenario file bytes used by verify.
3. Create writable `ROBOTICS_RESULTS_DIR` and the evidence directory before
   starting the observer. For edge recordings, also create
   `ROBOTICS_EVIDENCE_DIR/recordings` before mounting the read-only evidence
   directory, and set `ROBOTICS_BAG_DIR` to the recorder's bag directory. Retain
   the same run identity in all producers. Use a fresh result directory per run.
4. Start the profile with its default command. The observer loads
   `/input/acceptance-run.json` and measures the live graph. Edge attach consumes
   `/evidence/metrics.otlp.jsonl`; physical profiles consume
   `/evidence/hardware-time.otlp.json`. Their evidence index lives at
   `/evidence/evidence-index.json` and must bind those actual metric bytes.
5. Wait for `ROBOTICS_RESULTS_DIR/measurement-complete`, also monitoring observer
   failure. Only then stop/flush the measurement producers and finalize the
   evidence index. The observer waits for finalized evidence before returning
   its verdict. Do not create the marker from the orchestration process.
6. Require exit 0, `acceptance-result.json` with `evaluation_mode: live` and
   `status: passed`, and the JUnit output. Exit 1 is a failed/incomplete verdict;
   exit 2 is an input or execution error, recorded in `diagnostic.json`.

`scripts/ci/foundation/run-edge-attach.sh` exercises this lifecycle against the
same real Gazebo, recorder and Collector used by the foundation acceptance path.
It uses a separate Compose project joined to the simulator's existing network,
executes the service's default `verify` command without replacing it with a
probe, and verifies the resulting aggregate and signed qualification bundle.
Cleanup checks cover both Compose projects.

The physical authorization fixture separately checks synthetic device evidence
and SROS2 access restrictions. It does not yet implement this complete lifecycle
with contemporaneous hardware metrics and a permit bound to its acceptance
scenario. A full physical verdict requires the approved scenario, contemporaneous hardware
metrics and the independently bound permit.

Physical profiles additionally require `authorization-output` to be owned by
UID/GID `10002:10002` with mode `0755`, and the persistent nonce store to be
owned by the same identity with mode `0700`. The nonce store is a security
boundary: do not place it on a shared or group-writable mount.

## Physical host preflight

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
`pmc.log[.1]`) by atomic replacement. PTP Compose mounts
`ROBOTICS_PTP_SAMPLE_DIR` (default `/run/robotics-time`). Use only one sampler
per output file. The monotonic flag represents synchronization status, not proof
of hardware clock monotonicity. Verify collector rotation in Linux CI and
qualify physical timing on the selected host.

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
the [attach run lifecycle](#attached-acceptance-observation) when preparing these files.
The synthetic authorization test exercises the permit and SROS2 boundary
with a ROS telemetry probe. The synthetic fixture does not establish a physical
acceptance verdict. Physical acceptance requires an approved scenario
bound to the permit and hardware timing evidence collected during the actual
observation window. Preflight success is not product or hardware qualification.

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
