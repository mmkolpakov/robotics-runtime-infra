#!/usr/bin/env bash
set -Eeuo pipefail

test "${STATIC_RESULT}" = success
test "${COMPOSE_RESULT}" = success
test "${INTEGRATION_RESULT}" = success
test "${AMD_RESULT}" = success
test "${INTEL_RESULT}" = success
test "${NVIDIA_RESULT}" = success
test "${NVIDIA_JETSON_RESULT}" = success
test "${RKNN_RESULT}" = success
test "${RKNN_ARM64_RESULT}" = success
test "${ARM64_RESULT}" = success
test "${REPRO_RESULT}" = success
