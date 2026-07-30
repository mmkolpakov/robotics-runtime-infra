#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

: "${COMPOSE_PROJECT_NAME:?COMPOSE_PROJECT_NAME is required}"
: "${IMAGE_REF:?IMAGE_REF is required}"
: "${OVERLAY:?OVERLAY is required}"
: "${PROFILE:?PROFILE is required}"

status=0
docker compose \
  -f compose.yaml \
  -f "${OVERLAY}" \
  --profile "${PROFILE}" \
  down --volumes --remove-orphans || status=70

for image in "${IMAGE_REF}" "${SUPPORT_IMAGE_REF:-}"; do
  image_ids=
  test -n "${image}" || continue
  image_ids="$(
    docker image ls --quiet --no-trunc "${image}"
  )" || {
    printf 'qualification image inventory failed: %s\n' "${image}" >&2
    status=70
    continue
  }
  if test -n "${image_ids}"; then
    docker image rm "${image}" || status=70
  fi
done

containers="$(
  docker container ls --all --quiet \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}"
)" || status=70
networks="$(
  docker network ls --quiet \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}"
)" || status=70
volumes="$(
  docker volume ls --quiet \
    --filter "label=com.docker.compose.project=${COMPOSE_PROJECT_NAME}"
)" || status=70

for entry in \
  "container:${containers:-}" \
  "network:${networks:-}" \
  "volume:${volumes:-}"; do
  resource_type="${entry%%:*}"
  resources="${entry#*:}"
  if test -n "${resources}"; then
    printf '%s resources remain for Compose project %s: %s\n' \
      "${resource_type}" "${COMPOSE_PROJECT_NAME}" "${resources}" >&2
    status=70
  fi
done

for image in "${IMAGE_REF}" "${SUPPORT_IMAGE_REF:-}"; do
  image_ids=
  test -n "${image}" || continue
  image_ids="$(
    docker image ls --quiet --no-trunc "${image}"
  )" || {
    printf 'qualification image inventory failed after cleanup: %s\n' \
      "${image}" >&2
    status=70
    continue
  }
  if test -n "${image_ids}"; then
    printf 'qualification image remains after cleanup: %s\n' "${image}" >&2
    status=70
  fi
done

exit "${status}"
