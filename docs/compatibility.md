# Compatibility Policy

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

This integration branch builds both packages from the single workspace commit
in [the generated foundation lock](foundation-compatibility.md). The current
source candidate is contracts 0.17.0rc1 with harness metadata 0.18.0; it is not
a claim that contracts 0.17 / harness 0.19 have been published or qualified.
All producer and fixture changes must land in the same integration PR before
that branch is accepted. The E2E-0 milestone remains pending.

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
- The Jazzy/Harmonic basis remains fixed for this major line. A ROS
  distribution or simulator family change starts a new major compatibility
  line and repeats qualification.

## Consumers

Consumers inherit released images by digest, retain
`/usr/share/robotics-runtime/foundation.repos`, and keep product code in their
own image and Compose overlay. Consumer CI validates its scenario and runtime
manifest against the exact contracts revision recorded in the image.

Accelerator, HIL, and real-observation support remains
qualification-gated until the named host produces retained evidence.
