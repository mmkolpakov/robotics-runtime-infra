#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"
mkdir -p artifacts

docker ps --all --no-trunc > artifacts/docker-containers.txt
docker network ls --no-trunc > artifacts/docker-networks.txt
