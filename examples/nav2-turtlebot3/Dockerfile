FROM docker.io/library/ros:jazzy-ros-base-noble@sha256:a5426de405f6f0a82b0f3def3bbd3bce2a71a91421fe980c17613b4e51ef38d9
ENV DEBIAN_FRONTEND=noninteractive
RUN apt-get update && apt-get install -y --no-install-recommends \
        ros-jazzy-nav2-bringup=1.3.13-1noble.20261006.042503 \
        ros-jazzy-nav2-simple-commander=1.3.13-1noble.20260921.030016 \
        ros-jazzy-nav2-minimal-tb3-sim=1.0.1-1noble.20261006.041307 \
        ros-jazzy-nav2-msgs=1.3.13-1noble.20260921.023049 \
        ros-jazzy-ros-gz-sim=1.0.24-1noble.20261006.035056 \
        ros-jazzy-ros-gz-bridge=1.0.24-1noble.20260920.234644 \
        ros-jazzy-rosbag2-storage-mcap=0.26.11-1noble.20260911.143733 \
        ros-jazzy-rosbag2-transport=0.26.11-1noble.20260911.150336 \
        ros-jazzy-rclpy=7.1.12-1noble.20260912.162354 \
        ros-jazzy-rmw-fastrtps-cpp=8.4.4-1noble.20260911.100940 \
        ros-jazzy-gz-sim-vendor=0.0.13-1noble.20260905.073557 \
        python3-venv \
    && rm -rf /var/lib/apt/lists/*
COPY producer-requirements.lock /opt/consumer-requirements.lock
RUN python3 -m venv --system-site-packages /opt/consumer \
    && /opt/consumer/bin/pip install --disable-pip-version-check --only-binary=:all: \
       --require-hashes --no-cache-dir -r /opt/consumer-requirements.lock
ENV PYTHONDONTWRITEBYTECODE=1
ENV RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    LIBGL_ALWAYS_SOFTWARE=1
STOPSIGNAL SIGINT
# Upstream launch/model/world/map are selected from the unmodified ROS packages.
CMD ["ros2", "launch", "nav2_bringup", "tb3_simulation_launch.py", "headless:=True", "use_rviz:=False", "slam:=False", "use_composition:=False", "use_respawn:=False"]
