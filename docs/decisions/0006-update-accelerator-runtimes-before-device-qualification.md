# Update Accelerator Runtimes Before Device Qualification

- Status: accepted
- Date: 2026-09-30

## Context and Problem Statement

ONNX Runtime and the RKNN toolchain receive fixes that the accelerator images
should not wait for, but no RK3588, Jetson, AMD or NVIDIA device is available
for qualification. [ADR 0005](0005-retain-rknn-toolchain-constraints.md) keeps
RKNN upgrades behind a device gate.

## Decision Drivers

- Keep accelerator images on maintained runtime releases.
- Qualify every update with the evidence that exists without devices.
- Never report device support that no device run has shown.

## Considered Options

- Hold all accelerator updates until devices are available.
- Update and treat a successful image build as qualification.
- Update with host-side qualification and keep device qualification pending.

## Decision Outcome

Update with host-side qualification and keep device qualification pending.
An accelerator runtime update is accepted when its artifacts are hash-locked
from the publisher and CI passes the checks that do not need a device:

- ONNX Runtime CPU execution provider identity and tensor parity;
- CUDA, OpenVINO and MIGraphX provider loading in their image jobs;
- RKNN Toolkit2 conversion of the retained example model and RKNN simulator
  output parity with ONNX Runtime on x86;
- amd64 and arm64 image builds, the arm64 ones under QEMU in CI.

This supersedes the device gate in ADR 0005 for dependency updates inside the
RKNN Toolkit2 2.3.2 constraints. A toolkit or runtime version change still
needs this ADR's checks plus a device run before support is claimed.

## Consequences

Device qualification remains pending for every accelerator target, and the
support matrix says so. The first run on each device must retain its evidence
and may revert an update.

RKNN Toolkit2 2.3.2 reads `onnx.mapping`, which ONNX removed in 1.19, so the
converter stays on ONNX 1.18; its vendor requirements also cap NumPy at 1.26.4,
PyTorch at 2.4.0 and Protobuf at 4.25.4. The RKNN supply-chain check enforces
the ONNX bound.
