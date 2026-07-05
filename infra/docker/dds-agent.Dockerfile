ARG UBUNTU_BASE_IMAGE=ubuntu:24.04
FROM ${UBUNTU_BASE_IMAGE}

ARG IMAGE_CREATED=unknown
ARG IMAGE_SOURCE=unknown
ARG IMAGE_VERSION=2026-07-05
ARG VCS_REF=unknown
ARG MICRO_XRCE_DDS_AGENT_REF=v3.0.1
ARG MICRO_XRCE_DDS_AGENT_SHA=155cfaaf8b7abac2e85d4a62d3649b09ace0be55

LABEL org.opencontainers.image.title="robotics DDS bridge runtime" \
      org.opencontainers.image.description="Optional Micro XRCE-DDS Agent runtime for ROS 2/autopilot integration checks." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="Apache-2.0"

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install --no-install-recommends -y \
    build-essential \
    ca-certificates \
    cmake \
    git \
  && git clone --depth 1 --branch "${MICRO_XRCE_DDS_AGENT_REF}" \
    https://github.com/eProsima/Micro-XRCE-DDS-Agent.git /tmp/Micro-XRCE-DDS-Agent \
  && test "$(git -C /tmp/Micro-XRCE-DDS-Agent rev-parse HEAD)" = "${MICRO_XRCE_DDS_AGENT_SHA}" \
  && cmake -S /tmp/Micro-XRCE-DDS-Agent -B /tmp/Micro-XRCE-DDS-Agent/build \
    -DCMAKE_BUILD_TYPE=Release \
  && cmake --build /tmp/Micro-XRCE-DDS-Agent/build --parallel "$(nproc)" \
  && cmake --install /tmp/Micro-XRCE-DDS-Agent/build \
  && ldconfig \
  && rm -rf /tmp/Micro-XRCE-DDS-Agent /var/lib/apt/lists/*

CMD ["bash", "-lc", "MicroXRCEAgent --help || test $? -eq 1"]
