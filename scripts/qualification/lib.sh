#!/usr/bin/env bash

QUALIFICATION_PREDICATE_TYPE='https://robotics-runtime-contracts.dev/attestations/qualification-bundle/v2'

qualification_fail() {
  printf 'qualification: %s\n' "$*" >&2
  exit 65
}

qualification_require_command() {
  command -v "$1" >/dev/null 2>&1 || qualification_fail "required command is missing: $1"
}

qualification_require_file() {
  local path="$1"
  [[ -f "$path" && -r "$path" && ! -L "$path" ]] ||
    qualification_fail "required regular file is not readable: $path"
  [[ "$path" != *$'\n'* && "$path" != *$'\t'* ]] ||
    qualification_fail "file path contains a tab or newline: $path"
}

qualification_sha256() {
  sha256sum "$1" | cut -d' ' -f1
}

# Assigns sourced-library state consumed by the two qualification entrypoints.
# shellcheck disable=SC2034
qualification_parse_cli() {
  local mode="$1"
  shift
  [[ "$mode" == create || "$mode" == verify ]] || qualification_fail "invalid CLI mode: $mode"

  scenario_path=''
  acceptance_run_path=''
  aggregate_path=''
  transport_qualification_path=''
  output=''
  bundle=''
  verification_key=''
  trusted_root=''
  policy=''
  runtime_manifest_specs=()
  result_specs=()
  evidence_index_specs=()
  mcap_summary_specs=()
  optional_evidence_specs=()
  extension_schema_specs=()

  while (($# > 0)); do
    case "$1" in
      --bundle)
        [[ "$mode" == verify && $# -ge 2 ]] || usage
        bundle="$2"
        shift 2
        ;;
      --key)
        [[ "$mode" == verify && $# -ge 2 ]] || usage
        verification_key="$2"
        shift 2
        ;;
      --trusted-root)
        [[ "$mode" == verify && $# -ge 2 ]] || usage
        trusted_root="$2"
        shift 2
        ;;
      --policy)
        [[ "$mode" == verify && $# -ge 2 ]] || usage
        policy="$2"
        shift 2
        ;;
      --scenario)
        (($# >= 2)) || usage
        scenario_path="$2"
        shift 2
        ;;
      --runtime-manifest)
        (($# >= 2)) || usage
        runtime_manifest_specs+=("$2")
        shift 2
        ;;
      --acceptance-run)
        (($# >= 2)) || usage
        acceptance_run_path="$2"
        shift 2
        ;;
      --result)
        (($# >= 2)) || usage
        result_specs+=("$2")
        shift 2
        ;;
      --aggregate)
        (($# >= 2)) || usage
        aggregate_path="$2"
        shift 2
        ;;
      --transport-qualification)
        (($# >= 2)) || usage
        transport_qualification_path="$2"
        shift 2
        ;;
      --evidence-index)
        (($# >= 2)) || usage
        evidence_index_specs+=("$2")
        shift 2
        ;;
      --mcap-summary)
        (($# >= 2)) || usage
        mcap_summary_specs+=("$2")
        shift 2
        ;;
      --evidence)
        (($# >= 2)) || usage
        optional_evidence_specs+=("$2")
        shift 2
        ;;
      --extension-schema)
        (($# >= 2)) || usage
        extension_schema_specs+=("$2")
        shift 2
        ;;
      --output)
        [[ "$mode" == create && $# -ge 2 ]] || usage
        output="$2"
        shift 2
        ;;
      *)
        usage
        ;;
    esac
  done

  [[ "$mode" == verify || -n "$output" ]] || usage
}

qualification_resolve_contracts_cli() {
  if [[ -n "${ROBOTICS_CONTRACTS_CLI:-}" ]]; then
    [[ -x "$ROBOTICS_CONTRACTS_CLI" ]] ||
      qualification_fail \
        "ROBOTICS_CONTRACTS_CLI is not executable: $ROBOTICS_CONTRACTS_CLI"
    QUALIFICATION_CONTRACTS_CLI="$ROBOTICS_CONTRACTS_CLI"
  elif command -v robotics-contracts >/dev/null 2>&1; then
    QUALIFICATION_CONTRACTS_CLI="$(command -v robotics-contracts)"
  elif [[ -x dependencies/robotics-runtime-contracts/.venv/bin/robotics-contracts ]]; then
    QUALIFICATION_CONTRACTS_CLI="$PWD/dependencies/robotics-runtime-contracts/.venv/bin/robotics-contracts"
  else
    qualification_fail \
      'robotics-contracts CLI is unavailable; install robotics-runtime-contracts 0.13.0 or newer'
  fi
}

qualification_validate_contract() {
  local document="$1"
  local schema_name="$2"

  [[ -n "${QUALIFICATION_CONTRACTS_CLI:-}" ]] ||
    qualification_resolve_contracts_cli
  "$QUALIFICATION_CONTRACTS_CLI" validate \
    "$document" --schema "$schema_name" --quiet >/dev/null ||
    qualification_fail "$document does not satisfy $schema_name"
}

qualification_parse_named_file() {
  local specification="$1"

  [[ "$specification" == *=* ]] ||
    qualification_fail "expected LABEL=PATH, got: $specification"
  QUALIFICATION_LABEL="${specification%%=*}"
  QUALIFICATION_PATH="${specification#*=}"
  [[ "$QUALIFICATION_LABEL" =~ ^[a-z][a-z0-9]*([._-][a-z0-9]+)*$ ]] ||
    qualification_fail "invalid artifact label: $QUALIFICATION_LABEL"
  [[ -n "$QUALIFICATION_PATH" ]] ||
    qualification_fail "artifact path is empty for label: $QUALIFICATION_LABEL"
}

qualification_parse_evidence_file() {
  local specification="$1"
  local remainder

  [[ "$specification" == *:* ]] ||
    qualification_fail "expected KIND:LABEL=PATH, got: $specification"
  QUALIFICATION_KIND="${specification%%:*}"
  remainder="${specification#*:}"
  qualification_parse_named_file "$remainder"
}

qualification_append_subject() {
  local kind="$1"
  local subject_name="$2"
  local path="$3"

  qualification_require_file "$path"
  QUALIFICATION_ARTIFACT_SPECS+=("$kind:$subject_name=$path")
}

qualification_collect_subjects() {
  local specification
  local label
  local path

  QUALIFICATION_ARTIFACT_SPECS=()

  qualification_append_subject scenario scenario.json "$scenario_path"
  qualification_append_subject \
    acceptance_run acceptance-run.json "$acceptance_run_path"
  qualification_append_subject \
    acceptance_aggregate acceptance-aggregate.json "$aggregate_path"
  if [[ -n "$transport_qualification_path" ]]; then
    qualification_append_subject \
      transport_qualification transport-qualification.json \
      "$transport_qualification_path"
  fi

  # The caller owns these arrays; this file is a sourced command library.
  # shellcheck disable=SC2154
  for specification in "${runtime_manifest_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject \
      runtime_manifest "runtime-manifests/$label.json" "$path"
  done
  # shellcheck disable=SC2154
  for specification in "${result_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject domain_result "results/$label.json" "$path"
  done
  # shellcheck disable=SC2154
  for specification in "${evidence_index_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject \
      evidence_index "evidence-indexes/$label.json" "$path"
  done
  # shellcheck disable=SC2154
  for specification in "${mcap_summary_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject \
      mcap_summary "mcap-summaries/$label.json" "$path"
  done
  # shellcheck disable=SC2154
  for specification in "${optional_evidence_specs[@]}"; do
    qualification_parse_evidence_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject \
      "$QUALIFICATION_KIND" "evidence/$label" "$path"
  done
}

qualification_validate_links() {
  local work="$1"
  local specification
  local command=(
    "$QUALIFICATION_CONTRACTS_CLI"
    validate-qualification
    --quiet
    --output
    "$work/validated-artifacts.json"
  )

  # The caller owns this array; this file is a sourced command library.
  # shellcheck disable=SC2154
  for specification in "${extension_schema_specs[@]}"; do
    command+=(--extension-schema "$specification")
  done
  for specification in "${QUALIFICATION_ARTIFACT_SPECS[@]}"; do
    command+=(--artifact "$specification")
  done
  "${command[@]}" >/dev/null ||
    qualification_fail 'qualification artifact set is invalid'

  jq -S '[.artifacts[] | {name: .subject_name, digest: {sha256}}]' \
    "$work/validated-artifacts.json" >"$work/subjects.json"
  jq -S '[.artifacts[] | {kind, subject_name}]' \
    "$work/validated-artifacts.json" >"$work/artifacts.json"
  jq -er '.run_id' "$work/validated-artifacts.json" >"$work/run-id"
  jq -er '.generated_at' "$work/validated-artifacts.json" >"$work/generated-at"
  jq -er '.artifacts[] | select(.kind == "acceptance_aggregate") | .sha256' \
    "$work/validated-artifacts.json" >"$work/aggregate-sha256"
}

qualification_write_statement() {
  local work="$1"
  local output="$2"
  local temporary

  mkdir -p "$(dirname "$output")"
  temporary="$(mktemp "$(dirname "$output")/.qualification-statement.XXXXXX")"
  jq -S \
    --arg predicate_type "$QUALIFICATION_PREDICATE_TYPE" \
    --arg run_id "$(cat "$work/run-id")" \
    --arg generated_at "$(cat "$work/generated-at")" \
    --slurpfile subjects "$work/subjects.json" \
    --slurpfile artifacts "$work/artifacts.json" \
    -n '{
      "_type": "https://in-toto.io/Statement/v1",
      "subject": $subjects[0],
      "predicateType": $predicate_type,
      "predicate": {
        "schema_version": "qualification-bundle.v2",
        "run_id": $run_id,
        "generated_at": $generated_at,
        "artifacts": $artifacts[0]
      }
    }' >"$temporary"
  qualification_validate_contract "$temporary" qualification-bundle.v2
  chmod 0444 "$temporary"
  mv "$temporary" "$output"
}

qualification_prepare() {
  local work="$1"

  qualification_require_command jq
  qualification_resolve_contracts_cli
  [[ -n "$scenario_path" ]] || qualification_fail '--scenario is required'
  [[ -n "$acceptance_run_path" ]] || qualification_fail '--acceptance-run is required'
  [[ -n "$aggregate_path" ]] || qualification_fail '--aggregate is required'

  qualification_collect_subjects
  qualification_validate_links "$work"
}
