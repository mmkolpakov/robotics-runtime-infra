#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
  FAKE_BIN="${BATS_TEST_TMPDIR}/bin"
  DOCKER_LOG="${BATS_TEST_TMPDIR}/docker.log"
  SECURITY_DIR="${BATS_TEST_TMPDIR}/security"
  TRIVY_CACHE_DIR="${BATS_TEST_TMPDIR}/trivy-cache"
  mkdir -p "${FAKE_BIN}" "${SECURITY_DIR}" "${TRIVY_CACHE_DIR}"
}

# Fake docker: log the invocation, materialise the scan report from
# SCAN_FIXTURE (empty results by default) and always succeed at conversion,
# mirroring the unfiltered SARIF export.
write_gate_fake_docker() {
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
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
    if test -n "${SCAN_FIXTURE:-}"; then
      cat "${SCAN_FIXTURE}" >"${host_output}"
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

write_finding_fixture() {
  jq -n \
    --arg class "$1" --arg type "$2" --arg status "$3" --arg severity "$4" '
    {
      Results: [
        {
          Target: "fixture-image",
          Class: $class,
          Type: $type,
          Vulnerabilities: [
            {
              VulnerabilityID: "CVE-2026-0001",
              PkgName: "fixture-package",
              Severity: $severity,
              Status: $status
            }
          ]
        }
      ]
    }
  ' >"${BATS_TEST_TMPDIR}/fixture.json"
}

run_image_scan() {
  local environment=(
    "PATH=${FAKE_BIN}:${PATH}"
    "DOCKER_LOG=${DOCKER_LOG}"
    "HOME=${BATS_TEST_TMPDIR}"
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}"
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}"
    "SCAN_FIXTURE=${BATS_TEST_TMPDIR}/fixture.json"
    TRIVY_IMAGE=trivy:test
  )
  if test "$#" -gt 0; then
    environment+=("ROBOTICS_CI_TRIVY_IGNORE_FILE=$1")
  fi
  run env "${environment[@]}" \
    scripts/ci/security/scan-image.sh registry.example/runtime:test candidate
}

@test "image scanner accepts a quoted platform CSV without word splitting" {
  write_gate_fake_docker

  run env \
    "PATH=${FAKE_BIN}:${PATH}" \
    "DOCKER_LOG=${DOCKER_LOG}" \
    "HOME=${BATS_TEST_TMPDIR}" \
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}" \
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" \
    TRIVY_IMAGE=trivy:test \
    scripts/ci/security/scan-image.sh \
      registry.example/runtime:test \
      candidate \
      linux/amd64,linux/arm64

  [ "${status}" -eq 0 ]
  [ "$(wc -l <"${DOCKER_LOG}")" -eq 4 ]
  [ "$(grep -Fc -- '--vex /work/security/vex/linux-libc-dev.openvex.json' "${DOCKER_LOG}")" -eq 2 ]
  [ "$(grep -Fc -- '--vex /work/security/vex/go-modules.openvex.json' "${DOCKER_LOG}")" -eq 2 ]
  [ "$(grep -Fc -- '--show-suppressed' "${DOCKER_LOG}")" -eq 2 ]
  run grep -F -- '--platform linux/amd64' "${DOCKER_LOG}"
  [ "${status}" -eq 0 ]
  run grep -F -- '--platform linux/arm64' "${DOCKER_LOG}"
  [ "${status}" -eq 0 ]
}

@test "Bake group scanner derives and scans every tagged image" {
  cat >"${BATS_TEST_TMPDIR}/bake-plan.json" <<'EOF'
{
  "target": {
    "runtime": {
      "tags": ["registry.example/runtime:test"]
    },
    "conformance": {
      "tags": ["registry.example/conformance:test"]
    },
    "internal": {}
  }
}
EOF
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
    printf '{"Results":[]}\n' >"${host_output}"
  else
    printf '{"runs":[]}\n' >"${host_output}"
  fi
fi
EOF
  chmod +x "${FAKE_BIN}/docker"

  environment=(
    "PATH=${FAKE_BIN}:${PATH}"
    "BAKE_PLAN=${BATS_TEST_TMPDIR}/bake-plan.json"
    "DOCKER_LOG=${DOCKER_LOG}"
    "HOME=${BATS_TEST_TMPDIR}"
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}"
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}"
    TRIVY_IMAGE=trivy:test
  )

  run env "${environment[@]}" BAKE_PLAN_MODE=empty \
    scripts/ci/security/scan-bake-group.sh accelerator
  [ "${status}" -ne 0 ]
  [ ! -e "${DOCKER_LOG}" ]

  run env "${environment[@]}" BAKE_PLAN_MODE=multi \
    scripts/ci/security/scan-bake-group.sh accelerator
  [ "${status}" -ne 0 ]
  [ ! -e "${DOCKER_LOG}" ]

  run env "${environment[@]}" \
    scripts/ci/security/scan-bake-group.sh accelerator

  [ "${status}" -eq 0 ]
  [ "$(wc -l <"${DOCKER_LOG}")" -eq 4 ]
  run grep -F 'registry.example/runtime:test' "${DOCKER_LOG}"
  [ "${status}" -eq 0 ]
  run grep -F 'registry.example/conformance:test' "${DOCKER_LOG}"
  [ "${status}" -eq 0 ]
}

