# syntax=docker/dockerfile:1.19

ARG ROS_BASE_IMAGE=ros:jazzy-ros-base@sha256:31daab66eef9139933379fb67159449944f4e2dcf2e22c2d12cc715f29873e0f
ARG SIMULATION_BASE_IMAGE=osrf/ros:jazzy-simulation@sha256:acb7c427deb2aaa5acd0fdfa5f6cca9ad2055a64102b4667986b70d550dc469d
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa
ARG UBUNTU_BASE_IMAGE=ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90
ARG RCLONE_IMAGE=rclone/rclone:1.74.4@sha256:c61954aaa32328a5486715dd063a81c7879f5195ad3505cd362deddd509dc4a1
ARG AWS_CLI_IMAGE=public.ecr.aws/aws-cli/aws-cli:2.35.21@sha256:238583846e731f31c9848dae26c5a560769ff35c4c5368a4cb6be5816683e485
ARG GO_BUILDER_IMAGE=golang:1.26.5@sha256:079e59808d2d252516e27e3f3a9c003740dee7f75e55aa71528766d52bcfc16a
ARG NVIDIA_CUDA_BASE_IMAGE=nvidia/cuda:13.3.0-cudnn-runtime-ubuntu24.04@sha256:95c91edfddb448d236689f572725b8421f3e51a6808f11e37ba6834dc57b12c8
ARG NVIDIA_CUDA_RUNTIME_IMAGE=nvidia/cuda:13.3.0-runtime-ubuntu24.04@sha256:789e629e49401647e22b7054ae9c6c4f6427dba68010ba428deb4cc6b063676e
ARG NVIDIA_INFERENCE_DEVEL_IMAGE=nvcr.io/nvidia/cuda-dl-base:26.06-cuda13.3-inference-devel-ubuntu24.04@sha256:8d74c381b9842610edcd770dd2bfef12ff37dc76a6fa283215a372db99fca5fc
ARG UBUNTU_SNAPSHOT=20260701T000000Z
ARG ROS_SNAPSHOT=2026-06-18
ARG ROSDISTRO_INDEX_REVISION=9f76014b84955f757306270d6860fa3bc1c30b57

FROM ${UV_IMAGE} AS uv
FROM ${RCLONE_IMAGE} AS rclone
FROM ${AWS_CLI_IMAGE} AS aws-cli
FROM ${NVIDIA_CUDA_BASE_IMAGE} AS nvidia-cuda-runtime
FROM ${NVIDIA_CUDA_RUNTIME_IMAGE} AS nvidia-cuda-runtime-minimal

FROM ${UBUNTU_BASE_IMAGE} AS onnxruntime-jetson-source-verification

# hadolint ignore=DL3022
COPY --from=onnxruntime-source VERSION_NUMBER /verification/VERSION_NUMBER
# hadolint ignore=DL3022
COPY --from=onnxruntime-source cmake/external/onnx/CMakeLists.txt /verification/onnx-CMakeLists.txt

RUN test "$(cat /verification/VERSION_NUMBER)" = "1.27.0" \
    && test -s /verification/onnx-CMakeLists.txt

FROM ${NVIDIA_INFERENCE_DEVEL_IMAGE} AS onnxruntime-jetson-build-dependencies

ARG UBUNTU_SNAPSHOT

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots

RUN export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
    && UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
      /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      cmake \
      libopenblas-dev \
      ninja-build \
      python3-dev \
      python3-numpy \
      python3-packaging \
      python3-pip \
      python3-setuptools \
      python3-wheel \
    && for binary in cmake g++ gcc ninja nvcc python3; do \
      command -v "${binary}"; \
    done \
    && rm -rf \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

ADD --checksum=sha256:21198380bfe97a868cf22448790e91ca17ba3a851b12772f5b8936ee7321bfb3 \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/sbsa/libcufft-13-3_12.3.0.29-1_arm64.deb \
    /tmp/cuda-packages/
ADD --checksum=sha256:7279508aa787cf9c95bc6ab82df7850da7ba0b8edba2efeb151993dd0d32bfd2 \
    https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2404/sbsa/libcufft-dev-13-3_12.3.0.29-1_arm64.deb \
    /tmp/cuda-packages/

