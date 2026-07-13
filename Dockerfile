# syntax=docker/dockerfile:1.19

ARG ROS_BASE_IMAGE=ros:jazzy-ros-base@sha256:31daab66eef9139933379fb67159449944f4e2dcf2e22c2d12cc715f29873e0f
ARG SIMULATION_BASE_IMAGE=osrf/ros:jazzy-simulation@sha256:acb7c427deb2aaa5acd0fdfa5f6cca9ad2055a64102b4667986b70d550dc469d
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa
ARG UBUNTU_BASE_IMAGE=ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90
ARG RCLONE_IMAGE=rclone/rclone:1.74.4@sha256:c61954aaa32328a5486715dd063a81c7879f5195ad3505cd362deddd509dc4a1
ARG AWS_CLI_IMAGE=public.ecr.aws/aws-cli/aws-cli:2.35.21@sha256:238583846e731f31c9848dae26c5a560769ff35c4c5368a4cb6be5816683e485
ARG GO_BUILDER_IMAGE=golang:1.26.5@sha256:079e59808d2d252516e27e3f3a9c003740dee7f75e55aa71528766d52bcfc16a
ARG NVIDIA_CUDA_BASE_IMAGE=nvidia/cuda:13.0.2-cudnn-runtime-ubuntu24.04@sha256:14d94b039cb94bbd5da559f303b46bc4b0d5d6c24ab1a9d7b186e566ed3400dc
ARG UBUNTU_SNAPSHOT=20260701T000000Z
ARG ROS_SNAPSHOT=2026-06-18
ARG ROSDISTRO_INDEX_REVISION=9f76014b84955f757306270d6860fa3bc1c30b57

FROM ${UV_IMAGE} AS uv
FROM ${RCLONE_IMAGE} AS rclone
FROM ${AWS_CLI_IMAGE} AS aws-cli
FROM ${NVIDIA_CUDA_BASE_IMAGE} AS nvidia-cuda-runtime

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
      .

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

FROM ubuntu-ca AS geographiclib-datasets

ARG UBUNTU_SNAPSHOT

SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
RUN UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
      /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && apt-get install -y --no-install-recommends curl \
    && mkdir -p /datasets \
    && download() { \
      curl \
        --fail \
        --location \
        --show-error \
        --silent \
        --connect-timeout 30 \
        --max-time 300 \
        --retry 8 \
        --retry-all-errors \
        --retry-delay 2 \
        --output "$2" \
        "$1"; \
    } \
    && download \
      https://downloads.sourceforge.net/project/geographiclib/geoids-distrib/egm96-5.tar.bz2 \
      /datasets/egm96-5.tar.bz2 \
    && download \
      https://downloads.sourceforge.net/project/geographiclib/gravity-distrib/egm96.tar.bz2 \
      /datasets/egm96.tar.bz2 \
    && download \
      https://downloads.sourceforge.net/project/geographiclib/magnetic-distrib/emm2015.tar.bz2 \
      /datasets/emm2015.tar.bz2 \
    && printf '%s  %s\n' \
      c46224f8f723dc915d97179f4e1580a98d6c742fe2b82cd8fef0ecaaad13e614 \
      /datasets/egm96-5.tar.bz2 \
      6fea4c6bd56ff8ac53dbdad8d5dd505c855471d0354c4abc5c5fe048bf8350c1 \
      /datasets/egm96.tar.bz2 \
      8e71a9704c5f2714bb65581df68e30f0d84d0ad17286d00efb782e7232334c3f \
      /datasets/emm2015.tar.bz2 \
      | sha256sum --check --strict \
    && rm -rf \
      /var/cache/ldconfig/aux-cache \
      /var/lib/apt/lists/* \
      /var/log/apt/* \
      /var/log/alternatives.log \
      /var/log/dpkg.log

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
COPY --from=nvidia-cuda-runtime /usr/local/cuda-13.0 /usr/local/cuda-13.0
COPY --from=nvidia-cuda-runtime /usr/lib/x86_64-linux-gnu/libcudnn*.so* /usr/lib/x86_64-linux-gnu/
COPY docker/python/inference-nvidia.lock /tmp/python/inference-nvidia.lock

RUN ln -s /usr/local/cuda-13.0 /usr/local/cuda \
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
    CUDA_VERSION=13.0.2 \
    LD_LIBRARY_PATH=/usr/local/cuda/lib64:/usr/lib/x86_64-linux-gnu \
    NVIDIA_DRIVER_CAPABILITIES=compute,utility \
    NVIDIA_REQUIRE_CUDA="cuda>=13.0" \
    PATH="/opt/venv/bin:/usr/local/cuda/bin:${PATH}"

LABEL org.opencontainers.image.title="Robotics NVIDIA inference runtime" \
      org.opencontainers.image.description="ONNX Runtime CUDA provider with CUDA 13 and cuDNN 9 on ROS 2 Jazzy."

USER ubuntu

HEALTHCHECK --interval=30s --timeout=10s --retries=3 \
  CMD ["python3", "-c", "import onnxruntime as ort; assert 'CUDAExecutionProvider' in ort.get_available_providers()"]

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
