FROM docker.io/library/node:24.21.0-trixie-slim@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697
WORKDIR /app
COPY assets /app/assets
COPY package.json package-lock.json /app/
RUN npm ci --ignore-scripts --no-audit --no-fund --cache /tmp/npm-cache && rm -rf /tmp/npm-cache
COPY app /app/
COPY profiles /app/profiles/
COPY identity.json compose.legacy-retained.yaml compose.legacy-finalization.podman.yaml /app/
COPY tools/docker-compose /usr/local/bin/docker-compose
RUN test "$(node --version)" = v24.21.0 && test "$(npm --version)" = 11.19.0 && test "$(docker-compose version --short)" = 5.3.1 && chmod -R a-w /app
USER 1000:1000
ENTRYPOINT ["node", "/app/bootstrap.mjs"]
