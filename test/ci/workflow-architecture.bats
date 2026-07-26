#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}"
}

@test "CI workflow remains declarative and compact" {
  line_count="$(wc -l <.github/workflows/ci.yml)"
  [ "${line_count}" -le 460 ]

  run grep -nE '^[[:space:]]+run:[[:space:]]*[|>]' .github/workflows/ci.yml
  [ "${status}" -eq 1 ]

  run grep -nE \
    '^[[:space:]]+run:.*(<<|(^|[;&])[[:space:]]*(for|while|if|case)[[:space:]])' \
    .github/workflows/ci.yml
  [ "${status}" -eq 1 ]
}

@test "every workflow phase exists and is executable" {
  phase_lines="$(
    sed -nE \
      's#^[[:space:]]+run:[[:space:]]+(scripts/ci/[^[:space:]]+\.sh)$#\1#p' \
      .github/workflows/ci.yml
  )"
  mapfile -t phases <<<"${phase_lines}"
  [ "${#phases[@]}" -gt 0 ]

  local phase
  for phase in "${phases[@]}"; do
    [ -f "${phase}" ]
    [ -x "${phase}" ]
  done
}

@test "every job that invokes a repository script checks out the repository" {
  run awk '
    function finish_job() {
      if (job != "" && invokes_script && !has_checkout) {
        print job
        failed = 1
      }
    }

    /^jobs:$/ {
      in_jobs = 1
      next
    }
    in_jobs && /^  [A-Za-z0-9_-]+:$/ {
      finish_job()
      job = $1
      sub(/:$/, "", job)
      invokes_script = 0
      has_checkout = 0
      next
    }
    in_jobs && /uses: actions\/checkout@/ {
      has_checkout = 1
    }
    in_jobs && /run: scripts\/ci\// {
      invokes_script = 1
    }
    END {
      finish_job()
      exit failed
    }
  ' .github/workflows/ci.yml
  [ "${status}" -eq 0 ]
}

@test "workflow architecture tests are an explicit CI phase" {
  run grep -F \
    'uses: bats-core/bats-action@77d6fb60505b4d0d1d73e48bd035b55074bbfb43' \
    .github/workflows/ci.yml
  [ "${status}" -eq 0 ]

  run grep -F \
    'run: scripts/ci/static-analysis/test-workflow-architecture.sh' \
    .github/workflows/ci.yml
  [ "${status}" -eq 0 ]
}

