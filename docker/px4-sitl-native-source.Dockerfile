# syntax=docker/dockerfile:1.14
ARG PX4_DEPS_IMAGE
FROM ros:jazzy-ros-base@sha256:31daab66eef9139933379fb67159449944f4e2dcf2e22c2d12cc715f29873e0f AS ca-source
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90 AS native-source-inputs
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG UBUNTU_SNAPSHOT
ENV DEBIAN_FRONTEND=noninteractive PYTHONDONTWRITEBYTECODE=1
COPY --from=ca-source /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chmod=0555 use-package-snapshots /usr/local/sbin/use-package-snapshots
RUN set -eu; \
    UBUNTU_SNAPSHOT="$UBUNTU_SNAPSHOT" /usr/local/sbin/use-package-snapshots \
    && mkdir -p /opt/sdk-apt-lists/partial \
    && mapfile -t apt_packages < <(dpkg-query -W -f='${binary:Package}\t${source:Package}\t${db:Status-Status}\n' | awk '$2 == "apt" && $3 == "installed" {print $1}') \
    && test "${#apt_packages[@]}" -gt 0 \
    && apt-get -o Acquire::Retries=0 -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=- -o Dir::State::lists=/opt/sdk-apt-lists update \
    && install -d /usr/share/robotics-px4/sdk-source/build-apt-indexes \
    && cp /opt/sdk-apt-lists/*InRelease /opt/sdk-apt-lists/*Packages* /usr/share/robotics-px4/sdk-source/build-apt-indexes/ \
    && apt-get -o Acquire::Retries=0 -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=- -o Dir::State::lists=/opt/sdk-apt-lists install -y --download-only --only-upgrade --no-remove --no-install-recommends "${apt_packages[@]}" \
    && apt-get -o Acquire::Retries=0 -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=- -o Dir::State::lists=/opt/sdk-apt-lists install -y --download-only --no-install-recommends build-essential cmake ninja-build pkg-config git ca-certificates python3 python3-venv python3-pip binutils pax-utils libcurl4-openssl-dev libssl-dev liblzma-dev libasio-dev libfmt-dev libtinyxml2-dev nlohmann-json3-dev \
    && : > /usr/share/robotics-px4/sdk-source/build-debs.tsv \
    && for file in /var/cache/apt/archives/*.deb; do \
         test -e "$file" || continue; \
         printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
           "$(dpkg-deb -f "$file" Package)" "$(dpkg-deb -f "$file" Version)" \
           "$(dpkg-deb -f "$file" Architecture)" "$(stat -c %s "$file")" \
           "$(sha256sum "$file" | cut -d " " -f 1)" "${file##*/}" \
           >> /usr/share/robotics-px4/sdk-source/build-debs.tsv; \
       done \
    && LC_ALL=C sort -o /usr/share/robotics-px4/sdk-source/build-debs.tsv /usr/share/robotics-px4/sdk-source/build-debs.tsv \
    && apt-get -o Acquire::Retries=0 -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=- -o Dir::State::lists=/opt/sdk-apt-lists install -y --no-download --no-remove --no-install-recommends "${apt_packages[@]}" build-essential cmake ninja-build pkg-config git ca-certificates python3 python3-venv python3-pip binutils pax-utils libcurl4-openssl-dev libssl-dev liblzma-dev libasio-dev libfmt-dev libtinyxml2-dev nlohmann-json3-dev \
    && for package in "${apt_packages[@]}"; do \
         dpkg --compare-versions "$(dpkg-query -W -f='${source:Version}' "$package")" ge 2.8.4ubuntu0.1 || exit 1; \
       done \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' | LC_ALL=C sort \
       > /usr/share/robotics-px4/sdk-source/build-apt-closure.tsv \
    && rm -rf /opt/sdk-apt-lists
COPY build.lock /opt/sdk-inputs/build.lock
RUN python3 -m venv /opt/sdk-build \
    && /opt/sdk-build/bin/python -I -m pip download --require-hashes --only-binary=:all: \
       --no-deps --dest /opt/sdk-wheelhouse -r /opt/sdk-inputs/build.lock \
    && /opt/sdk-build/bin/python -I -m pip install --no-index --find-links=/opt/sdk-wheelhouse \
       --require-hashes --only-binary=:all: --no-deps -r /opt/sdk-inputs/build.lock \
    && /opt/sdk-build/bin/python -I -m pip check
