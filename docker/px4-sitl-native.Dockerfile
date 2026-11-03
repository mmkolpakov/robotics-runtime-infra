# syntax=docker/dockerfile:1.14
ARG PX4_DEPS_IMAGE
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa
FROM ${UV_IMAGE} AS uv
FROM ${PX4_DEPS_IMAGE} AS native-sdk
COPY --from=uv /uv /usr/local/bin/uv
COPY native-sdk.lock /usr/share/robotics-px4/native-sdk.lock
COPY metadata/native-sdk.sha256 /usr/share/robotics-px4/native-sdk.sha256
WORKDIR /usr/share/robotics-px4
RUN sha256sum --check native-sdk.sha256 \
    && uv venv --python /usr/bin/python3 /opt/px4-native-venv \
    && uv pip sync --python /opt/px4-native-venv/bin/python \
         --require-hashes --only-binary=:all: native-sdk.lock

FROM ${PX4_DEPS_IMAGE}
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG VCS_REF=local
LABEL org.opencontainers.image.title="Robotics PX4 native Python source candidate" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.robotics.px4.commit="d6f12ad1c4f70ad3230afd7d86e971421e02fef4" \
      org.robotics.px4.models-commit="b6127f4ec20de867e215fb5f78ae88b80f371909" \
      org.robotics.px4.controller="native-python"
COPY --from=native-sdk /opt/px4-native-venv/ /opt/px4-native-venv/
COPY native-sdk.lock /usr/share/robotics-px4/native-sdk.lock
COPY payload/ /opt/px4/
COPY metadata/ /usr/share/robotics-px4/source/
COPY workers/ /opt/robotics/px4/
WORKDIR /opt/robotics/px4
RUN sha256sum --check /usr/share/robotics-px4/source/workers.sha256
WORKDIR /opt/px4
RUN test -x /usr/bin/timeout \
    && sha256sum --check /usr/share/robotics-px4/source/payload.sha256 \
    && (cd /usr/share/robotics-px4 && sha256sum --check source/native-sdk.sha256) \
    && test ! -e /opt/robotics/mavsdk_server && test ! -L /opt/robotics/mavsdk_server \
    && chmod -R a-w /opt/px4 /opt/robotics/px4 /opt/px4-native-venv
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
