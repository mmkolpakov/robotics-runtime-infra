# syntax=docker/dockerfile:1.19
FROM ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa AS uv
FROM ros:jazzy-ros-base@sha256:31daab66eef9139933379fb67159449944f4e2dcf2e22c2d12cc715f29873e0f AS certificates
FROM ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90 AS controller-base
COPY --from=uv /uv /usr/local/bin/uv
COPY --from=certificates /etc/ssl/certs/ca-certificates.crt /etc/ssl/certs/ca-certificates.crt
RUN sed -i -E 's#http://(archive|security).ubuntu.com/ubuntu/?#https://snapshot.ubuntu.com/ubuntu/20260930T000000Z/#g' /etc/apt/sources.list.d/ubuntu.sources \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install -y --no-install-recommends python3 python3-venv ca-certificates passwd \
    && rm -rf /var/lib/apt/lists/* \
    && groupadd --gid 123 _chrony \
    && useradd --uid 123 --gid _chrony --no-create-home --shell /usr/sbin/nologin _chrony
FROM controller-base AS checks
COPY ansible/requirements.lock /tmp/requirements.lock
RUN uv venv --python /usr/bin/python3 /opt/ansible \
    && uv pip install --python /opt/ansible/bin/python --require-hashes --no-deps -r /tmp/requirements.lock
ENV PATH="/opt/ansible/bin:$PATH" ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
WORKDIR /src/ansible
ENTRYPOINT ["/opt/ansible/bin/python", "/src/ansible/tests/check.py"]
