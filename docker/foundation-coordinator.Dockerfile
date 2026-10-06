# syntax=docker/dockerfile:1.14
ARG FOUNDATION_WHEELS_IMAGE
ARG LEGACY_BASE_IMAGE
FROM ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa AS uv
FROM ${FOUNDATION_WHEELS_IMAGE} AS foundation-wheels
FROM ${LEGACY_BASE_IMAGE}
USER 0:0
COPY --from=uv /uv /usr/local/bin/uv
COPY docker/python/acceptance-observer.lock /tmp/acceptance-dependencies.lock
COPY --from=foundation-wheels /tmp/foundation-lock.json /tmp/built-foundation-lock.json
COPY --chmod=0444 foundation.repos /usr/share/robotics-runtime/foundation.repos
COPY --chmod=0444 config/foundation-lock.json /usr/share/robotics-runtime/foundation-lock.json
RUN --mount=from=foundation-wheels,source=/out,target=/tmp/foundation-wheels,ro \
    cmp /tmp/built-foundation-lock.json /usr/share/robotics-runtime/foundation-lock.json \
    && /usr/local/bin/uv pip install --python /opt/contracts/bin/python --require-hashes --no-deps -r /tmp/acceptance-dependencies.lock \
    && UV_NO_INSTALLER_METADATA=1 /usr/local/bin/uv --directory /tmp/foundation-wheels pip install \
      --python /opt/contracts/bin/python --require-hashes --no-deps --requirement harness.requirements \
    && /usr/local/bin/uv pip check --python /opt/contracts/bin/python \
    && /opt/contracts/bin/python -c 'import json;from importlib.metadata import version;lock=json.load(open("/usr/share/robotics-runtime/foundation-lock.json"));assert all(version(p["distribution"])==p["version"] for p in lock["packages"].values())' \
    && /usr/local/bin/uv pip freeze --python /opt/contracts/bin/python > /usr/share/robotics-runtime/coordinator-python-packages.txt
ENV ROBOTICS_REQUIRE_HARNESS=true
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/robotics-entrypoint"]
