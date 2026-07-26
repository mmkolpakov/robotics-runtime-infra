# Qualification image publication

Hardware qualification consumes private, immutable images produced only by
`.github/workflows/publish-conformance-image.yml`. The workflow uses the
repository's `docker-bake.hcl`; the Bake target remains the single source of
stage arguments, build contexts, and target platforms.

## Publication

1. Merge the source revision to `main`.
2. Run **Publish conformance image** with the full source commit SHA and one
   target.
3. Record the immutable `ghcr.io/...@sha256:...` reference from the workflow
   summary.
4. Pass that reference and the same source SHA to **Hardware qualification**.

The publication workflow verifies that the requested revision belongs to
`origin/main`, builds from that exact checkout, emits BuildKit provenance and an
SBOM, publishes a GitHub artifact attestation, and verifies the attestation
before reporting the image reference.

The available publication targets are:

| Target | Published image | Qualification |
| --- | --- | --- |
| `nvidia-x86` | ONNX Runtime provider probe | CUDA provider and numerical parity |
| `nvidia-simulation-x86` | Simulation runtime | Headless EGL rendering and GPU lidar |
| `nvidia-sensor-inference-x86` | Sensor inference probe | Sensor-to-CUDA-to-OTLP path |
| `intel-native`, `intel-wsl` | ONNX Runtime provider probe | OpenVINO on the named host type |
| `amd-native` | ONNX Runtime provider probe | MIGraphX on the named host |
| `jetson-orin`, `jetson-thor` | ONNX Runtime provider probe | TensorRT on the named Jetson family |

The NVIDIA sensor-inference qualification is composed from two independently
published images from the same source SHA. Publish
`nvidia-sensor-inference-x86` and `nvidia-simulation-x86`, then pass the former
as `image_ref` and the latter as `support_image_ref`. Every other target rejects
a non-empty `support_image_ref`.

## Trust boundary

The hardware workflow accepts only:

- every supplied image reference in the repository owner's GHCR namespace with
  a SHA-256 digest;
- a source revision reachable from `main`;
- a GitHub attestation for each image whose source digest and source ref match
  the requested revision;
- a signer workflow listed in the protected environment variable
  `ROBOTICS_ATTESTATION_SIGNER_WORKFLOW`.

The conformance package may remain private. Release images and hardware support
claims are separate outputs and are not created by this workflow.
