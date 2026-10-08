# Retain the RKNN Toolchain Constraints Until Device Qualification

- Status: accepted
- Date: 2026-09-07

## Context and Problem Statement

The RK3588 candidate uses RKNN Toolkit2 and Runtime 2.3.2. Its converter pins
NumPy 1.26.4, ONNX 1.18.0 and the CPU PyTorch 2.4.0 wheel for Python 3.12.
The converter and runtime use Debian bookworm in `docker/rknn.Dockerfile`,
separately from the Ubuntu 24.04 ROS runtime. These are existing build inputs;
this record documents the constraint now and does not backdate qualification.

## Decision Drivers

- Preserve reproducible conversion and runtime inputs.
- Keep the converter's Python/ABI and model-format dependencies consistent.
- Require device evidence before claiming an accelerator upgrade works.

## Considered Options

- Update numerical libraries independently as their latest releases appear.
- Replace the vendor toolkit or move its base OS without a conversion gate.
- Retain the current pins and review upgrades as a complete toolchain change.

## Decision Outcome

Retain the pinned toolchain as a qualification-gated candidate. Treat the
versions in `docker/python/rknn-converter.in`, its hash lock, the runtime lock,
and the source revision in `docker/rknn.Dockerfile` as one review boundary.
This records the repository's constraint; it does not assert that upstream
forbids every other version. Renovate proposals are advisory and must not be
merged solely because an upstream version is newer or an image builds.

## Consequences

A proposed upgrade must verify source and wheel provenance, dependency
resolution, conversion of the retained test model, and inference/parity on a
named RK3588 device with retained evidence. Update both locks and the support
matrix together. Until that gate passes, support remains qualification-gated
and the older numerical-library pins are intentional technical constraints.