@test "reviewed OpenVEX policy is scoped to the kernel header package" {
  local scope_filter='
    def reviewed_headers:
      [
        {"@id": "pkg:deb/ubuntu/linux-libc-dev@6.8.0-142.142?arch=amd64&distro=ubuntu-24.04"},
        {"@id": "pkg:deb/ubuntu/linux-libc-dev@6.8.0-142.142?arch=arm64&distro=ubuntu-24.04"}
      ];
    def scoped_cves:
      ["CVE-2024-46742", "CVE-2024-46833", "CVE-2024-52560", "CVE-2024-56591"];
    def newly_reviewed_cves:
      ["CVE-2022-50240", "CVE-2024-58098", "CVE-2024-58100", "CVE-2025-37743", "CVE-2025-37776", "CVE-2025-38204", "CVE-2025-39933", "CVE-2025-40074", "CVE-2025-40139", "CVE-2025-40168", "CVE-2025-40170", "CVE-2025-40274"];
    .["@context"] == "https://openvex.dev/ns/v0.2.0"
    and .author == "mmkolpakov"
    and .version == 15
    and (.statements | length == 206)
    and ([.statements[] | select(.products == reviewed_headers)] | length == 151)
    and (
      [.statements[].vulnerability.name]
      | length == (unique | length)
    )
    and (
      [.statements[].vulnerability.name
        | select(. as $name | scoped_cves | index($name) != null)]
      | sort == scoped_cves
    )
    and (
      [.statements[].vulnerability.name
        | select(. as $name | newly_reviewed_cves | index($name) != null)]
      | sort == newly_reviewed_cves
    )
    and all(
      .statements[];
      (.vulnerability.name | test("^CVE-[0-9]{4}-[0-9]+$"))
      and (
        if (.vulnerability.name as $name | newly_reviewed_cves | index($name)) != null then
          .products == reviewed_headers
          and (.impact_statement | contains("binary-exclude:linux-libc-dev"))
          and (.vulnerability.name as $name | .impact_statement
            | contains("https://ubuntu.com/security/cves/" + $name + ".json (SHA256 "))
          and (.impact_statement | contains("937db1a88a4fa2ea97fd4eab89f2cd9d077290f6a26bcd27b1a6d24fa3d706b6"))
          and (.impact_statement | contains("d66451a894349eed008637ee6f0b8a10dfe426fe424613396e7decc75fa711a0"))
          and (.impact_statement | contains("does not qualify the host kernel, hardware"))
          and (.impact_statement | contains("another package/version/architecture/distribution or another vulnerability"))
        elif (.vulnerability.name as $name | scoped_cves | index($name)) != null then
          .products == reviewed_headers
          and (.impact_statement | contains("Sources: https://"))
          and (
            .impact_statement
            | contains("does not qualify")
              and contains("host kernel")
              and contains("hardware")
              and contains("other binary packages from the linux source")
              and contains("another package version/architecture")
              and contains("any other vulnerability")
          )
        elif .vulnerability.name == "CVE-2025-22043" then
          .products == reviewed_headers
          and (.impact_statement | contains("binary-exclude:linux-libc-dev"))
          and (.impact_statement | contains("https://ubuntu.com/security/cves/CVE-2025-22043.json"))
          and (.impact_statement | contains("does not qualify the host kernel"))
          and (.impact_statement | contains("another version/architecture/distribution"))
          and (.impact_statement | contains("no exception for OPA, yq or x/net"))
        else
          .products == [{"@id": "pkg:deb/ubuntu/linux-libc-dev"}]
          or (
            .products == reviewed_headers
            and (.impact_statement | contains("Sources: https://"))
            and (.impact_statement | contains("does not qualify the host kernel or hardware"))
          )
        end
      )
      and .status == "not_affected"
      and .justification == "vulnerable_code_not_present"
    )
  '

  run jq -e "$scope_filter" security/vex/linux-libc-dev.openvex.json
  [ "$status" -eq 0 ]

  local cve product mutated="$BATS_TEST_TMPDIR/out-of-scope-vex.json"
  for cve in CVE-2022-50240 CVE-2024-58098 CVE-2024-58100 CVE-2025-37743 CVE-2025-37776 CVE-2025-38204 CVE-2025-39933 CVE-2025-40074 CVE-2025-40139 CVE-2025-40168 CVE-2025-40170 CVE-2025-40274; do
    for product in \
      'pkg:deb/ubuntu/linux-libc-dev@6.8.0-142.143?arch=amd64&distro=ubuntu-24.04' \
      'pkg:deb/ubuntu/linux-libc-dev@6.8.0-142.142?arch=ppc64el&distro=ubuntu-24.04' \
      'pkg:deb/ubuntu/linux-image-6.8.0-142-generic@6.8.0-142.142?arch=amd64&distro=ubuntu-24.04' \
      'pkg:deb/ubuntu/linux-libc-dev@6.8.0-142.142?arch=amd64&distro=ubuntu-22.04' \
      'pkg:golang/github.com/open-policy-agent/opa@v1.21.2%2Bdirty' \
      'pkg:golang/github.com/mikefarah/yq/v4@v4.54.1' \
      'pkg:golang/golang.org/x/net@v0.60.0'; do
      jq --arg cve "$cve" --arg product "$product" '
        (.statements[] | select(.vulnerability.name == $cve).products[0]["@id"]) = $product
      ' security/vex/linux-libc-dev.openvex.json >"$mutated"
      run jq -e "$scope_filter" "$mutated"
      [ "$status" -ne 0 ] || { printf 'policy accepted %s for %s\n' "$product" "$cve" >&2; return 1; }
    done
  done

  run awk '!/^[[:space:]]*(#|$)/ { print }' .trivyignore
  [ "${status}" -eq 0 ]
  [ -z "${output}" ]

  run grep -F -- '--vex /work/security/vex/linux-libc-dev.openvex.json' \
    .github/workflows/rk3588-qualification.yml
  [ "${status}" -eq 0 ]
}