COPY sdk/MAVSDK/ /src/MAVSDK/
COPY archives/ /opt/sdk-inputs/archives/
COPY metadata/sdk-inputs.sha256 /opt/sdk-inputs/archives.sha256
COPY source-sdk-lock.json /opt/sdk-inputs/source-sdk-lock.json
WORKDIR /opt/sdk-inputs
RUN sha256sum --check archives.sha256 \
    && mkdir -p /src/deps \
    && for name in MAVLink libevents PicoSHA2 libmavlike; do \
         mkdir -p "/src/deps/$name"; \
         tar -xzf "archives/$name.tar.gz" --strip-components=1 -C "/src/deps/$name"; \
       done \
    && mkdir -p /src/deps/MAVLink/pymavlink \
    && tar -xzf archives/pymavlink.tar.gz --strip-components=1 -C /src/deps/MAVLink/pymavlink
ENV PATH=/opt/sdk-build/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
    PIP_NO_INDEX=1 PIP_FIND_LINKS=/opt/sdk-wheelhouse CMAKE_BUILD_PARALLEL_LEVEL=4

FROM ${PX4_DEPS_IMAGE} AS native-source-runtime-inputs
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG UBUNTU_SNAPSHOT
COPY --chmod=0555 use-package-snapshots /usr/local/sbin/use-package-snapshots
RUN set -eu; \
    UBUNTU_SNAPSHOT="$UBUNTU_SNAPSHOT" /usr/local/sbin/use-package-snapshots \
    && mkdir -p /opt/sdk-apt-lists/partial \
    && mapfile -t apt_packages < <(dpkg-query -W -f='${binary:Package}\t${source:Package}\t${db:Status-Status}\n' | awk '$2 == "apt" && $3 == "installed" {print $1}') \
    && test "${#apt_packages[@]}" -gt 0 \
    && apt-get -o Acquire::Retries=0 -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=- -o Dir::State::lists=/opt/sdk-apt-lists update \
    && install -d /usr/share/robotics-px4/sdk-source/runtime-apt-indexes \
    && cp /opt/sdk-apt-lists/*InRelease /opt/sdk-apt-lists/*Packages* /usr/share/robotics-px4/sdk-source/runtime-apt-indexes/ \
    && apt-get -o Acquire::Retries=0 -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=- -o Dir::State::lists=/opt/sdk-apt-lists install -y --download-only --only-upgrade --no-remove --no-install-recommends "${apt_packages[@]}" \
    && apt-get -o Acquire::Retries=0 -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=- -o Dir::State::lists=/opt/sdk-apt-lists install -y --download-only --no-install-recommends libcurl4t64 libssl3t64 liblzma5 libfmt9 libtinyxml2-10 libstdc++6 libgcc-s1 pax-utils \
    && : > /usr/share/robotics-px4/sdk-source/runtime-debs.tsv \
    && for file in /var/cache/apt/archives/*.deb; do \
         test -e "$file" || continue; \
         printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
           "$(dpkg-deb -f "$file" Package)" "$(dpkg-deb -f "$file" Version)" \
           "$(dpkg-deb -f "$file" Architecture)" "$(stat -c %s "$file")" \
           "$(sha256sum "$file" | cut -d " " -f 1)" "${file##*/}" \
           >> /usr/share/robotics-px4/sdk-source/runtime-debs.tsv; \
       done \
    && LC_ALL=C sort -o /usr/share/robotics-px4/sdk-source/runtime-debs.tsv /usr/share/robotics-px4/sdk-source/runtime-debs.tsv \
    && apt-get -o Acquire::Retries=0 -o Dir::Etc::sourcelist=/etc/apt/sources.list.d/ubuntu.sources -o Dir::Etc::sourceparts=- -o Dir::State::lists=/opt/sdk-apt-lists install -y --no-download --no-remove --no-install-recommends "${apt_packages[@]}" libcurl4t64 libssl3t64 liblzma5 libfmt9 libtinyxml2-10 libstdc++6 libgcc-s1 pax-utils \
    && for package in "${apt_packages[@]}"; do \
         dpkg --compare-versions "$(dpkg-query -W -f='${source:Version}' "$package")" ge 2.8.4ubuntu0.1 || exit 1; \
       done \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' | LC_ALL=C sort \
       > /usr/share/robotics-px4/sdk-source/runtime-apt-closure.tsv \
    && rm -rf /opt/sdk-apt-lists

