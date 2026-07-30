#!/usr/bin/env bash
set -Eeuo pipefail

work_dir="${PWD}/artifacts/security-runtime"
project="security-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -p "${work_dir}"
sudo chown -R 1000:1000 "${work_dir}"
export ROS_DOMAIN_ID=92
export ROBOTICS_SECURITY_WORK_DIR="${work_dir}"
compose=(
  docker compose -p "${project}"
  -f compose.yaml
  -f compose.security.yaml
)
cleanup() {
  "${compose[@]}" \
    --profile security --profile security-init \
    --profile security-verify --profile security-negative \
    --profile security-observer \
    --profile security-observer-negative \
    down --volumes --remove-orphans || true
}
trap cleanup EXIT
"${compose[@]}" --profile security-init \
  run --rm security-artifacts
"${compose[@]}" --profile security-verify \
  run --rm security-signature-check
"${compose[@]}" --profile security \
  up --no-build --abort-on-container-exit \
  --exit-code-from secure-listener \
  secure-listener secure-talker
"${compose[@]}" --profile security \
  down --volumes --remove-orphans
"${compose[@]}" --profile security-negative \
  run --rm secure-denied-remap
"${compose[@]}" --profile security-negative \
  run --rm secure-missing-enclave
"${compose[@]}" --profile security-negative \
  up --no-build --abort-on-container-exit \
  --exit-code-from secure-reject-unsecured-listener \
  secure-reject-unsecured-listener unsecured-talker
"${compose[@]}" --profile security-negative \
  down --volumes --remove-orphans
"${compose[@]}" --profile security-observer \
  up --no-build --abort-on-container-exit \
  --exit-code-from secure-observer \
  secure-observer secure-observer-source
"${compose[@]}" --profile security-observer \
  down --volumes --remove-orphans
"${compose[@]}" --profile security-observer-negative \
  run --rm secure-observer-denied-command
