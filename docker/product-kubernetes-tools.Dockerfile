# syntax=docker/dockerfile:1.19
# Official uv publisher, pinned by immutable multiarch digest.
# hadolint ignore=DL3026
FROM ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa AS uv
FROM ros:jazzy-ros-base@sha256:31daab66eef9139933379fb67159449944f4e2dcf2e22c2d12cc715f29873e0f AS certificates
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90 AS tools-base
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --from=uv /uv /usr/local/bin/uv
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN sed -i -E 's#http://(archive|security).ubuntu.com/ubuntu/?#https://snapshot.ubuntu.com/ubuntu/20260930T000000Z/#g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install -y --no-install-recommends python3 ca-certificates curl \
    && rm -rf /var/lib/apt/lists/*
RUN curl -fsSL https://get.helm.sh/helm-v4.3.0-linux-amd64.tar.gz -o /tmp/helm.tar.gz \
    && echo "86584a54def73570558f66f5111cc53dfed56689637ae32c1201205d494f54fb  /tmp/helm.tar.gz" | sha256sum -c - \
    && tar -xzf /tmp/helm.tar.gz -C /tmp \
    && install -m 0755 /tmp/linux-amd64/helm /usr/local/bin/helm \
    && rm -rf /tmp/helm.tar.gz /tmp/linux-amd64
RUN curl -fsSL https://dl.k8s.io/release/v1.35.9/bin/linux/amd64/kubectl -o /tmp/kubectl \
    && echo "3cfeaf80be482b435b0aa214aff6e0b2c312ee23c0ff20810c75517b6004c6eb  /tmp/kubectl" | sha256sum -c - \
    && install -m 0755 /tmp/kubectl /usr/local/bin/kubectl \
    && rm /tmp/kubectl
RUN mkdir -p /opt/kubernetes \
    && curl -fsSL https://raw.githubusercontent.com/kubernetes/kubernetes/v1.34.0/api/openapi-spec/swagger.json -o /opt/kubernetes/swagger.json \
    && echo "d3b0cdc2fda15c753206d25ab459dc7c12df64e2fd652b6809687471ea751c37  /opt/kubernetes/swagger.json" | sha256sum -c -
FROM tools-base AS preflight
COPY helm/verify-kubernetes-binding.py /opt/robotics/verify-kubernetes-binding.py
USER 1000:1000
ENTRYPOINT ["python3", "/opt/robotics/verify-kubernetes-binding.py"]
FROM tools-base AS checks
COPY helm/requirements.lock /tmp/requirements.lock
RUN uv venv --python /usr/bin/python3 /opt/checks \
    && uv pip install --python /opt/checks/bin/python --require-hashes --no-deps -r /tmp/requirements.lock
COPY helm/ /src/helm/
WORKDIR /src/helm
ENTRYPOINT ["/opt/checks/bin/python", "/src/helm/tests/check.py"]
