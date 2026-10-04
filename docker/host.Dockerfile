# syntax=docker/dockerfile:1.14
FROM node:24.21.0-trixie-slim@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697
ARG HOST_ASSET_SHA256
ARG IMAGE_CREATED=1970-01-01T00:00:00Z
ARG VCS_REF=local
LABEL org.opencontainers.image.title="Robotics Cordis host" \
      org.opencontainers.image.source="https://github.com/mmkolpakov/robotics-runtime-infra" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.created="${IMAGE_CREATED}"
WORKDIR /opt/robotics/infra
COPY host/package.json host/package-lock.json ./
# The exact native host asset is the same fixed file dependency used by TypeScript.
COPY --from=host-asset /host.tgz ./.tools/core.tgz
RUN test -n "${HOST_ASSET_SHA256}" \
    && printf '%s  %s\n' "${HOST_ASSET_SHA256}" /opt/robotics/infra/.tools/core.tgz | sha256sum --check \
    && npm ci --omit=dev --ignore-scripts --no-audit --no-fund \
    && test "$(node --version)" = v24.21.0 \
    && test "$(npm --version)" = 11.19.0
COPY host/dist/src ./dist/src
ADD --chmod=0555 https://github.com/docker/compose/releases/download/v5.3.1/docker-compose-linux-x86_64 /usr/local/bin/docker-compose
RUN printf '%s  %s\n' f9ebc6ebdb19d769b793c245a736caaeb198c62587f13b25c660c13b4987f959 /usr/local/bin/docker-compose | sha256sum --check \
    && test "$(docker-compose version --short)" = 5.3.1
USER 1000:1000
WORKDIR /run/robotics/input/profile
ENTRYPOINT ["/opt/robotics/infra/node_modules/.bin/cordis"]
