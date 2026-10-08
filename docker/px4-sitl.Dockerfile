# syntax=docker/dockerfile:1.14
ARG PX4_DEPS_IMAGE
FROM ${PX4_DEPS_IMAGE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG VCS_REF=local
LABEL org.opencontainers.image.title="Robotics stock PX4/Gazebo source worker" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.robotics.px4.commit="d6f12ad1c4f70ad3230afd7d86e971421e02fef4" \
      org.robotics.px4.models-commit="b6127f4ec20de867e215fb5f78ae88b80f371909"
COPY payload/ /opt/px4/
COPY mavsdk_server /opt/robotics/mavsdk_server
COPY metadata/ /usr/share/robotics-px4/source/
COPY workers/ /opt/robotics/px4/
WORKDIR /opt/robotics/px4
RUN sha256sum --check /usr/share/robotics-px4/source/workers.sha256
WORKDIR /opt/px4
RUN sha256sum --check /usr/share/robotics-px4/source/payload.sha256 \
    && printf '%s  %s\n' 7cd0a2995460983e82fe2cf0ef187aba852bb849168ce972a139680f3611c0d8 /opt/robotics/mavsdk_server | sha256sum --check \
    && chmod -R a-w /opt/px4 /opt/robotics/px4 \
    && chmod 0555 /opt/robotics/mavsdk_server
ENV HEADLESS=1 GZ_IP=127.0.0.1 GZ_DISTRO=jetty HOME=/tmp/px4 \
    PX4_SIM_MODEL=gz_x500 PX4_SYS_AUTOSTART=4001 PX4_GZ_WORLD=default \
    PX4_GZ_MODELS=/opt/px4/Tools/simulation/gz/models \
    PX4_GZ_WORLDS=/opt/px4/Tools/simulation/gz/worlds \
    GZ_SIM_RESOURCE_PATH=/opt/px4/Tools/simulation/gz/models:/opt/px4/Tools/simulation/gz/worlds \
    GZ_SIM_SYSTEM_PLUGIN_PATH=/opt/px4/build/px4_sitl_default/src/modules/simulation/gz_plugins \
    GZ_SIM_SERVER_CONFIG_PATH=/opt/px4/src/modules/simulation/gz_bridge/server.config
USER 1000:1000
WORKDIR /tmp
ENTRYPOINT ["/opt/px4/build/px4_sitl_default/bin/px4"]
CMD ["-d", "/opt/px4/build/px4_sitl_default/etc", "-w", "/tmp"]
