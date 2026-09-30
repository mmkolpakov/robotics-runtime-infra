# Qualify Accelerator Updates Before Device Access

- Status: accepted
- Date: 2026-09-30

## Context and Problem Statement

The NVIDIA, Jetson and RK3588 inference paths are qualification-gated, and no
protected device runner exists yet. Holding their dependencies until a device
can qualify them left the images behind their upstream releases and kept
known advisories: the RKNN converter pinned onnx 1.18.0, protobuf 4.25.4 and
torch 2.4.0, all with published advisories.

RKNN Toolkit2 2.3.2 is the newest vendor release on GitHub and PyPI. Its
package metadata caps protobuf at 4.25.4, torch at 2.4.0 and NumPy at 1.26.4.
Its compiled modules import `pkg_resources`, which setuptools 82 removed, and
read `onnx.mapping`, which onnx 1.19 removed. RKNN Toolkit Lite2 also imports
`pkg_resources`.

## Decision Drivers

- Remove known advisories without waiting for devices.
- Back every update with a check that runs without devices.
- Keep the remaining device qualification explicit and runnable.

## Considered Options

- Hold the pins until a device qualifies them.
- Update, qualify with the available software checks, and keep device
  qualification pending.
- Replace the vendor toolkit.

## Decision Outcome

Update and qualify with the available software checks. Support rows stay
Qualification-gated until the device procedure below passes.

For the RK3588 converter environment:

- onnx 1.23.1, protobuf 6.33.6, ONNX Runtime 1.30.0 and CPU torch 2.14.0.
  Versions above the toolkit's declared caps are set in
  `docker/python/rknn-converter.overrides`. The image accepts exactly the
  `uv pip check` findings listed in `docker/python/rknn-converter.pip-check`
  and fails on any other.
- protobuf 7 is excluded: the toolkit reads `FieldDescriptor.label`, which
  protobuf 7 removed.
- NumPy stays 1.26.4. setuptools 81.0.0 is the newest release that still
  ships `pkg_resources`. Its advisory CVE-2026-59890 concerns building source
  distributions, which neither image does.
- `docker/python/rknn_onnx_mapping_compat.py` restores the two `onnx.mapping`
  tables the toolkit reads, with the onnx 1.18 values. A `.pth` file loads it
  in the converter environment only.

The RK3588 runtime environment moves to setuptools 81.0.0 for the same
`pkg_resources` requirement.

Checks that run without devices:

| Path | Check | Where |
| --- | --- | --- |
| RK3588 converter | Vendor `onnx_edit` example; 16-bit and 8-bit conversions run on the RKNN simulator and compared with the ONNX Runtime CPU provider (`probes/rknn_simulator_conformance.py`) | `rknn-converter-verification`, CI job `rknn-supply-chain` |
| RK3588 runtime | ARM64 image build under emulation, `uv pip check`, `rknnlite` import | CI job `rknn-arm64-image` |
| ONNX Runtime CPU | `provider-conformance-cpu`: provider identity, no fallback, tensor parity | CI job `integration` |
| ONNX Runtime CUDA on amd64 | Image build and `CUDAExecutionProvider` availability without a GPU | CI job `nvidia-image` |
| Jetson | Verification of the pinned ONNX Runtime source; the image is not built in CI | CI job `nvidia-jetson-supply-chain` |

A workstation GPU, including one under WSL2, may run the provider test before
a merge. The pull request records that evidence; it does not qualify a
target.

Device qualification that remains pending:

| Target | Procedure |
| --- | --- |
| NVIDIA GPU on amd64 Linux | Publish the conformance image with `publish-conformance-image.yml` (target `nvidia-x86`), then dispatch `hardware-qualification.yml` from `main` with `target=nvidia-x86`, the image reference by digest and the source SHA. It runs on a runner labelled `robotics-nvidia-gpu` in the `accelerator-nvidia` environment. |
| Jetson Orin or Thor | The same with target `jetson-orin` or `jetson-thor` and runner label `robotics-jetson-orin` or `robotics-jetson-thor`. |
| RK3588 | The generic hardware workflow has no RK3588 target. On a board with the RKNPU driver, run the published `provider-conformance-rknn-rk3588` image by digest: `RKNN_CONFORMANCE_IMAGE=<ref@digest> ROBOTICS_RKNN_RENDER_GID="$(getent group render \| cut -d: -f3)" docker compose -f compose.yaml -f compose.rknn.yaml --profile rknn-rk3588 run --rm provider-conformance-rknn-rk3588`. Then convert a model with the converter image, run it on the NPU and compare the outputs with the simulator report for the same inputs. |

Retain the image digests, command output and both reports as the
qualification record before changing a support row.

## Consequences

- The compatibility module, the overrides and the accepted `uv pip check`
  findings are removed once an RKNN Toolkit2 release supports the current
  dependencies. Dependency updates to these pins must pass the same checks.
- Simulator agreement qualifies the converter environment, not NPU execution
  or timing.
- This supersedes ADR 0005, which held the RKNN pins until device
  qualification.
