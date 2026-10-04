# syntax=docker/dockerfile:1.14
FROM ros:jazzy-ros-base@sha256:31daab66eef9139933379fb67159449944f4e2dcf2e22c2d12cc715f29873e0f AS ca-source
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90
ARG UBUNTU_SNAPSHOT=20260930T000000Z
COPY --from=ca-source /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
RUN UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && apt-get install -y --no-install-recommends ca-certificates catatonit \
    && install -d /out \
    && dpkg-query -W catatonit > /out/catatonit-package.txt \
    && cp /usr/bin/catatonit /out/catatonit \
    && sha256sum /out/catatonit > /out/catatonit.sha256 \
    && rm -rf /var/lib/apt/lists/*
