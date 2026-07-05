ARG RUNTIME_BASE_IMAGE=robotics/ros-jazzy-simulation:2026-07-05
FROM ${RUNTIME_BASE_IMAGE}

ARG IMAGE_CREATED=unknown
ARG IMAGE_SOURCE=unknown
ARG IMAGE_VERSION=2026-07-05
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="robotics diagnostics runtime" \
      org.opencontainers.image.description="Optional ROS 2 diagnostics tools for local simulation analysis." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install --no-install-recommends -y \
    "ros-${ROS_DISTRO}-plotjuggler" \
    "ros-${ROS_DISTRO}-plotjuggler-ros" \
  && rm -rf /var/lib/apt/lists/*

CMD ["bash", "-lc", "source /etc/profile.d/robotics_ros_setup.sh && ros2 pkg list | grep -E '^plotjuggler$|^plotjuggler_ros$'"]
