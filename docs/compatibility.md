# Compatibility Policy

## Selected architecture and qualification boundary

Architecture C is the selected target: the public Python contracts/harness,
an upstream Cordis host, and separate simulator providers. Its implementation
and combined execution qualification are pending. The retained ROS v1 profile
keeps the supported basis below. Native providers require separate environment
and capability evidence; the common host does not require ROS or Gazebo.

[The qualification baseline](qualification-baseline.md) separates current
source, accepted R9, published R10 and the failed B3 released caller. B3 remains
open: native entity checks passed, but strict stepped Clock failed and
JointState readiness timed out. No later architecture claim closes those gates.

## Supported Basis

The runtime basis is Ubuntu 24.04, ROS 2 Jazzy, and Gazebo Harmonic. Exact APT
snapshots, Python locks, base-image digests, and imported repository revisions
are build inputs. `release.env` is the OCI execution lock.

Support applies to a source revision, an image digest, a named Compose profile,
and a declared target. A successful image build does not qualify hardware.

## Foundation Generations

The legacy 0.8 source line used contracts 0.15.4 and harness 0.17.1 with
`acceptance-scenario.v4`, emitted `runtime-manifest.v2`, `evidence-index.v3`, and
`qualification-bundle.v2`. It remains a distinct generation.

The current source foundation builds contracts 0.18.2 and harness 0.19.1 from
the single workspace commit in
[the generated foundation lock](foundation-compatibility.md). Both packages
are published. The release-bound pin checks that the harness tag matches the
commit and the contracts source tree matches its tag; publication and running
foundation qualification are separate checks.

The released infra `v0.9.0-rc.1` uses contracts 0.18.1 and harness 0.19.0. Its
stock UInt64 simulation profile passed released-mode qualification and independent
consumer verification. The historical `v0.8.0-rc.1` belongs to the legacy generation.

The published infra `v0.10.0-rc.1` contains the
[neutral robot fixture](../examples/neutral-robot/README.md) from infra commit
`d6dc8a1c6b976faacab7b371821e9af54b9883c2`. Its contracts 0.18.2 and harness
0.19.1 come from runtime workspace commit
`dc02c62897372514537cf241f06dc71b9f960c44`, recorded in the foundation lock.
Published image provenance, source integration and independent qualification of
a released consumer are separate gates. These software checks do not qualify
named hardware targets. The neutral robot released B3 attempt
`37157837270` failed and its independent consumer was skipped; R10 publication
is not accepted B3 qualification. Caller and tooling SHAs are recorded in
[the baseline](qualification-baseline.md).

The new generation uses `subject_digest` in permits, recording summaries,
qualification predicate `/qualification-bundle/v1`, and OTLP metrics with
media type `application/x-ndjson`. Neither upgrading one package nor matching
a `schema_version` string establishes compatibility. Reusable workflows use
the exact same workspace lock and therefore participate in the migration.
The `documents` input to `reusable-validate-documents.yml` changes from bare
paths to explicit `SCHEMA=PATH` entries. Update callers when changing their
infra commit pin; document-provided discriminators no longer select the role
that the workflow validates.

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
  requires a new schema major and migration notes. The historical 0.15 / 0.16
  name reuse above is a migration hazard, not evidence of compatibility.
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
