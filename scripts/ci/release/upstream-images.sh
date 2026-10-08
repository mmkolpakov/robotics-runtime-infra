#!/usr/bin/env bash

ci_release_otel_collector_reference() (
  set -o pipefail
  # Inspect the trusted default, without evaluating ambient image overrides.
  docker compose --project-directory "${CI_REPO_ROOT}" --env-file /dev/null \
    --file "${CI_REPO_ROOT}/compose.yaml" \
    --file "${CI_REPO_ROOT}/compose.observability.yaml" \
    --profile '*' config --no-interpolate --format json |
    jq -er '
      .services["otel-collector"].image |
      capture("^\\$\\{OTEL_COLLECTOR_IMAGE:-(?<image>otel/opentelemetry-collector-contrib:[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64})\\}$").image
    '
)

ci_release_edge_attach_data_plane_reference() (
  set -o pipefail
  # Inspect the trusted default, without evaluating ambient image overrides.
  docker compose --project-directory "${CI_REPO_ROOT}" --env-file /dev/null \
    --file "${CI_REPO_ROOT}/compose.yaml" \
    --file "${CI_REPO_ROOT}/compose.edge-attach.yaml" \
    --profile '*' config --no-interpolate --format json |
    jq -er '
      .services["edge-attach-data-plane"].image |
      capture("^\\$\\{EDGE_ATTACH_DATA_PLANE_IMAGE:-(?<image>registry.k8s.io/pause:[0-9]+\\.[0-9]+\\.[0-9]+@sha256:[a-f0-9]{64})\\}$").image
    '
)
