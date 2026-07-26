#!/usr/bin/env bash
set -Eeuo pipefail

: "${EXPECTED_COMPOSE_VERSION:?EXPECTED_COMPOSE_VERSION is required}"
actual="v$(docker compose version --short | sed 's/^v//')"
test "${actual}" = "${EXPECTED_COMPOSE_VERSION}"
