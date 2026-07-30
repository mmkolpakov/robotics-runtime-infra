#!/usr/bin/env bash
set -Eeuo pipefail

docker run --rm --volume "${PWD}:/work:ro" --workdir /work "${RENOVATE_IMAGE}" renovate-config-validator --strict renovate.json