@test "every external action is pinned to a full commit SHA" {
  failures=()
  while IFS= read -r workflow; do
    line_number=0
    while IFS= read -r line; do
      ((line_number += 1))
      if [[ "${line}" =~ uses:[[:space:]]+([^[:space:]#]+) ]]; then
        action="${BASH_REMATCH[1]}"
        [[ "${action}" == ./* ]] && continue
        if [[ ! "${action}" =~ ^[^@]+@[0-9a-f]{40}$ ]]; then
          failures+=("${workflow}:${line_number}:${action}")
        fi
      fi
    done <"${workflow}"
  done < <(
    find .github/workflows -type f \
      \( -name '*.yml' -o -name '*.yaml' \) -print |
      LC_ALL=C sort
  )

  if [ "${#failures[@]}" -ne 0 ]; then
    printf '%s\n' "${failures[@]}"
  fi
  [ "${#failures[@]}" -eq 0 ]
}

@test "every repository script referenced by a workflow exists and is executable" {
  mapfile -t scripts < <(
    grep -rhoE 'scripts/ci/[A-Za-z0-9._/-]+\.sh' .github/workflows |
      LC_ALL=C sort -u
  )
  [ "${#scripts[@]}" -gt 0 ]

  for script in "${scripts[@]}"; do
    [ -f "${script}" ]
    [ -x "${script}" ]
  done
}

@test "all CI shell files parse" {
  while IFS= read -r -d '' script; do
    run bash -n "${script}"
    [ "${status}" -eq 0 ]
  done < <(find scripts/ci -type f -name '*.sh' -print0)
}

@test "all CI entrypoints are executable in the Git checkout" {
  while IFS= read -r -d '' script; do
    [ -x "${script}" ]
  done < <(
    find scripts/ci -type f -print0
  )
}

@test "Bake manifest is non-empty, unique, and names the CPU sensor target" {
  run jq -e '
    .bake_targets | type == "array" and length > 0 and
    all(.[]; type == "string" and length > 0) and
    length == (unique | length) and
    index("sensor-inference-cpu") != null
  ' config/ci/pipeline.json
  [ "${status}" -eq 0 ]

  run awk '/^group "cpu"/,/^}/ {print}' docker-bake.hcl
  [ "${status}" -eq 0 ]
  [[ "${output}" == *'"sensor-inference-cpu"'* ]]
}

@test "Bake validator rejects absent and malformed target lists" {
  printf '{}\n' >"${BATS_TEST_TMPDIR}/absent.json"
  run scripts/ci/static-analysis/validate-docker-bake-definition.sh \
    "${BATS_TEST_TMPDIR}/absent.json"
  [ "${status}" -ne 0 ]

  printf '{"bake_targets":[]}\n' >"${BATS_TEST_TMPDIR}/empty.json"
  run scripts/ci/static-analysis/validate-docker-bake-definition.sh \
    "${BATS_TEST_TMPDIR}/empty.json"
  [ "${status}" -ne 0 ]

  printf '{"bake_targets":[1]}\n' >"${BATS_TEST_TMPDIR}/malformed.json"
  run scripts/ci/static-analysis/validate-docker-bake-definition.sh \
    "${BATS_TEST_TMPDIR}/malformed.json"
  [ "${status}" -ne 0 ]
}

@test "Bake validator rejects incomplete rendered target coverage" {
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'if [[ "$*" == *"--list=type=targets,format=json"* ]]; then' \
    '  printf "%s\n" '"'"'[{"name":"default","group":true},{"name":"cpu","group":true},{"name":"simulation"},{"name":"missing-target"}]'"'" \
    'elif [[ "$*" == *"--print"* ]]; then' \
    '  printf "%s\n" '"'"'{"group":{"default":{},"cpu":{}},"target":{"simulation":{}}}'"'" \
    'else' \
    '  exit 64' \
    'fi' \
    >"${fake_bin}/docker"
  chmod +x "${fake_bin}/docker"

  run env "PATH=${fake_bin}:${PATH}" \
    scripts/ci/static-analysis/validate-docker-bake-definition.sh
  [ "${status}" -ne 0 ]

  printf '{"bake_targets":["default"]}\n' \
    >"${BATS_TEST_TMPDIR}/missing-group.json"
  run env "PATH=${fake_bin}:${PATH}" \
    scripts/ci/static-analysis/validate-docker-bake-definition.sh \
    "${BATS_TEST_TMPDIR}/missing-group.json"
  [ "${status}" -ne 0 ]
}

@test "both Compose jobs use the shared model validator" {
  invocation_count="$(
    grep -Fc 'run: scripts/ci/validate-compose-models.sh' \
      .github/workflows/ci.yml
  )"
  [ "${invocation_count}" -eq 2 ]
}

@test "Compose manifest covers every repository Compose file" {
  run jq -e '
    .compose_models | type == "array" and length > 0 and
    ([.[].name] | length == (unique | length)) and
    all(.[];
      (.files | type == "array" and length > 0) and
      .files[0] == "compose.yaml"
    )
  ' config/ci/pipeline.json
  [ "${status}" -eq 0 ]

  run bash -c '
    diff -u \
      <(find . -maxdepth 1 -type f -name "compose*.yaml" -printf "%f\n" | sort) \
      <(jq -r ".compose_models[].files[]" config/ci/pipeline.json | sort -u)
  '
  [ "${status}" -eq 0 ]
}

@test "runtime image enumeration fails closed and scans the complete set" {
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  call_log="${BATS_TEST_TMPDIR}/docker-calls.log"
  mkdir -p "${fake_bin}"
  printf '%s\n' \
    '#!/usr/bin/env bash' \
    'printf "%s\n" "$*" >>"${DOCKER_CALL_LOG}"' \
    >"${fake_bin}/docker"
  chmod +x "${fake_bin}/docker"

  common_env=(
    "PATH=${fake_bin}:${PATH}"
    "DOCKER_CALL_LOG=${call_log}"
    "TRIVY_IMAGE=trivy:test"
    "SIMULATION_IMAGE=simulation:test"
    "SENSOR_IMAGE=sensor:test"
    "INFERENCE_CPU_IMAGE=inference:test"
    "OBSERVER_IMAGE=observer:test"
    "BENCHMARK_IMAGE=benchmark:test"
    "EVIDENCE_IMAGE=evidence:test"
    "PERMIT_PREFLIGHT_IMAGE=permit:test"
    "HOST_IO_FIXTURE_IMAGE=host-io:test"
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${BATS_TEST_TMPDIR}/security"
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${BATS_TEST_TMPDIR}/trivy-cache"
  )

  run env -u EDGE_IMAGE "${common_env[@]}" \
    scripts/ci/integration/scan-images-and-enforce-vulnerability-policy.sh
  [ "${status}" -ne 0 ]
  [ ! -e "${call_log}" ]

  run env "${common_env[@]}" "EDGE_IMAGE=edge:test" \
    scripts/ci/integration/scan-images-and-enforce-vulnerability-policy.sh
  [ "${status}" -eq 0 ]
  [ "$(wc -l <"${call_log}")" -eq 18 ]

  for image in \
    simulation:test edge:test sensor:test inference:test observer:test \
    benchmark:test evidence:test permit:test host-io:test; do
    run grep -F "${image}" "${call_log}"
    [ "${status}" -eq 0 ]
  done
}

@test "CI orchestration contains no Python files" {
  run find scripts/ci -type f \( -name '*.py' -o -name '*.pyc' \) -print
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]
}
