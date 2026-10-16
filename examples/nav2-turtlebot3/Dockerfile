FROM docker.io/library/ros:jazzy-ros-base-noble@sha256:a5426de405f6f0a82b0f3def3bbd3bce2a71a91421fe980c17613b4e51ef38d9
ENV DEBIAN_FRONTEND=noninteractive
COPY inputs.lock.json Dockerfile /opt/sdk-policy/
RUN apt-get update && apt-get install -y --reinstall --download-only --no-install-recommends \
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
    && python3 -c 'import hashlib,json,pathlib; p=json.loads(pathlib.Path("/opt/sdk-policy/inputs.lock.json").read_bytes()); [(lambda b,e: (len(b)==int(e["Size"]) and hashlib.sha256(b).hexdigest()==e["SHA256"]) or (_ for _ in ()).throw(ValueError("native package checksum differs")))(pathlib.Path("/var/cache/apt/archives",pathlib.Path(e["Filename"]).name).read_bytes(),e) for e in p["packages"].values()]' \
    && apt-get install -y --no-install-recommends --no-download \
       $(python3 -c 'import json,pathlib; p=json.loads(pathlib.Path("/opt/sdk-policy/inputs.lock.json").read_bytes()); print(" ".join(k+"="+v["Version"] for k,v in p["packages"].items()))') python3-venv \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
ARG SDK_COHORT=__exact_sdk_cohort_required__
COPY ${SDK_COHORT}/wheels/ /opt/sdk-cohort/wheels/
COPY inputs.lock.json requirements.lock check-sdk-wheels.py /opt/sdk-policy/
RUN python3 /opt/sdk-policy/check-sdk-wheels.py /opt/sdk-cohort/wheels \
    && python3 -m venv --system-site-packages /opt/consumer \
    && /opt/consumer/bin/pip install --disable-pip-version-check --only-binary=:all: \
       --require-hashes --no-cache-dir --no-index --find-links=/opt/sdk-cohort/wheels \
       -r /opt/sdk-policy/requirements.lock
RUN /opt/consumer/bin/python - <<'PY'
import hashlib
import json
from pathlib import Path
import subprocess
import yaml

root = Path("/opt/sdk-policy")
policy = json.loads((root / "inputs.lock.json").read_bytes())
checked = subprocess.run(["dpkg", "--verify", *policy["packages"]], check=True, capture_output=True)
if checked.stdout or checked.stderr:
    raise ValueError("installed native package verification failed")
paths = {
    "model": "/opt/ros/jazzy/share/nav2_minimal_tb3_sim/urdf/gz_waffle.sdf.xacro",
    "world": "/opt/ros/jazzy/share/nav2_minimal_tb3_sim/worlds/tb3_sandbox.sdf.xacro",
    "map": "/opt/ros/jazzy/share/nav2_bringup/maps/tb3_sandbox.yaml",
    "launch": "/opt/ros/jazzy/share/nav2_bringup/launch/tb3_simulation_launch.py",
}
paths["map_image"] = str((Path(paths["map"]).parent / yaml.safe_load(Path(paths["map"]).read_text())["image"]).resolve(strict=True))
paths["robot_state"] = "/opt/ros/jazzy/share/nav2_minimal_tb3_sim/urdf/turtlebot3_waffle.urdf"
paths["params"] = "/opt/ros/jazzy/share/nav2_bringup/params/nav2_params.yaml"
paths["spawn_launch"] = "/opt/ros/jazzy/share/nav2_minimal_tb3_sim/launch/spawn_tb3.launch.py"
files = {}
for name, value in paths.items():
    path = Path(value)
    raw = path.read_bytes()
    files[name] = {"path": value, "sha256": hashlib.sha256(raw).hexdigest(), "size_bytes": len(raw)}
receipt = {
    "policy_sha256": hashlib.sha256((root / "inputs.lock.json").read_bytes()).hexdigest(),
    "dockerfile_sha256": hashlib.sha256((root / "Dockerfile").read_bytes()).hexdigest(),
    "packages": {name: {"version": item["Version"], "sha256": item["SHA256"]} for name, item in policy["packages"].items()},
    "files": files,
    "installed_packages_sha256": hashlib.sha256(subprocess.check_output(["dpkg-query", "-W", "-f=${Package}\t${Version}\t${Architecture}\n"])).hexdigest(),
}
(root / "image-build.json").write_text(json.dumps(receipt, sort_keys=True) + "\n")
PY
ENV PYTHONDONTWRITEBYTECODE=1
ENV RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    LIBGL_ALWAYS_SOFTWARE=1
STOPSIGNAL SIGINT
# Upstream launch/model/world/map are selected from the unmodified ROS packages.
CMD ["/opt/consumer/bin/python", "-c", "raise SystemExit('native launch requires an admitted v2 SDK/image composition')"]