FROM native-source-inputs AS native-sdk-source
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG VCS_REF=local
ARG APT_BUILD_CLOSURE_SHA256
ARG APT_BUILD_DEBS_SHA256
LABEL org.opencontainers.image.title="Robotics MAVSDK system-dependency source candidate" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.robotics.mavsdk.origin="project-source-build" \
      org.robotics.mavsdk.commit="2da0f3f85f0cd1ed12f981dcac17b647030186f0"
RUN --network=none test -n "$APT_BUILD_CLOSURE_SHA256" && test -n "$APT_BUILD_DEBS_SHA256"     && printf '%s  %s\n' "$APT_BUILD_CLOSURE_SHA256" /usr/share/robotics-px4/sdk-source/build-apt-closure.tsv        "$APT_BUILD_DEBS_SHA256" /usr/share/robotics-px4/sdk-source/build-debs.tsv | sha256sum --check
RUN --network=none cmake -S /src/deps/MAVLink -B /build/mavlink \
       -DCMAKE_INSTALL_PREFIX=/opt/mavsdk -DCMAKE_INSTALL_LIBDIR=lib \
       -DPython_EXECUTABLE=/opt/sdk-build/bin/python -DMAVLINK_ENABLE_CXX=OFF \
       -DMAVLINK_DIALECT=ardupilotmega \
    && cmake --build /build/mavlink --target install \
    && mkdir -p /opt/mavsdk/include/mavlink/message_definitions/v1.0 \
    && cp /src/deps/MAVLink/message_definitions/v1.0/{minimal,standard,common,ardupilotmega}.xml \
       /opt/mavsdk/include/mavlink/message_definitions/v1.0/
RUN --network=none cmake -S /src/deps/libevents/libs/cpp -B /build/libevents \
       -DCMAKE_INSTALL_PREFIX=/opt/mavsdk -DCMAKE_INSTALL_LIBDIR=lib \
       -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DENABLE_TESTING=OFF \
    && cmake --build /build/libevents --target install \
    && cmake -S /src/deps/PicoSHA2 -B /build/picosha2 \
       -DCMAKE_INSTALL_PREFIX=/opt/mavsdk -DCMAKE_INSTALL_LIBDIR=lib \
    && cmake --build /build/picosha2 --target install \
    && cmake -S /src/deps/libmavlike -B /build/libmavlike \
       -DCMAKE_PREFIX_PATH=/opt/mavsdk -DCMAKE_INSTALL_PREFIX=/opt/mavsdk \
       -DCMAKE_INSTALL_LIBDIR=lib -DCMAKE_POSITION_INDEPENDENT_CODE=ON -DBUILD_TESTING=OFF \
    && cmake --build /build/libmavlike --target install
RUN --network=none test "$(git -C /src/MAVSDK describe --exact-match --tags)" = v4.2.0 \
    && cmake -S /src/MAVSDK/cpp -B /build/mavsdk \
       -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/mavsdk \
       -DCMAKE_INSTALL_PREFIX=/opt/mavsdk -DCMAKE_INSTALL_LIBDIR=lib \
       -DSUPERBUILD=OFF -DBUILD_SHARED_LIBS=ON -DBUILD_WITHOUT_CURL=OFF \
       -DBUILD_MAVSDK_SERVER=OFF -DBUILD_TESTING=OFF \
    && cmake --build /build/mavsdk --target install \
    && cmake -S /src/MAVSDK/c -B /build/cmavsdk \
       -DCMAKE_BUILD_TYPE=Release -DCMAKE_PREFIX_PATH=/opt/mavsdk \
       -DCMAKE_INSTALL_PREFIX=/opt/mavsdk -DCMAKE_INSTALL_LIBDIR=lib \
       -DBUILD_SHARED_LIBS=ON -DBUILD_EXAMPLES=OFF -DBUNDLE_STATIC_RUNTIME=OFF \
    && cmake --build /build/cmavsdk --target install