@test "Bake group scanner scans every image before failing the gate" {
  cat >"${BATS_TEST_TMPDIR}/bake-plan.json" <<'EOF'
{
  "target": {
    "runtime": {
      "tags": ["registry.example/runtime:test"]
    },
    "conformance": {
      "tags": ["registry.example/conformance:test"]
    }
  }
}
EOF
  jq -n '
    {
      Results: [
        {
          Target: "fixture-image",
          Class: "os",
          Type: "ubuntu",
          Vulnerabilities: [
            {
              VulnerabilityID: "CVE-2026-0001",
              PkgName: "fixture-package",
              Severity: "HIGH",
              Status: "fixed"
            }
          ]
        }
      ]
    }
  ' >"${BATS_TEST_TMPDIR}/conformance-fixture.json"
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if test "$1 $2 $3 $4 $5" = "buildx bake --file docker-bake.hcl --print"; then
  cat "${BAKE_PLAN}"
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
    if test "${@: -1}" = registry.example/conformance:test; then
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

  run env \
    "PATH=${FAKE_BIN}:${PATH}" \
    "BAKE_PLAN=${BATS_TEST_TMPDIR}/bake-plan.json" \
    "CONFORMANCE_FIXTURE=${BATS_TEST_TMPDIR}/conformance-fixture.json" \
    "DOCKER_LOG=${DOCKER_LOG}" \
    "HOME=${BATS_TEST_TMPDIR}" \
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}" \
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" \
    TRIVY_IMAGE=trivy:test \
    scripts/ci/security/scan-bake-group.sh accelerator

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"vulnerability gate failed for registry.example/conformance:test"* ]]
  [[ "${output}" != *"vulnerability gate failed for registry.example/runtime:test"* ]]
  [ "$(grep -Fc -- 'registry.example/runtime:test' "${DOCKER_LOG}")" -eq 1 ]
  [ "$(grep -Fc -- 'registry.example/conformance:test' "${DOCKER_LOG}")" -eq 1 ]
  [ "$(grep -Fc -- '--format table' "${DOCKER_LOG}")" -eq 1 ]
  [ -s "${SECURITY_DIR}/accelerator-runtime-local.sarif" ]
  [ -s "${SECURITY_DIR}/accelerator-conformance-local.sarif" ]
}

