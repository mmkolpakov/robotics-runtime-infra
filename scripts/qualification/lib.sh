#!/usr/bin/env bash

QUALIFICATION_PREDICATE_TYPE='https://robotics-runtime-contracts.dev/attestations/qualification-bundle/v1'

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
      'robotics-contracts CLI is unavailable; install robotics-runtime-contracts 0.10.0 or newer'
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

qualification_validate_declared_contracts() {
  (($# > 0)) || qualification_fail 'no contract documents were supplied'
  [[ -n "${QUALIFICATION_CONTRACTS_CLI:-}" ]] ||
    qualification_resolve_contracts_cli
  local command=(
    "$QUALIFICATION_CONTRACTS_CLI"
    validate
    --quiet
  )
  local specification

  # The caller owns this array; this file is a sourced command library.
  # shellcheck disable=SC2154
  for specification in "${extension_schema_specs[@]}"; do
    command+=(--extension-schema "$specification")
  done
  command+=("$@")
  "${command[@]}" >/dev/null ||
    qualification_fail 'one or more documents do not satisfy their declared contracts'
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
  case "$QUALIFICATION_KIND" in
    metrics | traces | junit | channel_contract | channel_observation | other_evidence) ;;
    *) qualification_fail "unsupported optional evidence kind: $QUALIFICATION_KIND" ;;
  esac
  qualification_parse_named_file "$remainder"
}

qualification_append_subject() {
  local work="$1"
  local kind="$2"
  local subject_name="$3"
  local path="$4"
  local digest

  qualification_require_file "$path"
  [[ "$subject_name" =~ ^[a-z0-9][a-z0-9._/-]{0,1023}$ ]] ||
    qualification_fail "invalid in-toto subject name: $subject_name"
  [[ "$subject_name" != *'..'* && "$subject_name" != *'//'* ]] ||
    qualification_fail "non-canonical in-toto subject name: $subject_name"
  digest="$(qualification_sha256 "$path")"
  jq -cn --arg name "$subject_name" --arg digest "$digest" \
    '{name: $name, digest: {sha256: $digest}}' >>"$work/subjects.ndjson"
  jq -cn --arg kind "$kind" --arg subject_name "$subject_name" \
    '{kind: $kind, subject_name: $subject_name}' >>"$work/artifacts.ndjson"
  printf '%s\t%s\t%s\t%s\n' "$kind" "$subject_name" "$digest" "$path" \
    >>"$work/paths.tsv"
}

qualification_collect_subjects() {
  local work="$1"
  local specification
  local label
  local path

  : >"$work/subjects.ndjson"
  : >"$work/artifacts.ndjson"
  : >"$work/paths.tsv"

  qualification_append_subject "$work" scenario scenario.json "$scenario_path"
  qualification_append_subject \
    "$work" acceptance_run acceptance-run.json "$acceptance_run_path"
  qualification_append_subject \
    "$work" acceptance_aggregate acceptance-aggregate.json "$aggregate_path"

  # The caller owns these arrays; this file is a sourced command library.
  # shellcheck disable=SC2154
  for specification in "${runtime_manifest_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject \
      "$work" runtime_manifest "runtime-manifests/$label.json" "$path"
  done
  # shellcheck disable=SC2154
  for specification in "${result_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject "$work" domain_result "results/$label.json" "$path"
  done
  # shellcheck disable=SC2154
  for specification in "${evidence_index_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject \
      "$work" evidence_index "evidence-indexes/$label.json" "$path"
  done
  # shellcheck disable=SC2154
  for specification in "${mcap_summary_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject \
      "$work" mcap_summary "mcap-summaries/$label.json" "$path"
  done
  # shellcheck disable=SC2154
  for specification in "${optional_evidence_specs[@]}"; do
    qualification_parse_evidence_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    qualification_append_subject \
      "$work" "$QUALIFICATION_KIND" "evidence/$label" "$path"
  done

  jq -s 'sort_by(.name)' "$work/subjects.ndjson" >"$work/subjects.json"
  jq -s 'sort_by(.subject_name)' "$work/artifacts.ndjson" >"$work/artifacts.json"
  [[ "$(jq '[.[].name] | length == (unique | length)' "$work/subjects.json")" == true ]] ||
    qualification_fail 'in-toto subject names must be unique'
}

