# syntax=docker/dockerfile:1.14
FROM ros:jazzy-ros-base@sha256:31daab66eef9139933379fb67159449944f4e2dcf2e22c2d12cc715f29873e0f AS ca-source
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG UBUNTU_SNAPSHOT=20260930T000000Z
ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC GZ_DISTRO=jetty PYTHONDONTWRITEBYTECODE=1
COPY --from=ca-source /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
RUN UBUNTU_SNAPSHOT="$UBUNTU_SNAPSHOT" /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates=20260601~24.04.1 wget=1.21.4-1ubuntu4.5 gnupg=2.4.4-2ubuntu17.6 \
    && wget -q https://packages.osrfoundation.org/gazebo.gpg -O /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg \
    && printf '%s\n' 'deb [arch=amd64 signed-by=/usr/share/keyrings/pkgs-osrf-archive-keyring.gpg] https://packages.osrfoundation.org/gazebo/ubuntu-stable noble main' > /etc/apt/sources.list.d/gazebo-stable.list \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       gz-jetty=1.0.0-2~noble libgz-sim10-dev=10.5.0-2~noble \
       libgz-transport15-dev=15.1.0-3~noble libgz-msgs12-dev=12.0.2-2~noble libsdformat16-dev=16.1.0-2~noble \
       build-essential=12.10ubuntu1 ccache=4.9.1-1 cmake=3.28.3-1build7 ninja-build=1.11.1-2 pkg-config=1.8.1-2build1 git=1:2.43.0-1ubuntu7.3 file=1:5.45-3build1 rsync=3.2.7-1ubuntu1.5 bc=1.07.1-3ubuntu4 \
       libssl-dev=3.0.13-0ubuntu3.16 libxml2-dev=2.9.14+dfsg-1.3ubuntu3.9 libxml2-utils=2.9.14+dfsg-1.3ubuntu3.9 libunwind-dev=1.6.2-3build1.1 cppzmq-dev=4.10.0-1build1 \
       libeigen3-dev=3.4.0-4build0.1 libopencv-dev=4.6.0+dfsg-13.1ubuntu1 libgstreamer1.0-dev=1.24.2-1ubuntu0.1 libgstreamer-plugins-base1.0-dev=1.24.2-1ubuntu0.5 \
       gstreamer1.0-plugins-bad=1.24.2-1ubuntu4 python3=3.12.3-0ubuntu2.1 python3-dev=3.12.3-0ubuntu2.1 python3-venv=3.12.3-0ubuntu2.1 python3-pip=24.0+dfsg-1ubuntu1.3 \
    && install -d /usr/share/robotics-px4 \
    && dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort > /usr/share/robotics-px4/apt-closure.txt \
    && sha256sum /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg > /usr/share/robotics-px4/osrf-key.sha256 \
    && cp /var/lib/apt/lists/*osrf*Packages* /usr/share/robotics-px4/ \
    && gz sim --versions && gz topic --help \
    && rm -rf /var/lib/apt/lists/*
COPY docker/apt/px4-jetty-closure.lock /usr/share/robotics-px4/expected-apt-closure.txt
RUN diff -u /usr/share/robotics-px4/expected-apt-closure.txt /usr/share/robotics-px4/apt-closure.txt \
    && printf '%s  %s\n' 15d0300460e0c9c0efb21fa9770c0bf228988a07d71c4fac985c2161954a25a4 /usr/share/keyrings/pkgs-osrf-archive-keyring.gpg | sha256sum --check \
    && ! dpkg-query -W 'ros-*' 2>/dev/null | grep -q .
COPY docker/python/px4-sitl.lock /usr/share/robotics-px4/px4-sitl.lock
RUN python3 -m venv /opt/px4-venv \
    && /opt/px4-venv/bin/python -m pip install --no-cache-dir --require-hashes -r /usr/share/robotics-px4/px4-sitl.lock \
    && /opt/px4-venv/bin/python -m pip check
ENV PATH=/opt/px4-venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
WORKDIR /opt/px4