RUN dpkg --install /tmp/cuda-packages/*.deb \
    && for spec in \
      cuda-culibos-dev-13-3=13.3.33-1 \
      cuda-toolkit-13-3-config-common=13.3.29-1 \
      cuda-toolkit-13-config-common=13.3.29-1 \
      cuda-toolkit-config-common=13.3.29-1 \
      libcufft-13-3=12.3.0.29-1 \
      libcufft-dev-13-3=12.3.0.29-1; do \
      package="${spec%%=*}"; \
      expected="${spec#*=}"; \
      actual="$(dpkg-query --show --showformat='${Version}' "${package}")"; \
      printf '%s=%s\n' "${package}" "${actual}"; \
      test "${actual}" = "${expected}"; \
    done \
    && test -f /usr/local/cuda/targets/sbsa-linux/include/cufft.h \
    && test -e /usr/local/cuda/targets/sbsa-linux/lib/libcufft.so \
    && rm -rf /tmp/cuda-packages

FROM onnxruntime-jetson-build-dependencies AS onnxruntime-jetson-wheel-build

ARG ONNXRUNTIME_SOURCE_REVISION=8f0278c77bf44b0cc83c098c6c722b92a36ac4b5
ARG ONNXRUNTIME_SOURCE_DATE_EPOCH=1781277122

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3022
COPY --from=onnxruntime-source / /src/onnxruntime
WORKDIR /src/onnxruntime

RUN --mount=type=cache,id=onnxruntime-1.27.0-cuda13.3-trt11-arm64-build,target=/src/onnxruntime/build/Linux,sharing=locked \
    --mount=type=cache,id=onnxruntime-1.27.0-arm64-pip,target=/root/.cache/pip,sharing=locked \
    test "$(cat /src/onnxruntime/VERSION_NUMBER)" = "1.27.0" \
    && test -f /src/onnxruntime/cmake/external/onnx/CMakeLists.txt \
    && test "${ONNXRUNTIME_SOURCE_REVISION}" = \
      "8f0278c77bf44b0cc83c098c6c722b92a36ac4b5" \
    && SOURCE_DATE_EPOCH="${ONNXRUNTIME_SOURCE_DATE_EPOCH}" \
      ./build.sh \
        --config Release \
        --update \
        --build \
        --parallel 2 \
        --build_wheel \
        --use_cuda \
        --use_tensorrt \
        --cuda_home /usr/local/cuda \
        --cudnn_home /usr/lib/aarch64-linux-gnu \
        --tensorrt_home /usr/lib/aarch64-linux-gnu \
        --nvcc_threads 1 \
        --allow_running_as_root \
        --skip_tests \
        --skip_submodule_sync \
        --cmake_extra_defines \
          "CMAKE_CUDA_ARCHITECTURES=87-real;110-real" \
          onnxruntime_BUILD_UNIT_TESTS=OFF \
          onnxruntime_USE_FLASH_ATTENTION=OFF \
          onnxruntime_USE_MEMORY_EFFICIENT_ATTENTION=OFF \
    && mapfile -t wheels < <(find build/Linux/Release/dist -maxdepth 1 \
      -type f -name '*.whl' -print) \
    && test "${#wheels[@]}" -eq 1 \
    && install -D -m 0444 "${wheels[0]}" "/out/$(basename "${wheels[0]}")" \
    && install -m 0444 LICENSE /out/LICENSE \
    && printf '%s\n' \
      "onnxruntime=v1.27.0" \
      "revision=${ONNXRUNTIME_SOURCE_REVISION}" \
      "cuda_architectures=87-real;110-real" \
      > /out/source.txt \
    && sha256sum /out/*.whl \
      | sed 's#  /out/#  #' > /out/SHA256SUMS

FROM scratch AS onnxruntime-jetson-wheel

COPY --from=onnxruntime-jetson-wheel-build /out /

FROM ${UBUNTU_BASE_IMAGE} AS rocm-signing-key
ADD --checksum=sha256:2de99e2354646a90d9903e2a669fc4e36b02c1bbff7075c481e12d7edab2c88b \
  https://repo.radeon.com/rocm/rocm.gpg.key \
  /rocm.asc

FROM ${UBUNTU_BASE_IMAGE} AS intel-gpu-packages
ADD --checksum=sha256:6c1fff18f5ea7ef23d3e5532750822363bf4688d342d09af31470329f54a83d6 \
  https://github.com/intel/intel-graphics-compiler/releases/download/v2.2.3/intel-igc-core-2_2.2.3%2B18220_amd64.deb \
  /packages/intel-igc-core-2_2.2.3+18220_amd64.deb
ADD --checksum=sha256:60e9e4de95b191fd9b49123e0d745c6071283a38e632059e9c4ffa935e99d4e7 \
  https://github.com/intel/intel-graphics-compiler/releases/download/v2.2.3/intel-igc-opencl-2_2.2.3%2B18220_amd64.deb \
  /packages/intel-igc-opencl-2_2.2.3+18220_amd64.deb
ADD --checksum=sha256:585de2bc881eaef17207449f2a6d5d7efb2b1680a6293546fcd01fc4a869812c \
  https://github.com/intel/compute-runtime/releases/download/24.48.31907.7/intel-level-zero-gpu_1.6.31907.7_amd64.deb \
  /packages/intel-level-zero-gpu_1.6.31907.7_amd64.deb
ADD --checksum=sha256:a3d0cf66868838951174918c61ee75e34537859309c79486e0b2a7b44cfe13a5 \
  https://github.com/intel/compute-runtime/releases/download/24.48.31907.7/intel-opencl-icd_24.48.31907.7_amd64.deb \
  /packages/intel-opencl-icd_24.48.31907.7_amd64.deb
ADD --checksum=sha256:48154eae949e17b5a1806aa5988f0013a490a062a5c62fa635d4a97ded442b26 \
  https://github.com/oneapi-src/level-zero/releases/download/v1.21.9/level-zero_1.21.9%2Bu24.04_amd64.deb \
  /packages/level-zero_1.21.9+u24.04_amd64.deb
ADD --checksum=sha256:a6adb750d17c8eb3c50a5b063115c762ffe57724cfbd45cc38e5abe823c49bd2 \
  https://github.com/intel/compute-runtime/releases/download/24.48.31907.7/libigdgmm12_22.5.4_amd64.deb \
  /packages/libigdgmm12_22.5.4_amd64.deb

# Rebuild the signed Cosign release source with the patched Go toolchain. The
# upstream v3.1.1 image was built with Go 1.26.3.
FROM --platform=${BUILDPLATFORM} ${GO_BUILDER_IMAGE} AS cosign
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TARGETOS
ARG TARGETARCH
ARG COSIGN_REVISION=7914231b348c4057891edeb321772aad3ed04fce
ARG COSIGN_SOURCE_DATE_EPOCH=1781007044
ARG COSIGN_VERSION=v3.1.1
# hadolint ignore=DL3022
COPY --from=cosign-source / /src/cosign
WORKDIR /src/cosign
RUN --mount=type=cache,id=cosign-v3.1.1-mod,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,id=cosign-v3.1.1-build,target=/root/.cache/go-build,sharing=locked \
    test "$(sed -n 's/^module //p' go.mod)" = \
      "github.com/sigstore/cosign/v3" \
    && test "$(sed -n 's/^go //p' go.mod)" = "1.26.0" \
    && test "${COSIGN_REVISION}" = \
      "7914231b348c4057891edeb321772aad3ed04fce" \
    && test "${COSIGN_SOURCE_DATE_EPOCH}" = "1781007044" \
    && go mod download \
    && go mod verify \
    && CGO_ENABLED=0 \
      GOOS="${TARGETOS}" \
      GOARCH="${TARGETARCH}" \
      go build \
        -trimpath \
        -ldflags "-buildid= \
          -X sigs.k8s.io/release-utils/version.gitVersion=${COSIGN_VERSION} \
          -X sigs.k8s.io/release-utils/version.gitCommit=${COSIGN_REVISION} \
          -X sigs.k8s.io/release-utils/version.gitTreeState=clean \
          -X sigs.k8s.io/release-utils/version.buildDate=2026-06-09T12:10:44Z" \
        -o /out/cosign \
        ./cmd/cosign \
    && install -m 0444 LICENSE /out/LICENSE \
    && printf '%s\n' \
      "cosign=${COSIGN_VERSION}" \
      "revision=${COSIGN_REVISION}" \
      "go=$(go version | awk '{print $3}')" \
      > /out/source.txt

# Build the exact OPA release with the upstream oras-go security update. The
# v1.18.2 release image predates Go 1.26.5 and oras-go v2.6.2.
FROM --platform=${BUILDPLATFORM} ${GO_BUILDER_IMAGE} AS opa
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG TARGETOS
ARG TARGETARCH
ARG OPA_REVISION=e695c9ef8edb0f8b9f13d014d7bc8a7fbcc57297
ARG OPA_SOURCE_DATE_EPOCH=1782998040
ARG OPA_VERSION=1.18.2
# hadolint ignore=DL3022
COPY --from=opa-source / /src/opa
WORKDIR /src/opa
RUN --mount=type=cache,id=opa-v1.18.2-mod,target=/go/pkg/mod,sharing=locked \
    --mount=type=cache,id=opa-v1.18.2-build,target=/root/.cache/go-build,sharing=locked \
    test "$(sed -n 's/^module //p' go.mod)" = \
      "github.com/open-policy-agent/opa" \
    && test "$(sed -n 's/^var Version = \"\(.*\)\"/\1/p' v1/version/version.go)" = \
      "${OPA_VERSION}" \
    && test "$(cat .go-version)" = "1.26.4" \
    && test "$(sed -n 's#^[[:space:]]*oras.land/oras-go/v2 v##p' go.mod)" = \
      "2.6.1" \
    && test "${OPA_REVISION}" = \
      "e695c9ef8edb0f8b9f13d014d7bc8a7fbcc57297" \
    && test "${OPA_SOURCE_DATE_EPOCH}" = "1782998040" \
    && go get oras.land/oras-go/v2@v2.6.2 \
    && test "$(sed -n 's#^[[:space:]]*oras.land/oras-go/v2 v##p' go.mod)" = \
      "2.6.2" \
    && test "$(sed -n 's#^[[:space:]]*golang.org/x/sync v##p' go.mod)" = \
      "0.22.0" \
    && go mod download \
    && go mod verify \
    && CGO_ENABLED=0 go test -mod=readonly ./v1/download \
    && CGO_ENABLED=0 \
      GOOS="${TARGETOS}" \
      GOARCH="${TARGETARCH}" \
      go build \
        -mod=readonly \
        -trimpath \
        -ldflags "-buildid= -s -w \
          -X github.com/open-policy-agent/opa/v1/version.Vcs=${OPA_REVISION} \
          -X github.com/open-policy-agent/opa/v1/version.Timestamp=2026-07-02T13:14:00Z \
          -X github.com/open-policy-agent/opa/v1/version.Hostname=release" \
        -o /out/opa \
        . \
    && install -m 0444 LICENSE /out/LICENSE \
    && cp go.mod go.sum /out/ \
    && printf '%s\n' \
      "opa=v${OPA_VERSION}" \
      "revision=${OPA_REVISION}" \
      "go=$(go version | awk '{print $3}')" \
      "security_delta=oras.land/oras-go/v2@v2.6.2,golang.org/x/sync@v0.22.0" \
      "upstream_delta=3f0256edb298a5ebaff9adf1a34584a53278d051" \
      > /out/source.txt

# Rebuild the exact yq release source with the patched Go toolchain. The
# upstream release binary was built with a Go standard library below 1.26.5.
FROM --platform=${BUILDPLATFORM} ${GO_BUILDER_IMAGE} AS yq
ARG TARGETOS
ARG TARGETARCH
ARG YQ_REVISION=1b9b4ac5187171d2e5e3129be0cfa827c7f9d53d
ARG YQ_VERSION=v4.53.3
RUN --mount=type=cache,target=/go/pkg/mod \
    --mount=type=cache,target=/root/.cache/go-build \
    YQ_MODULE="github.com/mikefarah/yq/v4"; \
    YQ_MODULE_VERSION="$(go list -m -f '{{.Version}}' \
      "${YQ_MODULE}@${YQ_REVISION}")"; \
    go mod download "${YQ_MODULE}@${YQ_MODULE_VERSION}"; \
    YQ_SOURCE="$(go list -m -f '{{.Dir}}' \
      "${YQ_MODULE}@${YQ_MODULE_VERSION}")"; \
    go -C "${YQ_SOURCE}" mod download; \
    go -C "${YQ_SOURCE}" mod verify; \
    CGO_ENABLED=0 \
      GOOS="${TARGETOS}" \
      GOARCH="${TARGETARCH}" \
      go -C "${YQ_SOURCE}" build \
      -trimpath \
      -ldflags "-s -w \
        -X github.com/mikefarah/yq/v4/cmd.GitCommit=${YQ_REVISION} \
        -X github.com/mikefarah/yq/v4/cmd.GitDescribe=${YQ_VERSION}" \
      -o /out/yq \
      .; \
    install -m 0444 "${YQ_SOURCE}/LICENSE" /out/YQ-LICENSE

FROM ${UBUNTU_BASE_IMAGE} AS ubuntu-ca-amd64
ADD --checksum=sha256:e3b33fefcebc3ef8f3367572a1ffead2e8ddf7807aec1d442b843e50b70261f4 \
  https://snapshot.ubuntu.com/ubuntu/20260701T000000Z/pool/main/o/openssl/openssl_3.0.13-0ubuntu3.11_amd64.deb \
  /packages/openssl.deb
ADD --checksum=sha256:6bac2a01979e210d9eac1d4d56747ec709ea60654744d66705dc3c36e7629e50 \
  https://snapshot.ubuntu.com/ubuntu/20260701T000000Z/pool/main/c/ca-certificates/ca-certificates_20260601~24.04.1_all.deb \
  /packages/ca-certificates.deb

FROM ${UBUNTU_BASE_IMAGE} AS ubuntu-ca-arm64
ADD --checksum=sha256:98961f09af294bdfb96a8a9418d48cba89efc9d2a7460975904484106071ae79 \
  https://snapshot.ubuntu.com/ubuntu/20260701T000000Z/pool/main/o/openssl/openssl_3.0.13-0ubuntu3.11_arm64.deb \
  /packages/openssl.deb
ADD --checksum=sha256:6bac2a01979e210d9eac1d4d56747ec709ea60654744d66705dc3c36e7629e50 \
  https://snapshot.ubuntu.com/ubuntu/20260701T000000Z/pool/main/c/ca-certificates/ca-certificates_20260601~24.04.1_all.deb \
  /packages/ca-certificates.deb

ARG TARGETARCH
# hadolint ignore=DL3006
FROM ubuntu-ca-${TARGETARCH} AS ubuntu-ca
RUN dpkg --install /packages/openssl.deb /packages/ca-certificates.deb \
    && rm -rf \
      /packages \
      /var/cache/ldconfig/aux-cache \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

FROM ubuntu-ca AS time-fixture

ARG UBUNTU_SNAPSHOT

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
COPY --chmod=0444 config/time/chrony-fixture.conf /etc/chrony/chrony.conf

RUN export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
    && UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
      /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      chrony \
      linuxptp \
      systemd \
      udev \
    && chronyd -v \
    && pmc -v \
    && udevadm --version \
    && install -d -m 0755 /usr/share/robotics-runtime \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
      chrony linuxptp systemd udev \
      | sort > /usr/share/robotics-runtime/time-fixture-packages.tsv \
    && rm -rf \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

RUN truncate --size 0 /etc/machine-id

LABEL org.opencontainers.image.title="Host time qualification fixture" \
      org.opencontainers.image.description="Ubuntu 24.04 Chrony, LinuxPTP, systemd, and udev validation fixture."

STOPSIGNAL SIGTERM
CMD ["chronyd", "-d", "-x", "-f", "/etc/chrony/chrony.conf"]

FROM scratch AS geographiclib-datasets
ADD --checksum=sha256:c46224f8f723dc915d97179f4e1580a98d6c742fe2b82cd8fef0ecaaad13e614 \
  https://sourceforge.net/projects/geographiclib/files/geoids-distrib/egm96-5.tar.bz2/download \
  /datasets/egm96-5.tar.bz2
ADD --checksum=sha256:6fea4c6bd56ff8ac53dbdad8d5dd505c855471d0354c4abc5c5fe048bf8350c1 \
  https://sourceforge.net/projects/geographiclib/files/gravity-distrib/egm96.tar.bz2/download \
  /datasets/egm96.tar.bz2
ADD --checksum=sha256:8e71a9704c5f2714bb65581df68e30f0d84d0ad17286d00efb782e7232334c3f \
  https://sourceforge.net/projects/geographiclib/files/magnetic-distrib/emm2015.tar.bz2/download \
  /datasets/emm2015.tar.bz2

FROM ${UBUNTU_BASE_IMAGE} AS mcap-amd64
ADD --checksum=sha256:53274b6ca922e2078daa02ae32aed75da046f78d6c3da9dc19065254be24b483 \
  https://github.com/foxglove/mcap/releases/download/releases%2Fmcap-cli%2Fv0.2.0/mcap-linux-amd64 \
  /mcap
RUN chmod 0555 /mcap

FROM ${UBUNTU_BASE_IMAGE} AS mcap-arm64
ADD --checksum=sha256:983af5f0d6b4e845ab0b4923f1505a992a3199a8bf797ee3afd78c1c8700a6fd \
  https://github.com/foxglove/mcap/releases/download/releases%2Fmcap-cli%2Fv0.2.0/mcap-linux-arm64 \
  /mcap
RUN chmod 0555 /mcap

ARG TARGETARCH
# hadolint ignore=DL3006
FROM mcap-${TARGETARCH} AS mcap

FROM scratch AS policy-tooling

ARG IMAGE_CREATED=1970-01-01T00:00:00Z
ARG IMAGE_SOURCE=https://github.com/mmkolpakov/robotics-runtime-infra
ARG IMAGE_VERSION=0.5.0
ARG VCS_REF=local

LABEL org.opencontainers.image.title="Robotics policy tooling" \
      org.opencontainers.image.description="Pinned Open Policy Agent for repository and execution policy validation." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="Apache-2.0 AND MIT"

COPY --from=opa /out/opa /opa
COPY --from=opa /out/LICENSE /LICENSE
COPY --from=yq /out/yq /yq
COPY --from=yq /out/YQ-LICENSE /YQ-LICENSE
USER 65532:65532
ENTRYPOINT ["/opa"]
CMD ["version"]

FROM ubuntu-ca AS permit-preflight

ARG IMAGE_CREATED=1970-01-01T00:00:00Z
ARG IMAGE_SOURCE=https://github.com/mmkolpakov/robotics-runtime-infra
ARG IMAGE_VERSION=0.5.0
ARG VCS_REF=local

LABEL org.opencontainers.image.title="Robotics execution permit preflight" \
      org.opencontainers.image.description="Exact-identity Sigstore bundle verification for physical runtime permits." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT AND Apache-2.0"

ARG UBUNTU_SNAPSHOT

ENV HOME=/home/preflight \
    PATH="/opt/venv/bin:${PATH}"

COPY --from=cosign /out/cosign /usr/local/bin/cosign
COPY --from=cosign /out/LICENSE /usr/share/licenses/cosign/LICENSE
COPY --from=cosign /out/source.txt /usr/share/robotics-runtime/cosign-source.txt
COPY --from=opa /out/opa /usr/local/bin/opa
COPY --from=opa /out/LICENSE /usr/share/licenses/opa/LICENSE
COPY --from=opa /out/source.txt /usr/share/robotics-runtime/opa-source.txt
COPY --from=opa /out/go.mod /usr/share/robotics-runtime/opa-go.mod
COPY --from=opa /out/go.sum /usr/share/robotics-runtime/opa-go.sum
COPY --from=yq /out/yq /usr/local/bin/yq
COPY --from=uv /uv /uvx /usr/local/bin/
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
COPY docker/python/permit-preflight.lock /tmp/python/permit-preflight.lock
COPY --chmod=0444 policy/execution.rego /usr/share/robotics-runtime/policy/execution.rego
COPY --chmod=0555 docker/permit-preflight/permit-preflight /usr/local/bin/permit-preflight

RUN chmod 0555 /usr/share/robotics-runtime/policy

RUN export DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC \
    && UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
      /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && apt-get install -y --no-install-recommends python3 \
    && uv venv --python /usr/bin/python3 /opt/venv \
    && uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/permit-preflight.lock \
    && uv pip check --python /opt/venv/bin/python \
    && uv pip freeze --python /opt/venv/bin/python \
      > /usr/share/robotics-runtime/python-packages.txt \
    && python3 -c \
      "from robotics_runtime_contracts import schema_names; assert 'execution-permit.v2' in schema_names() and 'execution-verification.v1' in schema_names()" \
    && groupadd --gid 10002 preflight \
    && useradd --uid 10002 --gid 10002 --create-home preflight \
    && mkdir -p /work \
    && chown 10002:10002 /work \
    && rm -rf \
      /tmp/python \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

USER preflight
WORKDIR /work

RUN test -r /usr/share/robotics-runtime/policy/execution.rego \
    && opa fmt --list --fail /usr/share/robotics-runtime/policy/execution.rego

ENTRYPOINT ["/usr/local/bin/permit-preflight"]
CMD ["versions"]

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD ["/usr/local/bin/permit-preflight", "versions"]

FROM ubuntu-ca AS evidence-sink

ARG IMAGE_CREATED=1970-01-01T00:00:00Z
ARG IMAGE_SOURCE=https://github.com/mmkolpakov/robotics-runtime-infra
ARG IMAGE_VERSION=0.5.0
ARG VCS_REF=local
ARG UBUNTU_SNAPSHOT

LABEL org.opencontainers.image.title="Robotics evidence sink" \
      org.opencontainers.image.description="Validated MCAP segment upload and evidence-index finalization." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    HOME=/home/evidence

COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots

RUN UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
      /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      ca-certificates \
      inotify-tools \
      jq \
    && groupadd --gid 10001 evidence \
    && useradd --uid 10001 --gid 10001 --create-home evidence \
    && mkdir -p /usr/share/robotics-runtime \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
      | sort > /usr/share/robotics-runtime/deb-packages.tsv \
    && rm -rf \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

COPY --from=mcap /mcap /usr/local/bin/mcap
COPY --from=rclone /usr/local/bin/rclone /usr/local/bin/rclone
COPY --from=yq /out/yq /usr/local/bin/yq
COPY --from=aws-cli /usr/local/aws-cli /usr/local/aws-cli
RUN ln -s /usr/local/aws-cli/v2/current/bin/aws /usr/local/bin/aws

COPY --chmod=0555 docker/evidence-sink/evidence-sink /usr/local/bin/evidence-sink

USER evidence
WORKDIR /work

ENTRYPOINT ["/usr/local/bin/evidence-sink"]
CMD ["watch"]

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD ["/usr/local/bin/evidence-sink", "versions"]

FROM ${ROS_BASE_IMAGE} AS edge-runtime

ARG IMAGE_CREATED=1970-01-01T00:00:00Z
ARG IMAGE_SOURCE=https://github.com/mmkolpakov/robotics-runtime-infra
ARG IMAGE_VERSION=0.5.0
ARG VCS_REF=local
ARG UBUNTU_SNAPSHOT
ARG ROS_SNAPSHOT
ARG ROSDISTRO_INDEX_REVISION

LABEL org.opencontainers.image.title="Robotics edge runtime" \
      org.opencontainers.image.description="Multi-architecture ROS 2 Jazzy runtime without a simulator." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    RCUTILS_COLORIZED_OUTPUT=1 \
    RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    ROBOTICS_ROS_SNAPSHOT="${ROS_SNAPSHOT}" \
    ROBOTICS_UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
    ROSDISTRO_INDEX_URL="https://raw.githubusercontent.com/ros/rosdistro/${ROSDISTRO_INDEX_REVISION}/index-v4.yaml"

COPY docker/rosdeps/edge/package.xml /tmp/rosdep/edge/package.xml
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
COPY --chmod=0444 docker/apt/ros-snapshot-key.gpg /usr/share/keyrings/ros-snapshot-key.gpg
COPY --from=geographiclib-datasets /datasets /tmp/geographiclib

RUN UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
    ROS_DISTRO="${ROS_DISTRO}" \
    ROS_SNAPSHOT="${ROS_SNAPSHOT}" \
    ROSDISTRO_INDEX_REVISION="${ROSDISTRO_INDEX_REVISION}" \
      /usr/local/sbin/use-package-snapshots \
    && export HOME=/root \
    && apt-get update \
    && rosdep update --rosdistro "${ROS_DISTRO}" \
    && rosdep install \
      --from-paths /tmp/rosdep \
      --ignore-src \
      --rosdistro "${ROS_DISTRO}" \
      -y \
    && tar -xjf /tmp/geographiclib/egm96-5.tar.bz2 -C /usr/share/GeographicLib \
    && tar -xjf /tmp/geographiclib/egm96.tar.bz2 -C /usr/share/GeographicLib \
    && tar -xjf /tmp/geographiclib/emm2015.tar.bz2 -C /usr/share/GeographicLib \
    && test -s /usr/share/GeographicLib/geoids/egm96-5.pgm \
    && test -s /usr/share/GeographicLib/gravity/egm96.egm.cof \
    && test -s /usr/share/GeographicLib/magnetic/emm2015.wmm.cof \
    && mkdir -p /usr/share/robotics-runtime \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
      | sort > /usr/share/robotics-runtime/deb-packages.tsv \
    && rm -rf \
      /tmp/rosdep \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/robotics-entrypoint
COPY --chmod=0555 docker/runtime/emit-runtime-manifest /usr/local/bin/emit-runtime-manifest

ENV HOME=/home/ubuntu \
    ROBOTICS_CONTRACTS_REVISION=576826d9fcdfe795dfc695ad44326610c023e94c \
    ROBOTICS_HARNESS_REVISION=e0fe6393a18211e28ebd5cf2774445962c72aee5 \
    ROBOTICS_INFRA_REVISION="${VCS_REF}"
USER ubuntu
WORKDIR /workspace

ENTRYPOINT ["/usr/local/bin/robotics-entrypoint"]
CMD ["bash"]

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["/usr/local/bin/robotics-entrypoint", "ros2", "pkg", "prefix", "mavros"]

FROM edge-runtime AS sensor-runtime

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY docker/rosdeps/sensor/package.xml /tmp/rosdep/sensor/package.xml

RUN export HOME=/root \
    && apt-get update \
    && rosdep update --rosdistro "${ROS_DISTRO}" \
    && rosdep install \
      --from-paths /tmp/rosdep \
      --ignore-src \
      --rosdistro "${ROS_DISTRO}" \
      -y \
    && apt-get install -y --no-install-recommends \
      gstreamer1.0-plugins-base \
      gstreamer1.0-plugins-good \
      gstreamer1.0-tools \
      v4l-utils \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
      | sort > /usr/share/robotics-runtime/deb-packages.tsv \
    && rm -rf \
      /tmp/rosdep \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

LABEL org.opencontainers.image.title="Robotics sensor runtime" \
      org.opencontainers.image.description="Portable ROS 2 image transport, OpenCV, GStreamer, and V4L2 runtime."

USER ubuntu

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["/bin/bash", "-lc", "ros2 pkg prefix cv_bridge && gst-launch-1.0 --version"]

FROM edge-runtime AS inference-cpu

USER root
COPY --from=uv /uv /uvx /usr/local/bin/
COPY docker/python/inference-cpu.lock /tmp/python/inference-cpu.lock

RUN uv venv --python /usr/bin/python3 --system-site-packages /opt/venv \
    && uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/inference-cpu.lock \
    && uv pip freeze --python /opt/venv/bin/python \
      > /usr/share/robotics-runtime/python-packages.txt \
    && rm -rf /tmp/python

ENV PATH="/opt/venv/bin:${PATH}"

LABEL org.opencontainers.image.title="Robotics CPU inference runtime" \
      org.opencontainers.image.description="Portable ONNX Runtime CPU provider on ROS 2 Jazzy."

USER ubuntu

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD ["python3", "-c", "import onnxruntime as ort; assert 'CPUExecutionProvider' in ort.get_available_providers()"]

FROM inference-cpu AS provider-conformance-cpu

USER root
COPY docker/python/provider-conformance.lock /tmp/python/provider-conformance.lock

RUN uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/provider-conformance.lock \
    && install -d -o ubuntu -g ubuntu /reports \
    && install -d -o root -g root -m 0555 /opt/provider-conformance \
    && rm -rf /tmp/python

COPY --chmod=0444 test/provider-conformance/test_provider.py /opt/provider-conformance/test_provider.py

ENV ROBOTICS_EXPECTED_PROVIDER=CPUExecutionProvider \
    ROBOTICS_PROVIDER_REPORT=/reports/provider-conformance.json

LABEL org.opencontainers.image.title="Robotics CPU provider conformance" \
      org.opencontainers.image.description="Release gate for ONNX Runtime provider identity, fallback, and tensor parity."

USER ubuntu
WORKDIR /opt/provider-conformance

ENTRYPOINT ["python3", "-m", "pytest"]
CMD ["-q", "-p", "no:cacheprovider", "--junitxml=/reports/provider-conformance.junit.xml", "test_provider.py"]

HEALTHCHECK NONE

FROM edge-runtime AS inference-intel

USER root
COPY --from=uv /uv /uvx /usr/local/bin/
COPY --from=intel-gpu-packages /packages /tmp/intel-gpu
COPY docker/python/inference-intel.lock /tmp/python/inference-intel.lock

RUN apt-get update \
    && apt-get install -y --no-install-recommends \
      clinfo \
      ocl-icd-libopencl1 \
      /tmp/intel-gpu/*.deb \
    && uv venv --python /usr/bin/python3 --system-site-packages /opt/venv \
    && uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/inference-intel.lock \
    && uv pip freeze --python /opt/venv/bin/python \
      > /usr/share/robotics-runtime/python-packages.txt \
    && rm -rf \
      /tmp/intel-gpu \
      /tmp/python \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

ENV PATH="/opt/venv/bin:${PATH}"

LABEL org.opencontainers.image.title="Robotics Intel inference runtime" \
      org.opencontainers.image.description="ONNX Runtime OpenVINO provider for explicit Intel CPU and GPU execution on ROS 2 Jazzy."

USER ubuntu

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD ["python3", "-c", "import onnxruntime as ort; assert 'OpenVINOExecutionProvider' in ort.get_available_providers()"]

FROM inference-intel AS provider-conformance-intel

USER root
COPY docker/python/provider-conformance.lock /tmp/python/provider-conformance.lock

RUN uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/provider-conformance.lock \
    && install -d -o ubuntu -g ubuntu /reports \
    && install -d -o root -g root -m 0555 /opt/provider-conformance \
    && rm -rf /tmp/python

COPY --chmod=0444 test/provider-conformance/test_provider.py /opt/provider-conformance/test_provider.py

ENV ROBOTICS_EXPECTED_PROVIDER=OpenVINOExecutionProvider \
    ROBOTICS_PROVIDER_REPORT=/reports/provider-conformance.json

LABEL org.opencontainers.image.title="Robotics Intel provider conformance" \
      org.opencontainers.image.description="Hardware gate for explicit OpenVINO device identity, fallback, and tensor parity."

USER ubuntu
WORKDIR /opt/provider-conformance

ENTRYPOINT ["python3", "-m", "pytest"]
CMD ["-q", "-p", "no:cacheprovider", "--junitxml=/reports/provider-conformance.junit.xml", "test_provider.py"]

HEALTHCHECK NONE

FROM edge-runtime AS inference-amd

ARG MIGRAPHX_DEB_VERSION=2.15.0.70204-93~24.04
ARG ROCM_VERSION=7.2.4

USER root
COPY --from=uv /uv /uvx /usr/local/bin/
COPY --from=rocm-signing-key /rocm.asc /tmp/rocm.asc
COPY docker/python/inference-amd.lock /tmp/python/inference-amd.lock

RUN install -D -m 0644 /tmp/rocm.asc /etc/apt/keyrings/rocm.asc \
    && printf '%s\n' \
      "deb [arch=amd64 signed-by=/etc/apt/keyrings/rocm.asc] https://repo.radeon.com/rocm/apt/${ROCM_VERSION} noble main" \
      > /etc/apt/sources.list.d/rocm.list \
    && printf '%s\n' \
      'Package: *' \
      'Pin: release o=repo.radeon.com' \
      'Pin-Priority: 600' \
      > /etc/apt/preferences.d/rocm-pin-600 \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      "migraphx=${MIGRAPHX_DEB_VERSION}" \
    && uv venv --python /usr/bin/python3 --system-site-packages /opt/venv \
    && uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/inference-amd.lock \
    && uv pip freeze --python /opt/venv/bin/python \
      > /usr/share/robotics-runtime/python-packages.txt \
    && dpkg-query --show --showformat='${binary:Package}=${Version}\n' \
      > /tmp/debian-packages.txt \
    && sort --output=/usr/share/robotics-runtime/debian-packages.txt \
      /tmp/debian-packages.txt \
    && rm -rf \
      /etc/apt/keyrings/rocm.asc \
      /etc/apt/preferences.d/rocm-pin-600 \
      /etc/apt/sources.list.d/rocm.list \
      /tmp/debian-packages.txt \
      /tmp/python \
      /tmp/rocm.asc \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

ENV LD_LIBRARY_PATH=/opt/rocm/lib:/opt/rocm/lib64 \
    PATH="/opt/venv/bin:/opt/rocm/bin:${PATH}" \
    ROCM_PATH=/opt/rocm \
    ROCM_VERSION=7.2.4

LABEL org.opencontainers.image.title="Robotics AMD inference runtime" \
      org.opencontainers.image.description="ONNX Runtime MIGraphX provider with ROCm 7.2.4 on ROS 2 Jazzy."

USER ubuntu

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD ["python3", "-c", "import onnxruntime as ort; assert 'MIGraphXExecutionProvider' in ort.get_available_providers()"]

FROM inference-amd AS provider-conformance-amd

USER root
COPY docker/python/provider-conformance.lock /tmp/python/provider-conformance.lock

RUN uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/provider-conformance.lock \
    && install -d -o ubuntu -g ubuntu /reports \
    && install -d -o root -g root -m 0555 /opt/provider-conformance \
    && rm -rf /tmp/python

COPY --chmod=0444 test/provider-conformance/test_provider.py /opt/provider-conformance/test_provider.py

ENV ROBOTICS_EXPECTED_PROVIDER=MIGraphXExecutionProvider \
    ROBOTICS_PROVIDER_REPORT=/reports/provider-conformance.json

LABEL org.opencontainers.image.title="Robotics AMD provider conformance" \
      org.opencontainers.image.description="Hardware gate for MIGraphX provider identity, fallback, and tensor parity."

USER ubuntu
WORKDIR /opt/provider-conformance

ENTRYPOINT ["python3", "-m", "pytest"]
CMD ["-q", "-p", "no:cacheprovider", "--junitxml=/reports/provider-conformance.junit.xml", "test_provider.py"]

HEALTHCHECK NONE

FROM edge-runtime AS inference-nvidia

USER root
COPY --from=uv /uv /uvx /usr/local/bin/
COPY --from=nvidia-cuda-runtime /usr/local/cuda-13.3 /usr/local/cuda-13.3
COPY --from=nvidia-cuda-runtime /usr/lib/x86_64-linux-gnu/libcudnn*.so* /usr/lib/x86_64-linux-gnu/
COPY --from=nvidia-cuda-runtime \
    /NGC-DL-CONTAINER-LICENSE \
    /usr/share/licenses/nvidia/NGC-DL-CONTAINER-LICENSE
COPY docker/python/inference-nvidia.lock /tmp/python/inference-nvidia.lock

RUN ln -s /usr/local/cuda-13.3 /usr/local/cuda \
    && uv venv --python /usr/bin/python3 --system-site-packages /opt/venv \
    && uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/inference-nvidia.lock \
    && uv pip freeze --python /opt/venv/bin/python \
      > /usr/share/robotics-runtime/python-packages.txt \
    && rm -rf /tmp/python

ENV CUDA_HOME=/usr/local/cuda \
    CUDA_MODULE_LOADING=LAZY \
    CUDA_VERSION=13.3.0 \
    LD_LIBRARY_PATH=/usr/local/cuda/targets/x86_64-linux/lib:/usr/lib/x86_64-linux-gnu \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    NVIDIA_REQUIRE_CUDA="cuda>=13.3" \
    PATH="/opt/venv/bin:/usr/local/cuda/bin:${PATH}"

LABEL org.opencontainers.image.title="Robotics NVIDIA inference runtime" \
      org.opencontainers.image.description="ONNX Runtime CUDA provider with CUDA 13.3 and cuDNN 9 on ROS 2 Jazzy."

USER ubuntu

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD ["python3", "-c", "import onnxruntime as ort; assert 'CUDAExecutionProvider' in ort.get_available_providers()"]

FROM inference-nvidia AS inference-nvidia-verification

USER root

RUN test -s /usr/share/licenses/nvidia/NGC-DL-CONTAINER-LICENSE \
    && python3 -c \
      "import onnxruntime as ort; providers = ort.get_available_providers(); assert 'CUDAExecutionProvider' in providers, providers" \
    && ! command -v nvcc \
    && test ! -e /usr/local/cuda/include/cuda.h \
    && test -z "$(find /usr/include -name 'NvInfer*.h' -print -quit)"

USER ubuntu

HEALTHCHECK NONE

FROM inference-nvidia AS provider-conformance-nvidia

USER root
COPY docker/python/provider-conformance.lock /tmp/python/provider-conformance.lock

RUN uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/provider-conformance.lock \
    && install -d -o ubuntu -g ubuntu /reports \
    && install -d -o root -g root -m 0555 /opt/provider-conformance \
    && rm -rf /tmp/python

COPY --chmod=0444 test/provider-conformance/test_provider.py /opt/provider-conformance/test_provider.py

ENV ROBOTICS_EXPECTED_PROVIDER=CUDAExecutionProvider \
    ROBOTICS_PROVIDER_REPORT=/reports/provider-conformance.json

LABEL org.opencontainers.image.title="Robotics NVIDIA provider conformance" \
      org.opencontainers.image.description="Hardware release gate for CUDA provider identity, fallback, and tensor parity."

USER ubuntu
WORKDIR /opt/provider-conformance

ENTRYPOINT ["python3", "-m", "pytest"]
CMD ["-q", "-p", "no:cacheprovider", "--junitxml=/reports/provider-conformance.junit.xml", "test_provider.py"]

HEALTHCHECK NONE

FROM edge-runtime AS inference-nvidia-jetson-base

USER root
COPY --from=nvidia-cuda-runtime-minimal /usr/local/cuda-13.3 /usr/local/cuda-13.3
COPY --from=nvidia-cuda-runtime-minimal \
    /NGC-DL-CONTAINER-LICENSE \
    /usr/share/licenses/nvidia/NGC-DL-CONTAINER-LICENSE
COPY --from=onnxruntime-jetson-wheel-build /out /tmp/onnxruntime
COPY docker/python/inference-nvidia-jetson.lock /tmp/python/inference-nvidia-jetson.lock
WORKDIR /tmp/onnxruntime

RUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv,ro \
    ln -s /usr/local/cuda-13.3 /usr/local/cuda \
    && sha256sum --check --strict SHA256SUMS \
    && uv venv --python /usr/bin/python3 --system-site-packages /opt/venv \
    && uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/inference-nvidia-jetson.lock \
    && uv pip install \
      --python /opt/venv/bin/python \
      --no-cache \
      --no-deps \
      /tmp/onnxruntime/*.whl \
    && uv pip check --python /opt/venv/bin/python \
    && uv pip freeze --python /opt/venv/bin/python \
      > /usr/share/robotics-runtime/python-packages.txt \
    && cp /tmp/onnxruntime/source.txt \
      /usr/share/robotics-runtime/onnxruntime-source.txt \
    && install -D -m 0444 /tmp/onnxruntime/LICENSE \
      /usr/share/licenses/onnxruntime/LICENSE \
    && ! command -v nvcc \
    && test ! -d /usr/local/cuda/include \
    && test -z "$(find /usr/include -name 'NvInfer*.h' -print -quit)" \
    && test ! -e /src/onnxruntime \
    && rm -rf /tmp/onnxruntime /tmp/python

WORKDIR /workspace

ENV CUDA_HOME=/usr/local/cuda \
    CUDA_MODULE_LOADING=LAZY \
    CUDA_VERSION=13.3.0 \
    LD_LIBRARY_PATH=/opt/venv/lib/python3.12/site-packages/tensorrt_libs:/opt/venv/lib/python3.12/site-packages/nvidia/cudnn/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cublas/lib:/opt/venv/lib/python3.12/site-packages/nvidia/cuda_nvrtc/lib:/usr/local/cuda/targets/sbsa-linux/lib:/usr/local/nvidia/lib:/usr/local/nvidia/lib64 \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    NVIDIA_REQUIRE_CUDA="cuda>=13.2" \
    NVIDIA_VISIBLE_DEVICES=all \
    PATH="/opt/venv/bin:/usr/local/cuda/bin:${PATH}"

LABEL org.opencontainers.image.title="Robotics NVIDIA Jetson inference runtime" \
      org.opencontainers.image.description="ONNX Runtime TensorRT provider for JetPack 7.2 on ROS 2 Jazzy."

USER ubuntu

FROM inference-nvidia-jetson-base AS inference-nvidia-jetson-orin

ENV LD_LIBRARY_PATH="/usr/local/cuda-13.3/compat_orin:${LD_LIBRARY_PATH}" \
    ROBOTICS_NVIDIA_JETSON_FAMILY=orin

LABEL org.opencontainers.image.title="Robotics NVIDIA Jetson Orin inference runtime"

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD ["python3", "-c", "import onnxruntime as ort; assert 'TensorrtExecutionProvider' in ort.get_available_providers()"]

FROM inference-nvidia-jetson-base AS inference-nvidia-jetson-thor

ENV LD_LIBRARY_PATH="/usr/local/cuda-13.3/compat:${LD_LIBRARY_PATH}" \
    ROBOTICS_NVIDIA_JETSON_FAMILY=thor

LABEL org.opencontainers.image.title="Robotics NVIDIA Jetson Thor inference runtime"

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD ["python3", "-c", "import onnxruntime as ort; assert 'TensorrtExecutionProvider' in ort.get_available_providers()"]

FROM inference-nvidia-jetson-base AS provider-conformance-nvidia-jetson-base

USER root
COPY docker/python/provider-conformance.lock /tmp/python/provider-conformance.lock

RUN --mount=from=uv,source=/uv,target=/usr/local/bin/uv,ro \
    uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/provider-conformance.lock \
    && install -d -o ubuntu -g ubuntu /reports \
    && install -d -o root -g root -m 0555 /opt/provider-conformance \
    && rm -rf /tmp/python

COPY --chmod=0444 test/provider-conformance/test_provider.py /opt/provider-conformance/test_provider.py

ENV ROBOTICS_EXPECTED_PROVIDER=TensorrtExecutionProvider \
    ROBOTICS_PROVIDER_REPORT=/reports/provider-conformance.json

LABEL org.opencontainers.image.description="Jetson hardware gate for TensorRT provider identity, fallback, and tensor parity."

USER ubuntu
WORKDIR /opt/provider-conformance

ENTRYPOINT ["python3", "-m", "pytest"]
CMD ["-q", "-p", "no:cacheprovider", "--junitxml=/reports/provider-conformance.junit.xml", "test_provider.py"]

HEALTHCHECK NONE

FROM provider-conformance-nvidia-jetson-base AS provider-conformance-nvidia-jetson-orin

ENV LD_LIBRARY_PATH="/usr/local/cuda-13.3/compat_orin:${LD_LIBRARY_PATH}" \
    ROBOTICS_NVIDIA_JETSON_FAMILY=orin

LABEL org.opencontainers.image.title="Robotics NVIDIA Jetson Orin provider conformance"

FROM provider-conformance-nvidia-jetson-base AS provider-conformance-nvidia-jetson-thor

ENV LD_LIBRARY_PATH="/usr/local/cuda-13.3/compat:${LD_LIBRARY_PATH}" \
    ROBOTICS_NVIDIA_JETSON_FAMILY=thor

LABEL org.opencontainers.image.title="Robotics NVIDIA Jetson Thor provider conformance"

FROM edge-runtime AS acceptance-observer

USER root
COPY --from=uv /uv /uvx /usr/local/bin/
COPY docker/python/acceptance-observer.lock /tmp/python/acceptance-observer.lock

RUN uv venv --python /usr/bin/python3 --system-site-packages /opt/venv \
    && uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-cache \
      --no-deps \
      --requirement /tmp/python/acceptance-observer.lock \
    && uv pip freeze --python /opt/venv/bin/python \
      > /usr/share/robotics-runtime/python-packages.txt \
    && rm -rf /tmp/python

ENV PATH="/opt/venv/bin:${PATH}"

LABEL org.opencontainers.image.title="Robotics acceptance observer" \
      org.opencontainers.image.description="Attach-only ROS 2 acceptance observation and machine-readable results."

USER ubuntu

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["robotics-acceptance", "--version"]

FROM edge-runtime AS benchmark-runtime

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY docker/rosdeps/benchmark/package.xml /tmp/rosdep/benchmark/package.xml

RUN export HOME=/root \
    && apt-get update \
    && rosdep update --rosdistro "${ROS_DISTRO}" \
    && rosdep install \
      --from-paths /tmp/rosdep \
      --ignore-src \
      --rosdistro "${ROS_DISTRO}" \
      -y \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
      | sort > /usr/share/robotics-runtime/deb-packages.tsv \
    && rm -rf \
      /tmp/rosdep \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

LABEL org.opencontainers.image.title="ROS 2 data-plane benchmark" \
      org.opencontainers.image.description="Apex.AI performance_test 2.3.0 on ROS 2 Jazzy."

USER ubuntu

HEALTHCHECK --interval=30s --timeout=5s --retries=3 \
  CMD ["ros2", "pkg", "prefix", "performance_test"]

FROM ${SIMULATION_BASE_IMAGE} AS simulation

ARG IMAGE_CREATED=1970-01-01T00:00:00Z
ARG IMAGE_SOURCE=https://github.com/mmkolpakov/robotics-runtime-infra
ARG IMAGE_VERSION=0.5.0
ARG VCS_REF=local
ARG UBUNTU_SNAPSHOT
ARG ROS_SNAPSHOT
ARG ROSDISTRO_INDEX_REVISION

LABEL org.opencontainers.image.title="Robotics simulation runtime" \
      org.opencontainers.image.description="ROS 2 Jazzy and Gazebo Harmonic runtime with domain-neutral acceptance tests." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ENV DEBIAN_FRONTEND=noninteractive \
    LIBGL_ALWAYS_SOFTWARE=1 \
    QT_QPA_PLATFORM=offscreen \
    RCUTILS_COLORIZED_OUTPUT=1 \
    RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    ROBOTICS_ROS_SNAPSHOT="${ROS_SNAPSHOT}" \
    ROBOTICS_UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
    ROSDISTRO_INDEX_URL="https://raw.githubusercontent.com/ros/rosdistro/${ROSDISTRO_INDEX_REVISION}/index-v4.yaml"

WORKDIR /opt/robotics_ws

COPY ros_ws/src/robotics_runtime_infra/package.xml /tmp/rosdep/robotics_runtime_infra/package.xml
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
COPY --chmod=0444 docker/apt/ros-snapshot-key.gpg /usr/share/keyrings/ros-snapshot-key.gpg
COPY --from=geographiclib-datasets /datasets /tmp/geographiclib

RUN UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
    ROS_DISTRO="${ROS_DISTRO}" \
    ROS_SNAPSHOT="${ROS_SNAPSHOT}" \
    ROSDISTRO_INDEX_REVISION="${ROSDISTRO_INDEX_REVISION}" \
      /usr/local/sbin/use-package-snapshots \
    && export HOME=/root \
    && apt-get update \
    && rosdep update --rosdistro "${ROS_DISTRO}" \
    && rosdep install \
      --from-paths /tmp/rosdep \
      --ignore-src \
      --rosdistro "${ROS_DISTRO}" \
      -y \
    && tar -xjf /tmp/geographiclib/egm96-5.tar.bz2 -C /usr/share/GeographicLib \
    && tar -xjf /tmp/geographiclib/egm96.tar.bz2 -C /usr/share/GeographicLib \
    && tar -xjf /tmp/geographiclib/emm2015.tar.bz2 -C /usr/share/GeographicLib \
    && test -s /usr/share/GeographicLib/geoids/egm96-5.pgm \
    && test -s /usr/share/GeographicLib/gravity/egm96.egm.cof \
    && test -s /usr/share/GeographicLib/magnetic/emm2015.wmm.cof \
    && mkdir -p /usr/share/robotics-runtime \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
      | sort > /usr/share/robotics-runtime/deb-packages.tsv \
    && rm -rf \
      /tmp/rosdep \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

COPY ros_ws/src ./src

RUN source "/opt/ros/${ROS_DISTRO}/setup.bash" \
    && colcon build \
      --merge-install \
      --event-handlers console_direct+ \
      --cmake-args -DBUILD_TESTING=ON \
    && chown -R ubuntu:ubuntu build install log

COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/robotics-entrypoint
COPY --chmod=0555 docker/runtime/emit-runtime-manifest /usr/local/bin/emit-runtime-manifest

ENV HOME=/home/ubuntu \
    ROBOTICS_CONTRACTS_REVISION=576826d9fcdfe795dfc695ad44326610c023e94c \
    ROBOTICS_HARNESS_REVISION=e0fe6393a18211e28ebd5cf2774445962c72aee5 \
    ROBOTICS_INFRA_REVISION="${VCS_REF}"
USER ubuntu

ENTRYPOINT ["/usr/local/bin/robotics-entrypoint"]
CMD ["ros2", "launch", "robotics_runtime_infra", "headless.launch.py"]

HEALTHCHECK --interval=10s --timeout=8s --start-period=30s --retries=6 \
  CMD ["/usr/local/bin/robotics-entrypoint", "timeout", "5", "ros2", "topic", "echo", "/clock", "--once"]
