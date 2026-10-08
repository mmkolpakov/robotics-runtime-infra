# syntax=docker/dockerfile:1.14
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90 AS runtime
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
ARG DEBIAN_FRONTEND=noninteractive
ARG VCS_REF=local
LABEL org.opencontainers.image.title="Robotics Webots native worker" \
      org.opencontainers.image.source="https://github.com/mmkolpakov/robotics-runtime-infra" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.robotics.webots.release="R2025a" \
      org.robotics.webots.artifact-sha256="6253d58c9b625a83ed7b62cd85a640fd0542d441c48d633a60932208b40b0657"
# Bootstrap HTTPS using the exact certificate payload from the same frozen archive.
ADD https://snapshot.ubuntu.com/ubuntu/20260901T000000Z/pool/main/c/ca-certificates/ca-certificates_20240203_all.deb /tmp/ca.deb
RUN printf '%s  %s\n' 641de77d8f142cfd62a1a6f964ba67b20754d3337c480efb529d086075a06c9a /tmp/ca.deb | sha256sum --check \
    && dpkg-deb -x /tmp/ca.deb /tmp/ca \
    && mkdir -p /etc/ssl/certs \
    && cat /tmp/ca/usr/share/ca-certificates/mozilla/*.crt > /etc/ssl/certs/ca-certificates.crt \
    && rm -rf /tmp/ca /tmp/ca.deb
RUN rm -f /etc/apt/sources.list.d/ubuntu.sources \
    && printf '%s\n' \
       'deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20260901T000000Z noble main universe' \
       'deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20260901T000000Z noble-updates main universe' \
       'deb [check-valid-until=no] https://snapshot.ubuntu.com/ubuntu/20260901T000000Z noble-security main universe' \
       > /etc/apt/sources.list \
    && apt-get update \
    && apt-get install --yes --no-install-recommends \
       ca-certificates=20260601~24.04.1 \
       python3=3.12.3-0ubuntu2.1 \
       lsb-release=12.0-2 \
       ffmpeg=7:6.1.1-3ubuntu5 \
       xvfb=2:21.1.12-1ubuntu1.6 \
       xauth=1:1.1.2-1build1 \
       mesa-utils=9.0.0-2 \
       libgl1-mesa-dri=25.2.8-0ubuntu0.24.04.2 \
       libglx-mesa0=25.2.8-0ubuntu0.24.04.2 \
       libatk1.0-0t64=2.52.0-1build1 \
       libdbus-1-3=1.14.10-4ubuntu4.1 \
       libfreeimage3=3.18.0+ds2-10build4 \
       libglib2.0-0t64=2.80.0-6ubuntu3.8 \
       libegl1=1.7.0-1build1 \
       libglu1-mesa=9.0.2-1.1build1 \
       libgtk-3-0t64=3.24.41-4ubuntu1.3 \
       libnss3=2:3.98-1ubuntu0.2 \
       libstdc++6=14.2.0-4ubuntu2~24.04.1 \
       libxaw7=2:1.0.14-1build2 \
       libxrandr2=2:1.5.2-2build1 \
       libxrender1=1:0.9.10-1.1build1 \
       libssh-4=0.10.6-2ubuntu0.5 \
       libzip4t64=1.7.3-1.1ubuntu2 \
       libxslt1.1=1.1.39-0exp1ubuntu0.24.04.3 \
       libfreetype6=2.13.2+dfsg-1ubuntu0.1 \
       libfontconfig1=2.15.0-1.1ubuntu2 \
       libxkbcommon-x11-0=1.6.0-1build1 \
       libxcb-keysyms1=0.4.0-1build4 \
       libxcb-image0=0.4.0-2build1 \
       libxcb-icccm4=0.4.1-1.1build3 \
       libxcb-randr0=1.15-1ubuntu2 \
       libxcb-render-util0=0.3.9-1build4 \
       libxcb-xinerama0=1.15-1ubuntu2 \
       libxcb-cursor0=0.1.4-1build1 \
       libxcomposite1=1:0.4.5-1build3 \
       libxtst6=2:1.2.3-1.1build1 \
       libopengl0=1.7.0-1build1 \
       libxcursor1=1:1.2.1-1build1 \
       libx11-xcb1=2:1.8.7-1build1 \
    && mkdir -p /usr/local/share/robotics-webots \
    && dpkg-query --show --showformat='${binary:Package}\t${Version}\t${Architecture}\n' | sort > /usr/local/share/robotics-webots/packages.tsv \
    && rm -rf /var/lib/apt/lists/*
ADD https://github.com/cyberbotics/webots/releases/download/R2025a/webots_2025a_amd64.deb /tmp/webots.deb
RUN printf '%s  %s\n' 6253d58c9b625a83ed7b62cd85a640fd0542d441c48d633a60932208b40b0657 /tmp/webots.deb | sha256sum --check \
    && test "$(dpkg-deb -f /tmp/webots.deb Version)" = 2025a \
    && test "$(dpkg-deb -f /tmp/webots.deb Architecture)" = amd64 \
    && dpkg-deb -x /tmp/webots.deb / \
    && rm /tmp/webots.deb \
    && test "$(cat /usr/local/webots/resources/version.txt)" = R2025a \
    && sha256sum /usr/local/webots/bin/webots-bin /usr/local/webots/webots-controller /usr/local/webots/lib/controller/libController.so > /usr/local/share/robotics-webots/binaries.sha256
ENV WEBOTS_HOME=/usr/local/webots \
    HOME=/tmp/robotics-webots \
    XDG_CACHE_HOME=/tmp/robotics-webots/cache \
    XDG_RUNTIME_DIR=/tmp/robotics-webots/runtime \
    LIBGL_ALWAYS_SOFTWARE=1 \
    PYTHONUNBUFFERED=1
FROM runtime
COPY workers/webots /opt/robotics/webots
RUN chmod -R a-w /opt/robotics/webots
USER 10001:10001
WORKDIR /opt/robotics/webots
ENTRYPOINT ["python3", "/opt/robotics/webots/launcher.py"]
