# Compatibility Policy

## Supported Basis

The runtime basis is Ubuntu 24.04, ROS 2 Jazzy, and Gazebo Harmonic. Exact APT
snapshots, Python locks, base-image digests, and imported repository revisions
are build inputs. `release.env` is the OCI execution lock.

Support applies to a source revision, an image digest, a named Compose profile,
and a declared target. A successful image build does not qualify hardware.

## Foundation Generations

This source line is pinned to the following released pair:

| Infra consumer | Contracts | Harness | Document family |
| --- | --- | --- | --- |
| Current source / 0.8 release candidates | 0.15.4 (`>=0.15.4,<0.16`) | 0.17.1 (`>=0.17.1,<0.18`) | Legacy versioned roles, including `acceptance-scenario.v4`, emitted `runtime-manifest.v2`, `evidence-index.v3`, `qualification-bundle.v2` |
| Pending coordinated migration | 0.16.0 | 0.18.0 | Role catalog v1; incompatible with current infra producers and fixtures |

The ranges describe the compatibility boundary, not qualification of every
patch release. The exact tested input pins remain 0.15.4 / 0.17.1; see the
[foundation lock](foundation-compatibility.md). A package upgrade must pass
`foundation-integration` with its matching wheel hashes and imported commits.
The E2E-0 milestone is not claimed by this documentation change.

Contracts 0.16 reuses some schema names with different fields and removes
several legacy roles. In particular, permits change `image_digest` to
`subject_digest`, MCAP summaries become recording summaries, and the
qualification predicate changes from `/qualification-bundle/v2` to
`/qualification-bundle/v1`. Harness 0.18 also requires OTLP metrics evidence
with media type `application/x-ndjson`, while this infra line uses
`application/json`. Neither upgrading one package nor matching a
`schema_version` string establishes compatibility. The reusable workflows
also use the pinned foundation pair; newer consumer examples are not accepted
without migration of producers, fixtures, CLI arguments and validation.

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
