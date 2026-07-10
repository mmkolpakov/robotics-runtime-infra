# syntax=docker/dockerfile:1.19
ARG ROS_BASE_IMAGE=osrf/ros:jazzy-simulation@sha256:acb7c427deb2aaa5acd0fdfa5f6cca9ad2055a64102b4667986b70d550dc469d
FROM ${ROS_BASE_IMAGE}

ARG IMAGE_CREATED=1970-01-01T00:00:00Z
ARG IMAGE_SOURCE=https://github.com/mmkolpakov/droning-simulation-infra
ARG IMAGE_VERSION=0.4.1
ARG VCS_REF=local

LABEL org.opencontainers.image.title="Robotics simulation infrastructure" \
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
    RCUTILS_COLORIZED_OUTPUT=1

WORKDIR /opt/robotics_ws

COPY ros_ws/src/robotics_simulation_infra/package.xml /tmp/rosdep/robotics_simulation_infra/package.xml

RUN apt-get update \
    && rosdep update --rosdistro "${ROS_DISTRO}" \
    && rosdep install \
      --from-paths /tmp/rosdep \
      --ignore-src \
      --rosdistro "${ROS_DISTRO}" \
      -y \
    && "/opt/ros/${ROS_DISTRO}/lib/mavros/install_geographiclib_datasets.sh" \
    && rm -rf /var/lib/apt/lists/* /tmp/rosdep

COPY ros_ws/src ./src

RUN source "/opt/ros/${ROS_DISTRO}/setup.bash" \
    && colcon build \
      --merge-install \
      --event-handlers console_direct+ \
      --cmake-args -DBUILD_TESTING=ON \
    && chown -R ubuntu:ubuntu build log

COPY --chmod=755 docker/entrypoint.sh /usr/local/bin/robotics-entrypoint

ENV HOME=/home/ubuntu
USER ubuntu

ENTRYPOINT ["/usr/local/bin/robotics-entrypoint"]
CMD ["ros2", "launch", "robotics_simulation_infra", "headless.launch.py"]

HEALTHCHECK --interval=10s --timeout=8s --start-period=30s --retries=6 \
  CMD ["/usr/local/bin/robotics-entrypoint", "timeout", "5", "ros2", "topic", "echo", "/clock", "--once"]
