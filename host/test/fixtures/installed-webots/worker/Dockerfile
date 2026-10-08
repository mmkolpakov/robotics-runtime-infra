# syntax=docker/dockerfile:1.14
ARG FOUNDATION_WHEELS_IMAGE
FROM ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa AS uv
FROM ${FOUNDATION_WHEELS_IMAGE} AS foundation-wheels
FROM localhost/rr-webots-worker@sha256:40ab3b23a99c6ddff68ba6398a2275789b4967ae26d1c1f159385af9f147e339
USER 0:0
ENV UV_CACHE_DIR=/tmp/c18-sdk-build-cache
COPY --from=uv /uv /usr/local/bin/uv
COPY assets/dependencies.lock /opt/c18/dependencies.lock
COPY --from=foundation-wheels /tmp/foundation-lock.json /tmp/built-foundation-lock.json
COPY --chmod=0444 assets/foundation-lock.json /usr/share/robotics-runtime/foundation-lock.json
RUN --mount=from=foundation-wheels,source=/out,target=/tmp/foundation-wheels,ro \
    cmp /tmp/built-foundation-lock.json /usr/share/robotics-runtime/foundation-lock.json \
    && uv venv --python /usr/bin/python3 /opt/contracts \
    && uv pip install --python /opt/contracts/bin/python --require-hashes --no-deps -r /opt/c18/dependencies.lock \
    && UV_NO_INSTALLER_METADATA=1 uv --directory /tmp/foundation-wheels pip install \
      --python /opt/contracts/bin/python --require-hashes --no-deps --requirement harness.requirements \
    && uv pip check --python /opt/contracts/bin/python \
    && /opt/contracts/bin/python -c 'import json;from importlib.metadata import version;lock=json.load(open("/usr/share/robotics-runtime/foundation-lock.json"));assert all(version(p["distribution"])==p["version"] for p in lock["packages"].values())' \
    && uv pip freeze --python /opt/contracts/bin/python > /usr/share/robotics-runtime/webots-python-packages.txt
COPY assets/provider_qualification.py assets/native-provider-source.v1.schema.json document-checks.py portable-checks.py /opt/c18/
RUN rm -rf /tmp/c18-sdk-build-cache /tmp/robotics-webots && chmod -R a-w /opt/c18 /opt/contracts
USER 10001:1000
