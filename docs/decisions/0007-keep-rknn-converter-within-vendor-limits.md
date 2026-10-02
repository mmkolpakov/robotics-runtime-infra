# Keep RKNN Converter Dependencies Within Vendor Limits

- Status: accepted
- Date: 2026-10-02

## Context and Problem Statement

RKNN Toolkit2 2.3.2 remains the latest Rockchip release. Its CPython 3.12
requirements cap protobuf at 4.25.4, torch at 2.4.0 and NumPy at 1.26.4.
The compiled toolkit reads `onnx.mapping`, removed in ONNX 1.19, and imports
`pkg_resources`, removed in setuptools 82. Updating those dependencies would
require overriding vendor metadata and restoring a removed ONNX API.

## Decision Outcome

Keep the existing converter lock: ONNX 1.18.0, protobuf 4.25.4, CPU torch
2.4.0, NumPy 1.26.4, ONNX Runtime 1.26.0 and setuptools 80.10.2. Keep
Toolkit2, Lite2 and `librknnrt.so` from vendor v2.3.2, commit
`42aa1d426c0a9e0869b6374edba009f7208a1926`. Require a successful `uv pip check`
without dependency overrides, accepted conflicts or startup compatibility code.

Wait for a vendor release that removes these compatibility requirements before
updating the constrained dependencies. Modern training and export environments
can produce trusted ONNX artifacts separately; they do not share this venv.
Matching package metadata is not a vendor support guarantee: Rockchip lists
Ubuntu 24.04 for Python 3.12, whereas this converter uses Debian Bookworm.

`rknn-converter-verification` verifies the vendor fixture hashes, converts the
`onnx_edit` model, and compares FP16 and INT8 simulator outputs with the ONNX
Runtime CPU provider. It runs as a non-root user with the build step's network
disabled. The check requires the native `upb` protobuf backend and records the
backend and package versions in both reports.

## Security and Qualification Limits

These pins retain known advisories. The native-backend assertion establishes
one applicability condition; it does not clear the dependency scan:

- Protobuf CVE-2025-4565 affects the pure-Python backend, which this fixture
  check rejects. CVE-2026-0994 affects nested `Any` messages parsed through
  `json_format.ParseDict`; binary ONNX fixture loading does not exercise that
  JSON API. These observations do not cover arbitrary converter scripts.
- Torch CVE-2025-32434 and CVE-2026-24747 affect loading malicious checkpoints
  with `torch.load(..., weights_only=True)`. This check loads the hashed ONNX
  fixture. It does not establish that arbitrary PyTorch models are safe.
- ONNX 1.18.0 retains model-processing advisories, including external-data
  traversal and unsafe version-converter adapters. Only trusted model and
  calibration artifacts belong in this converter. A non-root container does
  not protect files or secrets deliberately mounted into it, and this image
  does not impose runtime network or resource limits on arbitrary invocations.
- Setuptools CVE-2026-59890 concerns Unicode-sensitive exclusions when building
  source distributions. The fixture check does not build source distributions.

Keep the existing HIGH/CRITICAL vulnerability gates and their full reports.
This decision adds no vulnerability suppression or scan exemption. The current
RKNN image scan covers the tagged ARM64 runtime targets; the converter
verification target is untagged and is not included in that image scan.
Publishing or widening use of the converter requires its own image scan and
assessment of applicable findings. Such findings remain blockers under the
existing vulnerability policy.

Simulator agreement is evidence for one model and input set. It does not
qualify all supported operators, dtype mappings, direct PyTorch import, NPU
execution or latency. RK3588 qualification remains pending until the locked
runtime and a model produced by this converter execute on the NPU and their
outputs are compared with the simulator for the same inputs.

## References

- [Rockchip release v2.3.2](https://github.com/airockchip/rknn-toolkit2/releases/tag/v2.3.2)
- [Vendor CPython 3.12 requirements](https://github.com/airockchip/rknn-toolkit2/blob/42aa1d426c0a9e0869b6374edba009f7208a1926/rknn-toolkit2/packages/x86_64/requirements_cp312-2.3.2.txt)
- [Vendor platform matrix](https://pypi.org/project/rknn-toolkit2/2.3.2/)
- [ONNX 1.19 breaking changes](https://github.com/onnx/onnx/releases/tag/v1.19.0)
- [Setuptools removal of pkg_resources](https://setuptools.pypa.io/en/latest/history.html#v82-0-0)
- [Protobuf pure-Python advisory](https://github.com/protocolbuffers/protobuf/security/advisories/GHSA-8qvm-5x2c-j2w7)
- [Protobuf JSON recursion fix](https://github.com/protocolbuffers/protobuf/pull/25239)
- [Torch checkpoint advisory, 2025](https://github.com/pytorch/pytorch/security/advisories/GHSA-53q9-r3pm-6pq6)
- [Torch checkpoint advisory, 2026](https://github.com/pytorch/pytorch/security/advisories/GHSA-63cw-57p8-fm3p)
- [ONNX advisories](https://github.com/onnx/onnx/security/advisories)
- [Setuptools source-distribution advisory](https://github.com/pypa/setuptools/security/advisories/GHSA-h35f-9h28-mq5c)