RUN --network=none printf '%s\n' /opt/mavsdk/lib > /etc/ld.so.conf.d/mavsdk-source.conf \
    && ldconfig \
    && install -D /opt/mavsdk/lib/libcmavsdk.so.3.10.2 \
       /src/MAVSDK/py/mavsdk/mavsdk/lib/libcmavsdk.so \
    && python -m build --wheel --no-isolation --outdir /opt/sdk-dist /src/MAVSDK/py/mavsdk \
    && python3 -m venv /opt/px4-native-venv \
    && /opt/px4-native-venv/bin/python -I -m pip install --no-index --no-deps --no-compile /opt/sdk-dist/*.whl \
    && /opt/px4-native-venv/bin/python -I -m pip check \
    && readelf -d /opt/mavsdk/lib/libmavsdk.so.4 > /usr/share/robotics-px4/sdk-source/build-libmavsdk.dynamic.txt \
    && readelf -d /opt/mavsdk/lib/libcmavsdk.so.3 > /usr/share/robotics-px4/sdk-source/build-libcmavsdk.dynamic.txt \
    && /usr/bin/python3 /usr/bin/lddtree /opt/mavsdk/lib/libcmavsdk.so.3 > /usr/share/robotics-px4/sdk-source/build-dependency-tree.txt \
    && cp /opt/sdk-inputs/source-sdk-lock.json /usr/share/robotics-px4/sdk-source/
COPY metadata/sdk-source.json /usr/share/robotics-px4/sdk-source/inputs.json

FROM native-source-runtime-inputs
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG UBUNTU_SNAPSHOT
ARG VCS_REF=local
LABEL org.opencontainers.image.title="Robotics PX4 system-dependency SDK source candidate" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.robotics.px4.controller="native-python-source" \
      org.robotics.mavsdk.origin="project-source-build"
ARG APT_RUNTIME_CLOSURE_SHA256
ARG APT_RUNTIME_DEBS_SHA256
RUN test -n "$APT_RUNTIME_CLOSURE_SHA256" && test -n "$APT_RUNTIME_DEBS_SHA256"     && printf '%s  %s\n' "$APT_RUNTIME_CLOSURE_SHA256" /usr/share/robotics-px4/sdk-source/runtime-apt-closure.tsv        "$APT_RUNTIME_DEBS_SHA256" /usr/share/robotics-px4/sdk-source/runtime-debs.tsv | sha256sum --check
COPY --from=native-sdk-source /opt/mavsdk/ /opt/mavsdk/
COPY --from=native-sdk-source /opt/px4-native-venv/ /opt/px4-native-venv/
COPY --from=native-sdk-source /usr/share/robotics-px4/sdk-source/ /usr/share/robotics-px4/sdk-source/
COPY payload/ /opt/px4/
COPY metadata/ /usr/share/robotics-px4/source/
COPY workers/ /opt/robotics/px4/
WORKDIR /opt/px4
RUN printf '%s\n' /opt/mavsdk/lib > /etc/ld.so.conf.d/mavsdk-source.conf && ldconfig \
    && env --chdir=/opt/robotics/px4 sha256sum --check /usr/share/robotics-px4/source/workers.sha256 \
    && sha256sum --check /usr/share/robotics-px4/source/payload.sha256 \
    && dpkg-query -W -f='${binary:Package}\t${Version}\t${Architecture}\n' \
       | LC_ALL=C sort > /usr/share/robotics-px4/sdk-source/runtime-apt-closure.tsv \
    && /opt/px4-native-venv/bin/python -I -m pip check > /usr/share/robotics-px4/sdk-source/runtime-pip-check.txt \
    && /opt/px4-native-venv/bin/python -I -c 'import sys; from importlib.metadata import version; print(sys.version); print(version("mavsdk"))' > /usr/share/robotics-px4/sdk-source/runtime-python-metadata.txt \
    && readelf -d /opt/mavsdk/lib/libmavsdk.so.4 > /usr/share/robotics-px4/sdk-source/runtime-libmavsdk.dynamic.txt \
    && readelf -d /opt/mavsdk/lib/libcmavsdk.so.3 > /usr/share/robotics-px4/sdk-source/runtime-libcmavsdk.dynamic.txt \
    && /usr/bin/python3 /usr/bin/lddtree /opt/mavsdk/lib/libcmavsdk.so.3 > /usr/share/robotics-px4/sdk-source/runtime-dependency-tree.txt \
    && sha256sum /etc/ld.so.cache /etc/ld.so.conf.d/mavsdk-source.conf > /usr/share/robotics-px4/sdk-source/runtime-linker-config.sha256 \
    && printf 'PATH=%s\nLD_LIBRARY_PATH=%s\nLD_PRELOAD=%s\n' "$PATH" "${LD_LIBRARY_PATH-}" "${LD_PRELOAD-}" > /usr/share/robotics-px4/sdk-source/runtime-linker-env.txt \
    && test ! -e /opt/robotics/mavsdk_server \
    && chmod -R a-w /opt/px4 /opt/robotics/px4 /opt/px4-native-venv /opt/mavsdk
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
