# syntax=docker/dockerfile:1.19
# Published Ubuntu 24.04 base digest with python3, curl and ca-certificates.
# The domain gate builds this image without apt against the snapshot mirror.
FROM ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa AS uv
FROM ros:jazzy-ros-base@sha256:31daab66eef9139933379fb67159449944f4e2dcf2e22c2d12cc715f29873e0f AS controller-base
COPY --from=uv /uv /usr/local/bin/uv
RUN groupadd --gid 123 _chrony \
    && useradd --uid 123 --gid _chrony --no-create-home --shell /usr/sbin/nologin _chrony
FROM controller-base AS checks
COPY ansible/requirements.lock /tmp/requirements.lock
RUN uv venv --python /usr/bin/python3 /opt/ansible \
    && uv pip install --python /opt/ansible/bin/python --require-hashes --no-deps -r /tmp/requirements.lock
ENV PATH="/opt/ansible/bin:$PATH" ANSIBLE_LOCAL_TEMP=/tmp/ansible-local
WORKDIR /src/ansible
ENTRYPOINT ["/opt/ansible/bin/python", "/src/ansible/tests/check.py"]
