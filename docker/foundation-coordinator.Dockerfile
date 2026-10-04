# syntax=docker/dockerfile:1.14
FROM ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa AS uv
ARG LEGACY_BASE_IMAGE
FROM ${LEGACY_BASE_IMAGE}
USER 0:0
COPY --from=uv /uv /usr/local/bin/uv
COPY docker/python/acceptance-observer.lock /tmp/acceptance-dependencies.lock
RUN /usr/local/bin/uv pip install --python /opt/contracts/bin/python --require-hashes --no-deps -r /tmp/acceptance-dependencies.lock \
    && printf '%s\n' 'robotics-runtime-contracts==0.18.2 --hash=sha256:0e47072d262e8a12a7ad6446968b114880a2d9698c9a341a6698a36aa20669b6' > /tmp/contracts.lock \
    && /usr/local/bin/uv pip install --python /opt/contracts/bin/python --require-hashes --no-deps -r /tmp/contracts.lock \
    && printf '%s\n' 'robotics-acceptance-harness==0.19.1 --hash=sha256:1ddd6c122b0f9af20d02f82d2b5b11cd259fd0c442c85e007abad64e1f94fa98' > /tmp/harness.lock \
    && /usr/local/bin/uv pip install --python /opt/contracts/bin/python --require-hashes --no-deps -r /tmp/harness.lock \
    && /usr/local/bin/uv pip check --python /opt/contracts/bin/python \
    && /opt/contracts/bin/python -c 'import importlib.metadata as m;assert m.version("robotics-runtime-contracts")=="0.18.2";assert m.version("robotics-acceptance-harness")=="0.19.1";print(m.version("robotics-runtime-contracts"),m.version("robotics-acceptance-harness"))' \
    && /usr/local/bin/uv pip freeze --python /opt/contracts/bin/python > /usr/share/robotics-runtime/coordinator-python-packages.txt
USER 1000:1000
ENTRYPOINT ["/usr/local/bin/robotics-entrypoint"]