@test "Go module OpenVEX statements are scoped to pinned binaries" {
  run jq -e '
    .["@context"] == "https://openvex.dev/ns/v0.2.0"
    and .author == "mmkolpakov"
    and (.statements | length == 3)
    and all(
      .statements[];
      (.vulnerability.name | test("^CVE-[0-9]{4}-[0-9]+$"))
      and (.products | length == 1)
      and (.products[0]["@id"] | test("^pkg:golang/[^@]+@v[0-9][^@]*$"))
      and (.products[0].subcomponents | length == 1)
      and (.products[0].subcomponents[0]["@id"] | test("^pkg:golang/[^@]+@v[0-9][^@]*$"))
      and .status == "not_affected"
      and (.justification == "vulnerable_code_not_present"
        or .justification == "vulnerable_code_not_in_execute_path")
      and (.impact_statement | contains("Sources: https://"))
      and (.impact_statement | contains("sha256:"))
    )
  ' security/vex/go-modules.openvex.json
  [ "${status}" -eq 0 ]
}

@test "image scanner propagates the vulnerability gate failure" {
  write_gate_fake_docker
  write_finding_fixture os ubuntu fixed HIGH

  run env \
    "PATH=${FAKE_BIN}:${PATH}" \
    "DOCKER_LOG=${DOCKER_LOG}" \
    "HOME=${BATS_TEST_TMPDIR}" \
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}" \
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" \
    "SCAN_FIXTURE=${BATS_TEST_TMPDIR}/fixture.json" \
    TRIVY_IMAGE=trivy:test \
    scripts/ci/security/scan-image.sh \
      registry.example/runtime:test candidate linux/amd64,linux/arm64

  [ "${status}" -eq 1 ]
  [ "$(wc -l <"${DOCKER_LOG}")" -eq 6 ]
  [ "$(grep -Fc -- '--format table' "${DOCKER_LOG}")" -eq 2 ]
  [[ "${output}" == *"vulnerability gate failed: registry.example/runtime:test linux-amd64"* ]]
  [[ "${output}" == *"vulnerability gate failed: registry.example/runtime:test linux-arm64"* ]]
  [ -s "${SECURITY_DIR}/candidate-linux-amd64.sarif" ]
  [ -s "${SECURITY_DIR}/candidate-linux-arm64.sarif" ]
}

@test "image gate blocks fixable HIGH and CRITICAL findings only at those severities" {
  write_gate_fake_docker

  write_finding_fixture os ubuntu fixed HIGH
  run_image_scan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"blocking: CVE-2026-0001 HIGH fixed fixture-package (fixture-image)"* ]]

  write_finding_fixture os ubuntu fixed CRITICAL
  run_image_scan
  [ "${status}" -eq 1 ]

  write_finding_fixture os ubuntu fixed MEDIUM
  run_image_scan
  [ "${status}" -eq 0 ]

  write_finding_fixture os ubuntu fixed LOW
  run_image_scan
  [ "${status}" -eq 0 ]
}

@test "image gate tolerates will_not_fix and fix_deferred for Ubuntu OS packages" {
  write_gate_fake_docker

  write_finding_fixture os ubuntu will_not_fix HIGH
  run_image_scan
  [ "${status}" -eq 0 ]

  write_finding_fixture os ubuntu fix_deferred CRITICAL
  run_image_scan
  [ "${status}" -eq 0 ]
}

@test "image gate blocks end_of_life findings even for Ubuntu OS packages" {
  write_gate_fake_docker

  write_finding_fixture os ubuntu end_of_life HIGH
  run_image_scan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"blocking: CVE-2026-0001 HIGH end_of_life"* ]]

  write_finding_fixture lang-pkgs gobinary end_of_life CRITICAL
  run_image_scan
  [ "${status}" -eq 1 ]
}

@test "image gate blocks language and Alpine findings regardless of status" {
  write_gate_fake_docker

  local type status
  for type in gobinary python-pkg; do
    for status in fixed affected will_not_fix fix_deferred; do
      write_finding_fixture lang-pkgs "${type}" "${status}" HIGH
      run_image_scan
      [ "${status}" -eq 1 ] || {
        printf 'gate accepted %s %s\n' "${type}" "${status}" >&2
        return 1
      }
    done
  done

  write_finding_fixture os alpine will_not_fix HIGH
  run_image_scan
  [ "${status}" -eq 1 ]

  write_finding_fixture os alpine affected CRITICAL
  run_image_scan
  [ "${status}" -eq 1 ]
}