qualification_validate_links() {
  local work="$1"
  local run_id
  local generated_at
  local run_sha256
  local scenario_sha256
  local aggregate_run_id
  local aggregate_run_sha256
  local specification
  local label
  local path
  local result_run_id
  local result_domain_id
  local result_sha256
  local runtime_sha256
  local fastdds_profile_sha256
  local result_domains
  local run_domains
  local runtime_domains
  local evidence_domains
  local aggregate_results
  local local_results
  local referenced_mcap
  local local_mcap
  local scenario_schema
  local aggregate_schema
  local contract_documents=(
    "$scenario_path"
    "$acceptance_run_path"
    "$aggregate_path"
  )

  scenario_schema="$(yq -er '.schema_version' "$scenario_path")"
  case "$scenario_schema" in
    acceptance-scenario.v4) ;;
    *) qualification_fail "unsupported scenario contract: $scenario_schema" ;;
  esac
  [[ "$(jq -er '.schema_version' "$acceptance_run_path")" == acceptance-run.v1 ]] ||
    qualification_fail 'acceptance run must declare acceptance-run.v1'
  aggregate_schema="$(jq -er '.schema_version' "$aggregate_path")"
  case "$aggregate_schema" in
    acceptance-aggregate.v1 | acceptance-aggregate.v2) ;;
    *) qualification_fail "unsupported aggregate contract: $aggregate_schema" ;;
  esac
  # The caller owns these arrays; this file is a sourced command library.
  # shellcheck disable=SC2154
  for specification in "${runtime_manifest_specs[@]}"; do
    qualification_parse_named_file "$specification"
    contract_documents+=("$QUALIFICATION_PATH")
  done
  # shellcheck disable=SC2154
  for specification in "${result_specs[@]}"; do
    qualification_parse_named_file "$specification"
    contract_documents+=("$QUALIFICATION_PATH")
  done
  # shellcheck disable=SC2154
  for specification in "${evidence_index_specs[@]}"; do
    qualification_parse_named_file "$specification"
    contract_documents+=("$QUALIFICATION_PATH")
  done
  # shellcheck disable=SC2154
  for specification in "${mcap_summary_specs[@]}"; do
    qualification_parse_named_file "$specification"
    contract_documents+=("$QUALIFICATION_PATH")
  done
  # shellcheck disable=SC2154
  for specification in "${optional_evidence_specs[@]}"; do
    qualification_parse_evidence_file "$specification"
    case "$QUALIFICATION_KIND" in
      channel_contract | channel_observation)
        contract_documents+=("$QUALIFICATION_PATH")
        ;;
      metrics | traces | junit | other_evidence) ;;
    esac
  done
  qualification_validate_declared_contracts "${contract_documents[@]}"

  run_id="$(jq -er '.run_id' "$acceptance_run_path")"
  generated_at="$(jq -er '.generated_at' "$aggregate_path")"
  run_sha256="$(qualification_sha256 "$acceptance_run_path")"
  scenario_sha256="$(qualification_sha256 "$scenario_path")"
  [[ "$(jq -er '.scenario_sha256' "$acceptance_run_path")" == "$scenario_sha256" ]] ||
    qualification_fail 'scenario digest does not match acceptance run'
  aggregate_run_id="$(jq -er '.run_id' "$aggregate_path")"
  aggregate_run_sha256="$(jq -er '.acceptance_run_sha256' "$aggregate_path")"
  [[ "$aggregate_run_id" == "$run_id" ]] ||
    qualification_fail 'aggregate run_id does not match acceptance run'
  [[ "$aggregate_run_sha256" == "$run_sha256" ]] ||
    qualification_fail 'aggregate acceptance_run_sha256 does not match acceptance run'

  : >"$work/results.ndjson"
  : >"$work/runtime-domains.ndjson"
  : >"$work/runtime-digests.ndjson"
  : >"$work/evidence-domains.ndjson"
  : >"$work/mcap-digests.ndjson"

  # The caller owns these arrays; this file is a sourced command library.
  # shellcheck disable=SC2154
  for specification in "${runtime_manifest_specs[@]}"; do
    qualification_parse_named_file "$specification"
    [[ "$(jq -er '.schema_version' "$QUALIFICATION_PATH")" == runtime-manifest.v1 ]] ||
      qualification_fail \
        "runtime manifest $QUALIFICATION_LABEL must declare runtime-manifest.v1"
    fastdds_profile_sha256="$(
      jq -r '.data_plane.fastdds_profile_sha256 // empty' "$QUALIFICATION_PATH"
    )"
    if [[ -n "$fastdds_profile_sha256" ]] &&
      ! awk -F '\t' -v digest="$fastdds_profile_sha256" '
        $1 == "other_evidence" && $3 == digest { found = 1 }
        END { exit(found ? 0 : 1) }
      ' "$work/paths.tsv"; then
      qualification_fail \
        "runtime manifest $QUALIFICATION_LABEL references an absent Fast DDS profile: $fastdds_profile_sha256"
    fi
    jq -cn --arg value "$QUALIFICATION_LABEL" '$value' >>"$work/runtime-domains.ndjson"
    jq -cn --arg value "$(qualification_sha256 "$QUALIFICATION_PATH")" '$value' \
      >>"$work/runtime-digests.ndjson"
  done

  # shellcheck disable=SC2154
  for specification in "${result_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    [[ "$(jq -er '.schema_version' "$path")" == acceptance-result.v4 ]] ||
      qualification_fail "result $label must declare acceptance-result.v4"
    result_run_id="$(jq -er '.run_id' "$path")"
    result_domain_id="$(jq -er '.domain_id' "$path")"
    [[ "$result_run_id" == "$run_id" ]] ||
      qualification_fail "result $label has a foreign run_id"
    [[ "$result_domain_id" == "$label" ]] ||
      qualification_fail "result label $label does not match domain_id $result_domain_id"
    result_sha256="$(qualification_sha256 "$path")"
    runtime_sha256="$(jq -er '.runtime_manifest_sha256' "$path")"
    jq -cn \
      --arg domain_id "$result_domain_id" \
      --arg result_id "$(jq -er '.result_id' "$path")" \
      --arg result_sha256 "$result_sha256" \
      --arg status "$(jq -er '.status' "$path")" \
      --arg runtime_sha256 "$runtime_sha256" \
      '{
        domain_id: $domain_id,
        result_id: $result_id,
        result_sha256: $result_sha256,
        status: $status,
        runtime_sha256: $runtime_sha256
      }' >>"$work/results.ndjson"
  done

  # shellcheck disable=SC2154
  for specification in "${evidence_index_specs[@]}"; do
    qualification_parse_named_file "$specification"
    label="$QUALIFICATION_LABEL"
    path="$QUALIFICATION_PATH"
    [[ "$(jq -er '.schema_version' "$path")" == evidence-index.v2 ]] ||
      qualification_fail "evidence index $label must declare evidence-index.v2"
    [[ "$(jq -er '.run_id' "$path")" == "$run_id" ]] ||
      qualification_fail "evidence index $label has a foreign run_id"
    jq -cn --arg value "$label" '$value' >>"$work/evidence-domains.ndjson"
  done

  # shellcheck disable=SC2154
  for specification in "${mcap_summary_specs[@]}"; do
    qualification_parse_named_file "$specification"
    path="$QUALIFICATION_PATH"
    [[ "$(jq -er '.schema_version' "$path")" == mcap-summary.v1 ]] ||
      qualification_fail \
        "MCAP summary $QUALIFICATION_LABEL must declare mcap-summary.v1"
    jq -cn --arg value "$(qualification_sha256 "$path")" '$value' \
      >>"$work/mcap-digests.ndjson"
  done

  run_domains="$(jq -c '[.domains[].domain_id] | sort' "$acceptance_run_path")"
  result_domains="$(jq -sc 'map(.domain_id) | sort' "$work/results.ndjson")"
  runtime_domains="$(jq -sc 'sort' "$work/runtime-domains.ndjson")"
  evidence_domains="$(jq -sc 'sort' "$work/evidence-domains.ndjson")"
  [[ "$result_domains" == "$run_domains" ]] ||
    qualification_fail 'domain result set does not equal acceptance run domains'
  [[ "$runtime_domains" == "$run_domains" ]] ||
    qualification_fail 'runtime manifest set does not equal acceptance run domains'
  [[ "$evidence_domains" == "$run_domains" ]] ||
    qualification_fail 'evidence index set does not equal acceptance run domains'

  local_results="$(
    jq -sc 'map(del(.runtime_sha256)) | sort_by(.domain_id)' "$work/results.ndjson"
  )"
  aggregate_results="$(
    jq -c '[.per_domain_results[]] | sort_by(.domain_id)' "$aggregate_path"
  )"
  [[ "$local_results" == "$aggregate_results" ]] ||
    qualification_fail 'aggregate per_domain_results do not exactly match local results'

  while IFS= read -r runtime_sha256; do
    jq -s -e --arg digest "$runtime_sha256" \
      'index($digest) != null' "$work/runtime-digests.ndjson" >/dev/null ||
      qualification_fail "result references an absent runtime manifest: $runtime_sha256"
  done < <(jq -r '.runtime_sha256' "$work/results.ndjson")

  referenced_mcap="$(
    jq -sc \
      '[.[] | .segments[]? | select(.media_type == "application/mcap") |
        .mcap_summary.sha256] | sort | unique' \
      "${evidence_index_specs[@]#*=}"
  )"
  local_mcap="$(jq -sc 'sort | unique' "$work/mcap-digests.ndjson")"
  [[ "$referenced_mcap" == "$local_mcap" ]] ||
    qualification_fail 'MCAP summaries do not exactly match evidence-index references'

  printf '%s\n' "$run_id" >"$work/run-id"
  printf '%s\n' "$generated_at" >"$work/generated-at"
  printf '%s\n' "$(qualification_sha256 "$aggregate_path")" >"$work/aggregate-sha256"
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
        "schema_version": "qualification-bundle.v1",
        "run_id": $run_id,
        "generated_at": $generated_at,
        "artifacts": $artifacts[0]
      }
    }' >"$temporary"
  qualification_validate_contract "$temporary" qualification-bundle.v1
  chmod 0444 "$temporary"
  mv "$temporary" "$output"
}

