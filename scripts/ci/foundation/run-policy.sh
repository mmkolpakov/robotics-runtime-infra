#!/usr/bin/env bash

# Sourced after scripts/ci/lib.sh. Policy input paths must be readable inside
# ci_opa's repository mount; use the run's private copy of consumer inputs.
foundation_require_scenario_policy() {
  local python="$1" scenario="$2" output="$3"
  # Share the verifier's parser, including duplicate-key and YAML scalar rules.
  # Schema/semantic validation still runs when the acceptance context is created.
  "${python}" - "${scenario}" >"${output}" <<'PY' || return
import json
import sys
from robotics_runtime_contracts.serialization import load_mapping

json.dump(load_mapping(sys.argv[1]), sys.stdout, allow_nan=False, sort_keys=True)
PY
  ci_require_policy_allows policy/scenario.rego scenario "${output}"
}

foundation_require_release_images_policy() {
  local model="$1" output="$2"
  local mode="${ROBOTICS_RUNTIME_MODE:-source}"
  case "${mode}" in
    source|released) ;;
    *) printf 'unsupported runtime mode: %s\n' "${mode}" >&2; return 64 ;;
  esac
  # Compose include does not preserve every top-level extension. The caller's
  # execution mode is authoritative even if a consumer declares mode: source.
  jq --arg mode "${mode}" '."x-robotics-runtime".mode = $mode' \
    "${model}" >"${output}" || return
  ci_require_policy_allows policy/release-images.rego release_images "${output}"
}
