#!/usr/bin/env bash
# Shared fixtures for security-scanning.bats: the fake docker binary, finding
# fixtures and the gate invocation wrapper. Tests call these after setup()
# has created FAKE_BIN, DOCKER_LOG, SECURITY_DIR and TRIVY_CACHE_DIR.

# Fake docker: log the invocation, materialise the scan report from a fixture
# (empty results by default) and always succeed at conversion, mirroring the
# unfiltered SARIF export. SCAN_FIXTURE applies to every platform;
# SCAN_FIXTURE_LINUX_AMD64 / SCAN_FIXTURE_LINUX_ARM64 override per platform.
write_gate_fake_docker() {
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${DOCKER_LOG}"
mode=scan
output=
platform=
previous=
for argument in "$@"; do
  if test "${argument}" = convert; then
    mode=convert
  fi
  if test "${previous}" = --output; then
    output="${argument}"
  fi
  if test "${previous}" = --platform; then
    platform="${argument}"
  fi
  previous="${argument}"
done
if test -n "${output}"; then
  host_output="${output/#\/reports\//${ROBOTICS_CI_SECURITY_ARTIFACT_DIR}/}"
  if test "${mode}" = scan; then
    fixture="${SCAN_FIXTURE:-}"
    case "${platform}" in
      linux/amd64) fixture="${SCAN_FIXTURE_LINUX_AMD64:-${fixture}}" ;;
      linux/arm64) fixture="${SCAN_FIXTURE_LINUX_ARM64:-${fixture}}" ;;
    esac
    if test -n "${fixture}"; then
      cat "${fixture}" >"${host_output}"
    else
      printf '{"Results":[]}\n' >"${host_output}"
    fi
  else
    printf '{"runs":[]}\n' >"${host_output}"
  fi
fi
EOF
  chmod +x "${FAKE_BIN}/docker"
}

# Fake docker for scan-bake-group.sh: answers `buildx bake --print` from
# BAKE_PLAN (BAKE_PLAN_MODE=empty|multi|valid) and serves CONFORMANCE_FIXTURE
# for the conformance image, empty results for everything else.
write_bake_fake_docker() {
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if test "$1 $2 $3 $4 $5" = "buildx bake --file docker-bake.hcl --print"; then
  case "${BAKE_PLAN_MODE:-valid}" in
    empty) printf '{"target":{}}\n' ;;
    multi) jq '.target.runtime.tags += ["registry.example/runtime:latest"]' "${BAKE_PLAN}" ;;
    valid) cat "${BAKE_PLAN}" ;;
  esac
  exit 0
fi
printf '%s\n' "$*" >>"${DOCKER_LOG}"
mode=scan
output=
previous=
for argument in "$@"; do
  if test "${argument}" = convert; then
    mode=convert
  fi
  if test "${previous}" = --output; then
    output="${argument}"
  fi
  previous="${argument}"
done
if test -n "${output}"; then
  host_output="${output/#\/reports\//${ROBOTICS_CI_SECURITY_ARTIFACT_DIR}/}"
  if test "${mode}" = scan; then
    if test -n "${CONFORMANCE_FIXTURE:-}" && test "${@: -1}" = registry.example/conformance:test; then
      cat "${CONFORMANCE_FIXTURE}" >"${host_output}"
    else
      printf '{"Results":[]}\n' >"${host_output}"
    fi
  else
    printf '{"runs":[]}\n' >"${host_output}"
  fi
fi
EOF
  chmod +x "${FAKE_BIN}/docker"
}

# One-finding report. Pass status "missing" to omit the Status field.
write_finding_fixture() {
  local class="$1" type="$2" finding_status="$3" severity="$4"
  jq -n \
    --arg class "${class}" --arg type "${type}" \
    --arg status "${finding_status}" --arg severity "${severity}" '
    {
      Results: [
        {
          Target: "fixture-image",
          Class: $class,
          Type: $type,
          Vulnerabilities: [
            ({
              VulnerabilityID: "CVE-2026-0001",
              PkgName: "fixture-package",
              Severity: $severity
            }
            + (if $status == "missing" then {} else {Status: $status} end))
          ]
        }
      ]
    }
  ' >"${BATS_TEST_TMPDIR}/fixture.json"
}

# One-finding report for the header-only package linux-libc-dev. Pass status
# "missing" to omit the Status field; class/type default to os-pkgs/ubuntu.
write_header_finding() {
  local finding_status="$1" severity="$2" class="${3:-os-pkgs}" type="${4:-ubuntu}"
  jq -n \
    --arg class "${class}" --arg type "${type}" \
    --arg status "${finding_status}" --arg severity "${severity}" '
    {
      Results: [
        {
          Target: "fixture-image",
          Class: $class,
          Type: $type,
          Vulnerabilities: [
            ({
              VulnerabilityID: "CVE-2026-0001",
              PkgName: "linux-libc-dev",
              Severity: $severity
            }
            + (if $status == "missing" then {} else {Status: $status} end))
          ]
        }
      ]
    }
  ' >"${BATS_TEST_TMPDIR}/fixture.json"
}

# Write the repo-relative gate ignore policy; teardown() removes it.
write_gate_ignore() {
  printf '%s\n' "$@" >"${REPO_ROOT}/.trivyignore.gate-test"
}

# One well-formed exception line for CVE-2026-0001 on the finding fixture.
write_gate_exception() {
  local review="$1" exp="$2" pkg="${3:-fixture-package}" target="${4:-fixture-image}"
  write_gate_ignore \
    "CVE-2026-0001 #reason: distro backlog;pkg:${pkg};target:${target};review:${review};exp:${exp}"
}

# UTC date offset in days, e.g. gate_date_offset +30.
gate_date_offset() {
  date -u -d "${1} days" +%F
}

# Run the gate against the fake docker. Optional first argument is the
# repo-relative ignore file; remaining arguments are platforms.
run_image_scan() {
  local ignore_file="${1:-}"
  if test "$#" -gt 0; then
    shift
  fi
  local environment=(
    "PATH=${FAKE_BIN}:${PATH}"
    "DOCKER_LOG=${DOCKER_LOG}"
    "HOME=${BATS_TEST_TMPDIR}"
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}"
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}"
    "SCAN_FIXTURE=${SCAN_FIXTURE:-${BATS_TEST_TMPDIR}/fixture.json}"
    "GITHUB_STEP_SUMMARY=${GITHUB_STEP_SUMMARY:-}"
    TRIVY_IMAGE=trivy:test
  )
  if test -n "${ignore_file}"; then
    environment+=("ROBOTICS_CI_TRIVY_IGNORE_FILE=${ignore_file}")
  fi
  if test -n "${SCAN_FIXTURE_LINUX_AMD64:-}"; then
    environment+=("SCAN_FIXTURE_LINUX_AMD64=${SCAN_FIXTURE_LINUX_AMD64}")
  fi
  if test -n "${SCAN_FIXTURE_LINUX_ARM64:-}"; then
    environment+=("SCAN_FIXTURE_LINUX_ARM64=${SCAN_FIXTURE_LINUX_ARM64}")
  fi
  run env "${environment[@]}" \
    scripts/ci/security/scan-image.sh \
    "${GATE_TEST_IMAGE:-registry.example/runtime:test}" candidate "$@"
}
