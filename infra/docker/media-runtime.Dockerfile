ARG RUNTIME_BASE_IMAGE=robotics/ros-jazzy-simulation:2026-07-05
FROM ${RUNTIME_BASE_IMAGE}

ARG IMAGE_CREATED=unknown
ARG IMAGE_SOURCE=unknown
ARG IMAGE_VERSION=2026-07-05
ARG VCS_REF=unknown

LABEL org.opencontainers.image.title="robotics media sensor runtime" \
      org.opencontainers.image.description="Optional GStreamer runtime for camera and media pipeline checks." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT"

ENV DEBIAN_FRONTEND=noninteractive
SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN apt-get update && apt-get install --no-install-recommends -y \
    gstreamer1.0-libav \
    gstreamer1.0-plugins-bad \
    gstreamer1.0-plugins-good \
    gstreamer1.0-plugins-ugly \
    gstreamer1.0-tools \
  && rm -rf /var/lib/apt/lists/*

CMD ["bash", "-lc", "gst-launch-1.0 --version && gst-inspect-1.0 videotestsrc >/tmp/gst-videotestsrc.txt && test -s /tmp/gst-videotestsrc.txt"]
