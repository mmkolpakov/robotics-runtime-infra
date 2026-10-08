# syntax=docker/dockerfile:1.14
FROM ros:jazzy-ros-base@sha256:31daab66eef9139933379fb67159449944f4e2dcf2e22c2d12cc715f29873e0f AS ca-source
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90
ARG UBUNTU_SNAPSHOT=20260930T000000Z
ENV DEBIAN_FRONTEND=noninteractive TZ=Etc/UTC PYTHONDONTWRITEBYTECODE=1
COPY --from=ca-source /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
COPY docker/apt/media-closure.lock /tmp/media-closure.lock
RUN UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
       ca-certificates python3 python3-gi gir1.2-gstreamer-1.0 \
       gstreamer1.0-tools gstreamer1.0-plugins-base gstreamer1.0-plugins-good \
       gstreamer1.0-plugins-bad gstreamer1.0-libav \
    && install -d -m 0755 /usr/share/robotics-runtime /run/robotics/output \
    && dpkg-query -W -f='${binary:Package}\t${Version}\n' | LC_ALL=C sort \
       > /usr/share/robotics-runtime/media-apt-closure.txt \
    && diff -u /tmp/media-closure.lock /usr/share/robotics-runtime/media-apt-closure.txt \
    && printf '%s\n' "${UBUNTU_SNAPSHOT}" > /usr/share/robotics-runtime/media-ubuntu-snapshot \
    && python3 -c 'import gi;gi.require_version("Gst","1.0");from gi.repository import Gst;Gst.init(None);print(Gst.version_string());assert Gst.ElementFactory.find("videotestsrc");assert Gst.ElementFactory.find("appsink");assert Gst.ElementFactory.find("rtspsrc");assert Gst.ElementFactory.find("rtph264depay");assert Gst.ElementFactory.find("h264parse");assert Gst.ElementFactory.find("avdec_h264")' \
    && rm -rf /var/lib/apt/lists/* /var/log/apt/* /var/log/dpkg.log
USER 1000:1000
WORKDIR /run/robotics
ENTRYPOINT ["python3"]
