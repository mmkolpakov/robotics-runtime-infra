# syntax=docker/dockerfile:1
ARG ROS_BASE_IMAGE=osrf/ros:jazzy-simulation
FROM ${ROS_BASE_IMAGE}

ARG IMAGE_CREATED=unknown
ARG IMAGE_SOURCE=unknown
ARG IMAGE_VERSION=2026-07-05
ARG VCS_REF=unknown
ARG AWS_CLI_VERSION=2.35.17

LABEL org.opencontainers.image.title="robotics ROS 2 Jazzy simulation stack" \
      org.opencontainers.image.description="ROS 2 Jazzy, MAVROS, ROS-Gazebo, MoveIt2, ros2_control, OpenCV, and rosbag2 MCAP tooling for local simulation checks." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install --no-install-recommends -y \
    bash-completion \
    ca-certificates \
    curl \
    geographiclib-tools \
    git \
    groff \
    less \
    python3-opencv \
    python3-pip \
    python3-venv \
    unzip \
    "ros-${ROS_DISTRO}-cv-bridge" \
    "ros-${ROS_DISTRO}-image-transport" \
    "ros-${ROS_DISTRO}-launch-testing" \
    "ros-${ROS_DISTRO}-launch-testing-ros" \
    "ros-${ROS_DISTRO}-mavlink" \
    "ros-${ROS_DISTRO}-mavros" \
    "ros-${ROS_DISTRO}-mavros-extras" \
    "ros-${ROS_DISTRO}-mavros-msgs" \
    "ros-${ROS_DISTRO}-moveit" \
    "ros-${ROS_DISTRO}-ros2-control" \
    "ros-${ROS_DISTRO}-ros2-controllers" \
    "ros-${ROS_DISTRO}-rosbag2" \
    "ros-${ROS_DISTRO}-rosbag2-storage-mcap" \
    "ros-${ROS_DISTRO}-ros-gz" \
    "ros-${ROS_DISTRO}-sensor-msgs" \
    "ros-${ROS_DISTRO}-tf2-msgs" \
    "ros-${ROS_DISTRO}-vision-opencv" \
  && rm -rf /var/lib/apt/lists/*

# `launch_testing`/`launch_testing_ros` ship as ROS packages above (real
# Jazzy binaries, matching the rest of the stack's rosdep-managed
# versioning); pytest itself is pinned explicitly to match
# `requirements-dev.txt` so container-side test runs use the same pytest
# release as host-side CI. `--ignore-installed` avoids pip trying (and
# failing) to uninstall the apt/debian-managed `pluggy`/`pytest` that
# `ros-launch-testing` pulls in transitively, which has no RECORD file for
# pip to work with.
RUN python3 -m pip install --no-cache-dir --break-system-packages --ignore-installed "pytest==9.0.2"

RUN curl --fail --location --show-error \
      "https://awscli.amazonaws.com/awscli-exe-linux-x86_64-${AWS_CLI_VERSION}.zip" \
      -o /tmp/awscliv2.zip \
  && unzip -q /tmp/awscliv2.zip -d /tmp \
  && /tmp/aws/install --bin-dir /usr/local/bin --install-dir /usr/local/aws-cli \
  && rm -rf /tmp/aws /tmp/awscliv2.zip \
  && aws --version | grep -E "^aws-cli/${AWS_CLI_VERSION} "

RUN if [[ -x "/opt/ros/${ROS_DISTRO}/lib/mavros/install_geographiclib_datasets.sh" ]]; then \
      "/opt/ros/${ROS_DISTRO}/lib/mavros/install_geographiclib_datasets.sh"; \
    elif command -v geographiclib-get-geoids >/dev/null 2>&1; then \
      geographiclib-get-geoids egm96-5; \
    else \
      echo "No GeographicLib dataset installer is available" >&2; \
      exit 1; \
    fi

RUN printf '%s\n' \
    "source /opt/ros/${ROS_DISTRO}/setup.bash" \
  > /etc/profile.d/robotics_ros_setup.sh

COPY --chmod=755 infra/docker/scripts/healthcheck.sh /usr/local/bin/healthcheck.sh

CMD ["/usr/local/bin/healthcheck.sh"]
