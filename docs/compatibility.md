# Compatibility Policy

## Product and qualification boundary

Public contracts and evaluation are independent of the application host and
simulator providers. Each native provider defines its environment, assets and
accepted operations. Installing packages or building an image does not qualify
hardware or every combination of components.

The retained ROS profile uses Ubuntu 24.04, ROS 2 Jazzy and Gazebo Harmonic.
APT snapshots, Python locks, base-image digests and source revisions are explicit
build inputs. `release.env` is the immutable OCI execution lock.

## Package and release generations

The source foundation and published `v0.11.0-rc2` images use contracts 0.19.0 and
harness 0.20.0 from the exact workspace in the
[foundation lock](foundation-compatibility.md). The newer public harness release
is not an automatic image repin; the selected cohort requires its own validation.

The [qualification reference](qualification-baseline.md) records accepted
Docker execution and independent consumption of this release. Package identity,
image provenance, native execution and retained-result verification are separate
checks. Caller/tooling commits can differ from the attested image-source commit.

Older releases retain their own package generations. `v0.9.0-rc.1` used contracts
0.18.1/harness 0.19.0; `v0.10.0-rc.1` used contracts 0.18.2/harness 0.19.1.
The legacy 0.8 source line used contracts 0.15.4/harness 0.17.1 with
`acceptance-scenario.v4`, `runtime-manifest.v2`, `evidence-index.v3` and
`qualification-bundle.v2`. Those records are not interchangeable with the current
contracts. A matching `schema_version` string alone does not establish compatibility.

Current reusable document validation accepts explicit `SCHEMA=PATH` roles;
document-provided discriminators do not select the role. Recordings use
`dataset-manifest.v2` for complete native bags and ordered members. Full playback
acceptance remains scoped to the actual recorded type, native player, time and
environment in the qualification reference.

## Hardware Dependency Limits

NVIDIA [JetPack 7.2](https://developer.nvidia.com/embedded/jetpack/downloads/archive-7.2)
ships CUDA 13.2.1 and TensorRT 10.16.2. The current Jetson candidate builds
against CUDA 13.3 and TensorRT 11. These are distinct inputs; compatibility
with a stock JetPack host has not been qualified.

The RKNN converter intentionally pins Toolkit2 2.3.2, NumPy 1.26.4,
ONNX 1.18.0 and the CPU PyTorch 2.4.0 wheel in
`docker/python/rknn-converter.in`. `docker/rknn.Dockerfile` uses Python 3.12
on Debian bookworm, an exception to the Ubuntu runtime basis. These pins form
the current vendor-toolchain candidate, not a promise that newer versions
are compatible or that every pin is an upstream requirement. Upgrade the
converter and RKNN runtime together after source/wheel checks, model
conversion, and retained RK3588 device inference evidence. A successful image
build alone does not authorize that upgrade.
The constraint and its upgrade gate are recorded in
[ADR-0005](decisions/0005-retain-rknn-toolchain-constraints.md).

## Public Surfaces

The public surfaces are:

- published OCI image names and entry points;
- Compose service, profile, environment, volume, and network names documented
  in `README.md`;
- files under `/usr/share/robotics-runtime/`;
- ROS packages installed by the simulation and edge images;
- the `/simulator` ROS 2 `simulation_interfaces` service boundary and `/clock`;
- reusable workflows documented in `README.md`, when called by exact commit SHA;
- machine-readable documents defined by `robotics-runtime-contracts`.

Files under `test/`, implementation stages in `Dockerfile`, and local image
tags are not stable APIs.

## Change Rules

- Patch releases may fix implementation and security defects without changing
  a public document or Compose contract.
- Minor releases may add optional profiles, services, document versions, and
  image targets. Existing released profiles continue to resolve.
- Removing or changing a documented service, environment variable, ROS
  interface, or artifact meaning requires a major release.
- Within one published schema name, changes must be additive. Removing or
  requiring fields, narrowing accepted values, or changing artifact meaning
  requires a new schema major and migration notes. Historical schema-name reuse is a
  migration hazard, not evidence of compatibility.
- The retained ROS v1 Jazzy/Harmonic basis remains fixed for this major line.
  Changing that profile's ROS distribution or simulator family starts a new
  major compatibility line and repeats qualification. A separate optional
  native provider preserves the existing profile and requires its own
  declared environment, capabilities and execution qualification.

## Consumers

Consumers inherit released images by digest, retain
`/usr/share/robotics-runtime/foundation.repos`, and keep product code in their
own image and Compose overlay. Consumer CI validates its scenario and runtime
manifest against the exact contracts revision recorded in the image.

Accelerator, HIL, and real-observation support remains
qualification-gated until the named host produces retained evidence.

### Finite retained log evidence

The Engine metadata provider also exposes a narrow read-only `readLogs` operation for a previously
observed exact container ID. It uses the same Unix socket and selected API version, verifies native
run/project labels and the framing flag, and sets follow=false. Tail lines, bytes and deadline are
finite validated bounds. Ownership and bounds are copied before asynchronous work, so caller
mutation cannot expand the request. Raw bytes and framing are retained; any view uses the native
Dockerode modem demultiplexer. No Engine exec/start/stop/copy operation is exposed.

Unavailable or removed containers, wrong ownership, missing framing, empty retained logs, exceeded
limits, deadline and cancellation reject the read with diagnostics. The caller must report
incomplete evidence; an empty successful stdout is not substituted. A recorded source-profile
check exercised a real six-test worker with contracts0.18.2/harness0.19.1, raw framed bytes,
foreign run/project refusal,
byte cap1, deadline0 and actual1ms, missing exactID, cancellation, and immediate caller mutation of
owner/byte limits. Actual cleanup inventory was empty. This evidence-read boundary does not qualify
a live collector or broaden the Dockerode library compatibility claim.