qualification_prepare() {
  local work="$1"

  qualification_require_command jq
  qualification_require_command sha256sum
  qualification_require_command yq
  qualification_resolve_contracts_cli
  [[ -n "$scenario_path" ]] || qualification_fail '--scenario is required'
  [[ -n "$acceptance_run_path" ]] || qualification_fail '--acceptance-run is required'
  [[ -n "$aggregate_path" ]] || qualification_fail '--aggregate is required'
  # The caller owns these arrays; this file is a sourced command library.
  # shellcheck disable=SC2154
  ((${#runtime_manifest_specs[@]} > 0)) ||
    qualification_fail 'at least one --runtime-manifest is required'
  ((${#result_specs[@]} > 0)) ||
    qualification_fail 'at least one --result is required'
  ((${#evidence_index_specs[@]} > 0)) ||
    qualification_fail 'at least one --evidence-index is required'
  ((${#mcap_summary_specs[@]} > 0)) ||
    qualification_fail 'at least one --mcap-summary is required'

  # The caller owns this array; this file is a sourced command library.
  # shellcheck disable=SC2154
  for specification in "${optional_evidence_specs[@]}"; do
    qualification_parse_evidence_file "$specification"
    case "$QUALIFICATION_KIND" in
      channel_contract)
        [[ "$(jq -er '.schema_version' "$QUALIFICATION_PATH")" == zenoh-channel.v1 ]] ||
          qualification_fail \
            "channel contract $QUALIFICATION_LABEL must declare zenoh-channel.v1"
        ;;
      channel_observation)
        [[ "$(jq -er '.schema_version' "$QUALIFICATION_PATH")" == \
          zenoh-channel-observation.v1 ]] ||
          qualification_fail \
            "channel observation $QUALIFICATION_LABEL must declare zenoh-channel-observation.v1"
        ;;
      metrics | traces | junit | other_evidence) ;;
    esac
  done

  qualification_collect_subjects "$work"
  qualification_validate_links "$work"
}
