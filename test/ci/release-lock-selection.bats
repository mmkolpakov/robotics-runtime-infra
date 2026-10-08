#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  consumer="${BATS_TEST_TMPDIR}/consumer"
  trace="${BATS_TEST_TMPDIR}/calls"
  github_env="${BATS_TEST_TMPDIR}/github-env"
  probe="${BATS_TEST_TMPDIR}/resolve-inputs.sh"
  mkdir "${consumer}"
  ln -s "${REPOSITORY_ROOT}" "${BATS_TEST_TMPDIR}/tooling"
  printf 'scenario-fixture\n' >"${consumer}/scenario.yaml"
  : >"${trace}"
  : >"${github_env}"
  printf 'set -Eeuo pipefail\n' >"${probe}"
  # Execute the actual same-revision workflow code, including path validation.
  awk '
    /- name: Resolve caller inputs/ { step = 1; next }
    step && /^        run: \|$/ { body = 1; next }
    body && /^      - / { exit }
    body { print substr($0, 11) }
  ' "${REPOSITORY_ROOT}/.github/workflows/reusable-qualify.yml" >>"${probe}"
  grep -q 'gh release download' "${probe}"
  export TOOLING_REF=1111111111111111111111111111111111111111
  export EXECUTION_MODE=released RELEASE_TAG=v0.11.0-rc.1 RELEASE_LOCK=""
  export ARTIFACT_ARGUMENTS_FILE="" COMPOSE_PROJECT="" SCENARIO=scenario.yaml
  export GITHUB_ENV="${github_env}"
}

# Simulate an immutable older tooling checkout with no new download helper.
git() { printf '%s\n' "${TOOLING_REF}"; }
gh() {
  printf '%s\n' "$*" >>"${trace}"
  [[ "$1 $2" == 'release download' && "$3" == v0.11.0-rc.1 &&
     "$4 $5" == '--repo mmkolpakov/robotics-runtime-infra' &&
     "$6 $7" == '--pattern release.env' && "$8" == --dir ]] || return 99
  [[ -z "${DOWNLOAD_STATUS:-}" ]] || return "${DOWNLOAD_STATUS}"
  printf 'canonical-lock-bytes\n' >"$9/release.env"
}
resolve_inputs() {
  cd "${BATS_TEST_TMPDIR}" || return
  # The probe is extracted from the workflow at runtime.
  # shellcheck source=/dev/null
  source "${probe}"
}
selected_lock() { sed -n 's/^ROBOTICS_FOUNDATION_RELEASE_LOCK=//p' "${github_env}"; }

@test "selected release downloads canonical bytes inside a new caller directory" {
  run resolve_inputs
  [ "${status}" -eq 0 ]
  first="$(selected_lock)"
  [[ "${first}" == "${consumer}/.release-lock."*/release.env ]]
  [ "$(cat "${first}")" = canonical-lock-bytes ]
  : >"${github_env}"
  run resolve_inputs
  [ "${status}" -eq 0 ]
  [ "$(selected_lock)" != "${first}" ]
  [ "$(wc -l <"${trace}")" -eq 2 ]
}

@test "explicit caller lock is resolved without downloading or overwriting" {
  printf 'caller-lock\n' >"${consumer}/release.env"
  RELEASE_LOCK=release.env run resolve_inputs
  [ "${status}" -eq 0 ]
  [ "$(selected_lock)" = "${consumer}/release.env" ]
  [ "$(cat "${consumer}/release.env")" = caller-lock ]
  [ ! -s "${trace}" ]
}

@test "invalid release tag fails before download" {
  for tag in latest main '' 'v0.11.0;echo-invalid'; do
    RELEASE_TAG="${tag}" run resolve_inputs
    [ "${status}" -eq 64 ]
    [ ! -s "${trace}" ]
  done
  [ "$(find "${consumer}" -mindepth 1 -name '.release-lock.*' | wc -l)" -eq 0 ]
}

@test "download failure returns its status and removes the temporary directory" {
  DOWNLOAD_STATUS=73 run resolve_inputs
  [ "${status}" -eq 73 ]
  [ "$(find "${consumer}" -mindepth 1 -name '.release-lock.*' | wc -l)" -eq 0 ]
  [ ! -s "${github_env}" ]
}

@test "explicit caller lock cannot escape through a symlink" {
  printf 'outside-lock\n' >"${BATS_TEST_TMPDIR}/outside.env"
  ln -s "${BATS_TEST_TMPDIR}/outside.env" "${consumer}/release.env"
  RELEASE_LOCK=release.env run resolve_inputs
  [ "${status}" -ne 0 ]
  [ ! -s "${trace}" ]
}
