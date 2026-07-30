#!/usr/bin/env bash
set -Eeuo pipefail

docker run --rm --volume "${PWD}:/work:ro" --workdir /work "${HADOLINT_IMAGE}" /bin/hadolint --config .hadolint.yaml Dockerfile docker/rknn.Dockerfile
