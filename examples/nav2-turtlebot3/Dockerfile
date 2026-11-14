FROM docker.io/library/ros:jazzy-ros-base-noble@sha256:a5426de405f6f0a82b0f3def3bbd3bce2a71a91421fe980c17613b4e51ef38d9
ENV DEBIAN_FRONTEND=noninteractive
COPY inputs.lock.json Dockerfile /opt/sdk-policy/
COPY --from=apt-snapshot /use-package-snapshots /opt/sdk-policy/use-package-snapshots
COPY --from=apt-snapshot /ros-snapshot-key.gpg /usr/share/keyrings/ros-snapshot-key.gpg
RUN python3 -c '\
import hashlib,json,os,subprocess; \
from pathlib import Path; \
p=json.loads(Path("/opt/sdk-policy/inputs.lock.json").read_bytes()); s=p["apt_snapshots"]; \
helper=Path("/opt/sdk-policy/use-package-snapshots"); key=Path("/usr/share/keyrings/ros-snapshot-key.gpg"); \
assert hashlib.sha256(helper.read_bytes()).hexdigest()==s["helper_sha256"], "snapshot helper differs"; \
assert hashlib.sha256(key.read_bytes()).hexdigest()==s["ros_key_sha256"], "snapshot key differs"; \
subprocess.run(["bash",str(helper)],check=True,env=dict(os.environ,UBUNTU_SNAPSHOT=s["ubuntu"],ROS_SNAPSHOT=s["ros"],ROS_DISTRO=p["ros_distribution"],ROSDISTRO_INDEX_REVISION=s["rosdistro_index_revision"]))' \
    && rm -f /etc/apt/apt.conf.d/docker-clean \
    && apt-get update \
    && apt-get install -y --reinstall --download-only --no-install-recommends \
       $(python3 -c 'import json,pathlib; p=json.loads(pathlib.Path("/opt/sdk-policy/inputs.lock.json").read_bytes()); print(" ".join(k+"="+v["Version"] for k,v in p["packages"].items()))') python3-venv \
    && apt-get upgrade -y --download-only --with-new-pkgs \
    && python3 -c 'import hashlib,json,pathlib; p=json.loads(pathlib.Path("/opt/sdk-policy/inputs.lock.json").read_bytes()); [(lambda b,e: (len(b)==int(e["Size"]) and hashlib.sha256(b).hexdigest()==e["SHA256"]) or (_ for _ in ()).throw(ValueError("native package checksum differs")))(pathlib.Path("/var/cache/apt/archives",pathlib.Path(e["Filename"]).name).read_bytes(),e) for e in p["packages"].values()]' \
    && apt-get upgrade -y --no-download --with-new-pkgs \
    && apt-get install -y --reinstall --no-install-recommends --no-download \
       $(python3 -c 'import json,pathlib; p=json.loads(pathlib.Path("/opt/sdk-policy/inputs.lock.json").read_bytes()); print(" ".join(k+"="+v["Version"] for k,v in p["packages"].items()))') python3-venv \
    && apt-get install -y --reinstall --download-only --no-install-recommends \
       $(dpkg-query -W '-f=${Package}\n' 'ros-jazzy-*') \
    && apt-get install -y --reinstall --no-download --no-install-recommends \
       $(dpkg-query -W '-f=${Package}\n' 'ros-jazzy-*') \
    && rm -rf /var/lib/apt/lists/* /var/cache/apt/archives/*.deb
COPY --from=sdk-wheels / /opt/sdk-cohort/wheels/
COPY inputs.lock.json requirements.lock check-sdk-wheels.py native_simulation.launch.py /opt/sdk-policy/
RUN python3 /opt/sdk-policy/check-sdk-wheels.py /opt/sdk-cohort/wheels \
    && python3 -m venv --system-site-packages /opt/consumer \
    && /opt/consumer/bin/pip install --disable-pip-version-check --only-binary=:all: \
       --require-hashes --no-cache-dir --no-index --find-links=/opt/sdk-cohort/wheels \
       -r /opt/sdk-policy/requirements.lock
RUN /opt/consumer/bin/python -c '\
import hashlib,json,subprocess,yaml; \
from pathlib import Path; \
root=Path("/opt/sdk-policy"); \
policy=json.loads((root/"inputs.lock.json").read_bytes()); \
installed=subprocess.check_output(["dpkg-query","-W","-f=${Package}\\t${Version}\\t${Architecture}\\n"]); \
ros_packages=[row.split("\t")[0] for row in installed.decode().splitlines() if row.startswith("ros-jazzy-")]; \
assert ros_packages, "ROS package inventory is empty"; \
checked=subprocess.run(["dpkg","--verify",*ros_packages],check=True,capture_output=True); \
assert not checked.stdout and not checked.stderr, "installed native package verification failed"; \
base="/opt/ros/jazzy/share/"; \
paths={"model":base+"nav2_minimal_tb3_sim/urdf/gz_waffle.sdf.xacro","world":base+"nav2_minimal_tb3_sim/worlds/tb3_sandbox.sdf.xacro","map":base+"nav2_bringup/maps/tb3_sandbox.yaml","launch":base+"nav2_bringup/launch/tb3_simulation_launch.py","robot_state":base+"nav2_minimal_tb3_sim/urdf/turtlebot3_waffle.urdf","params":base+"nav2_bringup/params/nav2_params.yaml","spawn_launch":base+"nav2_minimal_tb3_sim/launch/spawn_tb3.launch.py"}; \
paths["consumer_launch"]="/opt/sdk-policy/native_simulation.launch.py"; \
paths["map_image"]=str((Path(paths["map"]).parent/yaml.safe_load(Path(paths["map"]).read_text())["image"]).resolve(strict=True)); \
files={name:{"path":path,"sha256":hashlib.sha256(raw:=Path(path).read_bytes()).hexdigest(),"size_bytes":len(raw)} for name,path in paths.items()}; \
receipt={"policy_sha256":hashlib.sha256((root/"inputs.lock.json").read_bytes()).hexdigest(),"dockerfile_sha256":hashlib.sha256((root/"Dockerfile").read_bytes()).hexdigest(),"packages":{name:{"version":item["Version"],"sha256":item["SHA256"]} for name,item in policy["packages"].items()},"files":files,"ros_packages":ros_packages,"snapshot_files":{path:hashlib.sha256(Path(path).read_bytes()).hexdigest() for path in ("/etc/apt/sources.list.d/ubuntu.sources","/etc/apt/sources.list.d/ros2-snapshot.sources","/etc/apt/apt.conf.d/50robotics-snapshot","/etc/ros/rosdep/sources.list.d/20-default.list")},"installed_packages_sha256":hashlib.sha256(installed).hexdigest()}; \
(root/"image-build.json").write_text(json.dumps(receipt,sort_keys=True))'
ENV PYTHONDONTWRITEBYTECODE=1
ENV RMW_IMPLEMENTATION=rmw_fastrtps_cpp \
    LIBGL_ALWAYS_SOFTWARE=1
STOPSIGNAL SIGINT
# Upstream launch/model/world/map are selected from the unmodified ROS packages.
CMD ["/opt/consumer/bin/python", "-c", "raise SystemExit('native launch requires an admitted v2 SDK/image composition')"]
