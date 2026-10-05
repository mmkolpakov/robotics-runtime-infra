# Source qualification cohort; install stock signed Debian artifacts, with no ros_gz overlay.
ARG ROS_COHORT_BASE_IMAGE=sha256:1c227795630eb5d3a5069774031321f7aa48a47179af8345432bf1a0be6c7c60
FROM ${ROS_COHORT_BASE_IMAGE} AS availability
USER 0:0
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
COPY --chmod=0444 docker/apt/ros-snapshot-key.gpg /usr/share/keyrings/ros-snapshot-key.gpg
COPY docker/apt/ros-cohort-source.packages /tmp/ros-cohort-source.packages
COPY config/ros-cohort-source.lock.json /usr/share/robotics-runtime/ros-cohort-source.lock.json
RUN sed -i -E 's#ros/rosdistro/[0-9a-f]{40}/#ros/rosdistro/8e9a99d200fd312f106418b2b497b0cc5146e6a7/#g' /etc/ros/rosdep/sources.list.d/20-default.list \
    && UBUNTU_SNAPSHOT=20260930T000000Z ROS_DISTRO=jazzy ROS_SNAPSHOT=2026-09-11 \
      ROSDISTRO_INDEX_REVISION=8e9a99d200fd312f106418b2b497b0cc5146e6a7 /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && mkdir -p /usr/share/robotics-runtime/ros-cohort \
    && mapfile -t packages < /tmp/ros-cohort-source.packages \
    && apt-cache policy "${packages[@]%%=*}" > /usr/share/robotics-runtime/ros-cohort/apt-policy.txt \
    && apt-get --simulate --no-install-recommends install "${packages[@]}" > /usr/share/robotics-runtime/ros-cohort/resolver-plan.txt \
    && cat /usr/share/robotics-runtime/ros-cohort/resolver-plan.txt

FROM availability AS runtime
COPY docker/apt/ros-cohort-source-closure.packages /tmp/ros-cohort-source-closure.packages
RUN mapfile -t packages < /tmp/ros-cohort-source-closure.packages \
    && apt-get install -y --no-install-recommends "${packages[@]}" \
    && for spec in "${packages[@]}"; do \
         package="${spec%%=*}";expected="${spec#*=}"; \
         actual="$(dpkg-query --show --showformat='${Version}' "${package}")"; \
         test "${actual}" = "${expected}" || exit 65; \
       done \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
      | sort > /usr/share/robotics-runtime/ros-cohort/deb-packages.tsv \
    && dpkg-query -S /opt/ros/jazzy/lib/ros_gz_sim/create \
      > /usr/share/robotics-runtime/ros-cohort/stock-create-owner.txt \
    && source /opt/ros/jazzy/setup.bash \
    && source /opt/robotics_ws/install/setup.bash \
    && test "$(ros2 pkg prefix ros_gz_sim)" = /opt/ros/jazzy \
    && /opt/contracts/bin/python -c 'import importlib.metadata as m; import xml.etree.ElementTree as E; from simulation_interfaces.msg import Result; from simulation_interfaces.srv import GetEntities,GetSimulatorFeatures,GetSimulationState,SetSimulationState,StepSimulation; assert m.version("robotics-runtime-contracts")=="0.18.2"; assert m.version("robotics-acceptance-harness")=="0.19.1"; assert E.parse("/opt/ros/jazzy/share/ros_gz_sim/package.xml").getroot().findtext("version")=="1.0.24"; assert E.parse("/opt/ros/jazzy/share/simulation_interfaces/package.xml").getroot().findtext("version")=="1.5.1"; print("stock ROS packages and native SDK interfaces imported",Result.RESULT_OK)' \
    && gz sim --versions > /usr/share/robotics-runtime/ros-cohort/gazebo-versions.txt \
    && rm -rf /var/lib/apt/lists/* /var/cache/ldconfig/aux-cache /var/log/apt/* /var/log/dpkg.log
ENV ROBOTICS_ROS_SNAPSHOT=2026-09-11 \
    ROSDISTRO_INDEX_URL=https://raw.githubusercontent.com/ros/rosdistro/8e9a99d200fd312f106418b2b497b0cc5146e6a7/index-v4.yaml
ARG ROS_COHORT_SOURCE_REVISION
LABEL org.robotics.runtime.ros-cohort.source-revision="${ROS_COHORT_SOURCE_REVISION}" \
      org.robotics.runtime.ros-cohort.qualification-scope="source-only"
USER 1000:1000