@test "image gate allows affected Ubuntu findings only with a ticketed unexpired exception" {
  write_gate_fake_docker
  write_finding_fixture os ubuntu affected HIGH
  local ignore="${BATS_TEST_TMPDIR}/trivyignore"

  run_image_scan
  [ "${status}" -eq 1 ]

  printf '%s\n' 'CVE-2026-0001 # reason: distro backlog; review: issue-42; exp:2999-01-01' >"${ignore}"
  run_image_scan "${ignore}"
  [ "${status}" -eq 0 ]

  printf '%s\n' 'CVE-2026-0001 # reason: distro backlog; review: issue-42; exp:2000-01-01' >"${ignore}"
  run_image_scan "${ignore}"
  [ "${status}" -eq 1 ]

  printf '%s\n' 'CVE-2026-0001 # reason: distro backlog; exp:2999-01-01' >"${ignore}"
  run_image_scan "${ignore}"
  [ "${status}" -eq 1 ]

  printf '%s\n' 'CVE-2026-0001 # reason: distro backlog; review: issue-42' >"${ignore}"
  run_image_scan "${ignore}"
  [ "${status}" -eq 1 ]

  printf '%s\n' '# nothing accepted' >"${ignore}"
  run_image_scan "${ignore}"
  [ "${status}" -eq 1 ]

  printf '%s\n' 'CVE-2026-0001 # reason: distro backlog; review: issue-42; exp:2999-01-01' >"${ignore}"
  write_finding_fixture lang-pkgs gobinary affected HIGH
  run_image_scan "${ignore}"
  [ "${status}" -eq 1 ]

  write_finding_fixture os ubuntu fixed HIGH
  run_image_scan "${ignore}"
  [ "${status}" -eq 1 ]

  write_finding_fixture os ubuntu end_of_life HIGH
  run_image_scan "${ignore}"
  [ "${status}" -eq 1 ]
}

@test "SARIF export stays unfiltered and never decides the gate" {
  write_gate_fake_docker
  write_finding_fixture os ubuntu fixed HIGH
  : >"${DOCKER_LOG}"

  run_image_scan
  [ "${status}" -eq 1 ]
  [ -s "${SECURITY_DIR}/candidate-local.sarif" ]
  [ "$(grep -Fc -- 'convert --format sarif' "${DOCKER_LOG}")" -eq 1 ]
  local sarif_line scan_line
  sarif_line="$(grep -F -- 'convert --format sarif' "${DOCKER_LOG}")"
  [[ "${sarif_line}" != *--severity* ]]
  [[ "${sarif_line}" != *--exit-code* ]]
  [[ "${sarif_line}" != *--ignore-unfixed* ]]
  [[ "${sarif_line}" != *--ignore-status* ]]
  scan_line="$(grep -F -- 'image --config' "${DOCKER_LOG}")"
  [[ "${scan_line}" != *--ignore-status* ]]
  [[ "${scan_line}" != *--ignore-unfixed* ]]

  printf '{"Results":[]}\n' >"${BATS_TEST_TMPDIR}/fixture.json"
  run_image_scan
  [ "${status}" -eq 0 ]
  [ -s "${SECURITY_DIR}/candidate-local.sarif" ]
}

@test "Ubuntu package snapshot and kernel headers are pinned together" {
  run grep -F 'ARG UBUNTU_SNAPSHOT=20260930T000000Z' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F 'ARG LINUX_LIBC_DEV_VERSION=6.8.0-142.142' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    'URIs: https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}' \
    docker/apt/use-package-snapshots
  [ "${status}" -eq 0 ]
  [ "$(grep -Fc '"linux-libc-dev=${LINUX_LIBC_DEV_VERSION}"' Dockerfile)" -eq 2 ]
  run grep -F 'ARG OPENSSL_VERSION=3.0.13-0ubuntu3.16' Dockerfile
  [ "${status}" -eq 0 ]
  [ "$(grep -Fc '"libssl3t64=${OPENSSL_VERSION}"' Dockerfile)" -eq 2 ]
  run grep -F 'default = "20260930T000000Z"' docker-bake.hcl
  [ "${status}" -eq 0 ]
  run grep -F 'default = "6.8.0-142.142"' docker-bake.hcl
  [ "${status}" -eq 0 ]
}
