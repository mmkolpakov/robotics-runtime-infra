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

teardown() {
  rm -f "${REPO_ROOT}/.trivyignore.gate-test"
}

load helpers/security-scanning

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
  # jq is the only exception authority: trivy never reads the ignore policy.
  run grep -F -- '--ignorefile' "${DOCKER_LOG}"
  [ "${status}" -ne 0 ]
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
  write_bake_fake_docker

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
        {"@id": "pkg:deb/ubuntu/linux-libc-dev@6.8.0-149.149?arch=amd64&distro=ubuntu-24.04"},
        {"@id": "pkg:deb/ubuntu/linux-libc-dev@6.8.0-149.149?arch=arm64&distro=ubuntu-24.04"}
      ];
    .["@context"] == "https://openvex.dev/ns/v0.2.0"
    and .author == "mmkolpakov"
    and .version == 16
    and (.statements | length == 182)
    and ([.statements[].vulnerability.name] | length == (unique | length))
    and ([.statements[] | select(.impact_statement | contains("Projected from Canonical Ltd. OpenVEX document"))] | length == 118)
    and ([.statements[] | select(.impact_statement | contains("binary-content applicability"))] | length == 64)
    and all(
      .statements[];
      (.vulnerability.name | test("^CVE-[0-9]{4}-[0-9]+$"))
      and .products == reviewed_headers
      and .status == "not_affected"
      and .justification == "vulnerable_code_not_present"
      and (.impact_statement | contains("Sources: https://"))
      and (.impact_statement | contains("does not qualify the host kernel, hardware"))
      and (.impact_statement | contains("another package version/architecture/distribution"))
      and (.impact_statement | contains("any other vulnerability"))
    )
  '

  run jq -e "$scope_filter" security/vex/linux-libc-dev.openvex.json
  [ "$status" -eq 0 ]

  local cve product mutated="$BATS_TEST_TMPDIR/out-of-scope-vex.json"
  for cve in CVE-2025-40344 CVE-2026-100074 CVE-2026-80668 CVE-2026-89788; do
    for product in \
      'pkg:deb/ubuntu/linux-libc-dev@6.8.0-149.150?arch=amd64&distro=ubuntu-24.04' \
      'pkg:deb/ubuntu/linux-libc-dev@6.8.0-149.149?arch=ppc64el&distro=ubuntu-24.04' \
      'pkg:deb/ubuntu/linux-image-6.8.0-149-generic@6.8.0-149.149?arch=amd64&distro=ubuntu-24.04' \
      'pkg:deb/ubuntu/linux-libc-dev@6.8.0-149.149?arch=amd64&distro=ubuntu-22.04' \
      'pkg:golang/github.com/open-policy-agent/opa@v1.21.2%2Bdirty' \
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
          Class: "os-pkgs",
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
  write_bake_fake_docker

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
  write_finding_fixture os-pkgs ubuntu fixed HIGH

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

  write_finding_fixture os-pkgs ubuntu fixed HIGH
  run_image_scan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"blocking: CVE-2026-0001 HIGH fixed fixture-package (fixture-image)"* ]]

  write_finding_fixture os-pkgs ubuntu fixed CRITICAL
  run_image_scan
  [ "${status}" -eq 1 ]

  write_finding_fixture os-pkgs ubuntu fixed MEDIUM
  run_image_scan
  [ "${status}" -eq 0 ]

  write_finding_fixture os-pkgs ubuntu fixed LOW
  run_image_scan
  [ "${status}" -eq 0 ]
}

@test "image gate tolerates will_not_fix and fix_deferred for Ubuntu OS packages" {
  write_gate_fake_docker

  write_finding_fixture os-pkgs ubuntu will_not_fix HIGH
  run_image_scan
  [ "${status}" -eq 0 ]

  write_finding_fixture os-pkgs ubuntu fix_deferred HIGH
  run_image_scan
  [ "${status}" -eq 0 ]

  write_finding_fixture os-pkgs ubuntu fix_deferred CRITICAL
  run_image_scan
  [ "${status}" -eq 0 ]

  # A CRITICAL will_not_fix is a permanent risk: it needs an exception.
  write_finding_fixture os-pkgs ubuntu will_not_fix CRITICAL
  run_image_scan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"blocking: CVE-2026-0001 CRITICAL will_not_fix"* ]]

  write_gate_exception "SEC-42" "$(gate_date_offset +30)"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 0 ]
}

@test "image gate blocks end_of_life findings even for Ubuntu OS packages" {
  write_gate_fake_docker

  write_finding_fixture os-pkgs ubuntu end_of_life HIGH
  run_image_scan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"blocking: CVE-2026-0001 HIGH end_of_life"* ]]

  write_finding_fixture lang-pkgs gobinary end_of_life CRITICAL
  run_image_scan
  [ "${status}" -eq 1 ]
}

@test "image gate blocks language and Alpine findings regardless of status" {
  write_gate_fake_docker

  local type finding_status
  for type in gobinary python-pkg; do
    for finding_status in fixed affected will_not_fix fix_deferred unknown under_investigation; do
      write_finding_fixture lang-pkgs "${type}" "${finding_status}" HIGH
      run_image_scan
      [ "${status}" -eq 1 ] || {
        printf 'gate accepted %s %s\n' "${type}" "${finding_status}" >&2
        return 1
      }
    done
  done

  # Alpine is an OS ecosystem, not a language package, and never Ubuntu.
  write_finding_fixture os-pkgs alpine will_not_fix HIGH
  run_image_scan
  [ "${status}" -eq 1 ]

  write_finding_fixture os-pkgs alpine affected CRITICAL
  run_image_scan
  [ "${status}" -eq 1 ]

  write_finding_fixture os-pkgs alpine fix_deferred CRITICAL
  run_image_scan
  [ "${status}" -eq 1 ]
}

@test "image gate fails closed on unknown, under_investigation and missing status" {
  write_gate_fake_docker

  local finding_status
  for finding_status in unknown under_investigation missing; do
    write_finding_fixture os-pkgs ubuntu "${finding_status}" HIGH
    run_image_scan
    [ "${status}" -eq 1 ] || {
      printf 'gate accepted ubuntu status %s\n' "${finding_status}" >&2
      return 1
    }
    [[ "${output}" == *"blocking: CVE-2026-0001 HIGH ${finding_status}"* ]]

    write_finding_fixture os-pkgs ubuntu "${finding_status}" CRITICAL
    run_image_scan
    [ "${status}" -eq 1 ]

    write_finding_fixture lang-pkgs gobinary "${finding_status}" HIGH
    run_image_scan
    [ "${status}" -eq 1 ]
  done

  # An exception cannot rescue a fail-closed status.
  write_gate_exception "#42" "$(gate_date_offset +30)"
  write_finding_fixture os-pkgs ubuntu under_investigation CRITICAL
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]
}

@test "image gate allows affected Ubuntu findings only with a ticketed unexpired exception" {
  write_gate_fake_docker
  write_finding_fixture os-pkgs ubuntu affected HIGH
  local exp
  exp="$(gate_date_offset +30)"

  run_image_scan
  [ "${status}" -eq 1 ]

  write_gate_exception "SEC-42" "${exp}"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 0 ]

  write_gate_exception "#42" "${exp}"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 0 ]

  write_gate_exception "issue-42" "${exp}"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  write_gate_exception "SEC-42" "$(gate_date_offset -1)"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  write_gate_ignore 'CVE-2026-0001 # reason: distro backlog; exp:2999-01-01'
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  write_gate_ignore 'CVE-2026-0001 #reason: distro backlog;pkg:fixture-package;target:fixture-image;exp:2999-01-01'
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  write_gate_ignore '# nothing accepted'
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  # Exceptions are scoped to a package and a target, never a whole image.
  write_gate_exception "SEC-42" "${exp}" "other-package"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  write_gate_exception "SEC-42" "${exp}" "fixture-package" "other-target"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  write_gate_exception "SEC-42" "${exp}"
  write_finding_fixture lang-pkgs gobinary affected HIGH
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  write_finding_fixture os-pkgs ubuntu fixed HIGH
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  write_finding_fixture os-pkgs ubuntu end_of_life HIGH
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]
}

@test "image gate exceptions expire strictly after today and within 90 days" {
  write_gate_fake_docker
  write_finding_fixture os-pkgs ubuntu affected HIGH

  write_gate_exception "SEC-42" "$(gate_date_offset 0)"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]

  write_gate_exception "SEC-42" "$(gate_date_offset +90)"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 0 ]

  write_gate_exception "SEC-42" "$(gate_date_offset +91)"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]
}

@test "ignore policy lint rejects broken and expired entries" {
  local exp
  exp="$(gate_date_offset +30)"

  run scripts/ci/security/lint-trivyignore.sh .trivyignore
  [ "${status}" -eq 0 ]
  [ "${output}" = "[]" ]

  write_gate_ignore \
    '# a comment' \
    '' \
    "CVE-2026-0001 #reason: distro backlog;pkg:fixture-package;target:fixture-image;review:SEC-42;exp:${exp}"
  run scripts/ci/security/lint-trivyignore.sh .trivyignore.gate-test
  [ "${status}" -eq 0 ]
  run jq -e 'length == 1 and .[0].cve == "CVE-2026-0001" and .[0].review == "SEC-42"' <<<"${output}"
  [ "${status}" -eq 0 ]

  local line
  for line in \
    'garbage line' \
    'CVE-2026-0001' \
    'CVE-2026-0001 # reason: old style; exp:2999-01-01' \
    "CVE-2026-0001 #reason: x;pkg:p;target:t;review:issue-42;exp:${exp}" \
    "CVE-2026-0001 #reason: x;pkg:p;target:t;review:#42;exp: ${exp}" \
    "CVE-2026-0001 #reason: x;pkg:p;target:t;review:#42;exp:2026-02-30" \
    "CVE-2026-0001 #reason: x;pkg:p;target:t;review:#42;exp:$(gate_date_offset 0)" \
    "CVE-2026-0001 #reason: x;pkg:p;target:t;review:#42;exp:$(gate_date_offset -1)" \
    "CVE-2026-0001 #reason: x;pkg:p;target:t;review:#42;exp:$(gate_date_offset +91)" \
    "CVE-2026-0001 #reason: ;pkg:p;target:t;review:#42;exp:${exp}" \
    "CVE-2026-0001 #reason: x;pkg:p;target: ;review:#42;exp:${exp}" \
    "CVE-2026-0001 #reason: x;pkg:p;target:t;review:#42;exp:${exp};extra:field"; do
    write_gate_ignore "${line}"
    run scripts/ci/security/lint-trivyignore.sh .trivyignore.gate-test
    [ "${status}" -eq 1 ] || {
      printf 'lint accepted: %s\n' "${line}" >&2
      return 1
    }
    [[ "${output}" == *"invalid .trivyignore entries"* ]]
  done

  run scripts/ci/security/lint-trivyignore.sh .trivyignore.does-not-exist
  [ "${status}" -ne 0 ]
}

@test "ignore file override stays repository-relative" {
  write_gate_fake_docker
  write_finding_fixture os-pkgs ubuntu fixed LOW

  run env \
    "PATH=${FAKE_BIN}:${PATH}" \
    "DOCKER_LOG=${DOCKER_LOG}" \
    "HOME=${BATS_TEST_TMPDIR}" \
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}" \
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" \
    "ROBOTICS_CI_TRIVY_IGNORE_FILE=${BATS_TEST_TMPDIR}/trivyignore" \
    TRIVY_IMAGE=trivy:test \
    scripts/ci/security/scan-image.sh registry.example/runtime:test candidate
  [ "${status}" -eq 64 ]
  [[ "${output}" == *"repository-relative"* ]]

  local escape
  for escape in '../trivyignore' 'sub/../.trivyignore' '..'; do
    run env \
      "PATH=${FAKE_BIN}:${PATH}" \
      "DOCKER_LOG=${DOCKER_LOG}" \
      "HOME=${BATS_TEST_TMPDIR}" \
      "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}" \
      "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" \
      "ROBOTICS_CI_TRIVY_IGNORE_FILE=${escape}" \
      TRIVY_IMAGE=trivy:test \
      scripts/ci/security/scan-image.sh registry.example/runtime:test candidate
    [ "${status}" -eq 64 ]
    [[ "${output}" == *"must not leave the repository"* ]]
  done

  run env \
    "PATH=${FAKE_BIN}:${PATH}" \
    "DOCKER_LOG=${DOCKER_LOG}" \
    "HOME=${BATS_TEST_TMPDIR}" \
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}" \
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" \
    "ROBOTICS_CI_TRIVY_IGNORE_FILE=.trivyignore.missing" \
    TRIVY_IMAGE=trivy:test \
    scripts/ci/security/scan-image.sh registry.example/runtime:test candidate
  [ "${status}" -eq 66 ]
}

@test "image gate evaluates each platform report independently" {
  write_gate_fake_docker
  printf '{"Results":[]}\n' >"${BATS_TEST_TMPDIR}/clean.json"
  write_finding_fixture os-pkgs ubuntu fixed CRITICAL
  cp "${BATS_TEST_TMPDIR}/fixture.json" "${BATS_TEST_TMPDIR}/blocking.json"

  SCAN_FIXTURE_LINUX_AMD64="${BATS_TEST_TMPDIR}/clean.json" \
    SCAN_FIXTURE_LINUX_ARM64="${BATS_TEST_TMPDIR}/blocking.json" \
    run_image_scan "" linux/amd64,linux/arm64

  [ "${status}" -eq 1 ]
  [[ "${output}" == *"vulnerability gate failed: registry.example/runtime:test linux-arm64"* ]]
  [[ "${output}" != *"linux-amd64"* ]]
  [ -s "${SECURITY_DIR}/candidate-linux-amd64.sarif" ]
  [ -s "${SECURITY_DIR}/candidate-linux-arm64.sarif" ]
  [ "$(wc -l <"${DOCKER_LOG}")" -eq 5 ]
}

@test "tolerated findings are written to the job summary" {
  write_gate_fake_docker
  jq -n '
    {
      Results: [
        {
          Target: "fixture-image",
          Class: "os-pkgs",
          Type: "ubuntu",
          Vulnerabilities: [
            {VulnerabilityID: "CVE-2026-0001", PkgName: "fixture-package", Severity: "HIGH", Status: "will_not_fix"},
            {VulnerabilityID: "CVE-2026-0002", PkgName: "fixture-package", Severity: "CRITICAL", Status: "fix_deferred"},
            {VulnerabilityID: "CVE-2026-0003", PkgName: "fixture-package", Severity: "CRITICAL", Status: "affected"},
            {VulnerabilityID: "CVE-2026-0004", PkgName: "fixture-package", Severity: "CRITICAL", Status: "fixed"}
          ]
        }
      ]
    }
  ' >"${BATS_TEST_TMPDIR}/fixture.json"
  write_gate_ignore \
    "CVE-2026-0003 #reason: distro backlog;pkg:fixture-package;target:fixture-image;review:SEC-42;exp:$(gate_date_offset +30)"

  GITHUB_STEP_SUMMARY="${BATS_TEST_TMPDIR}/summary.md"
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"tolerated: CVE-2026-0001 HIGH will_not_fix"* ]]
  [[ "${output}" == *"tolerated: CVE-2026-0002 CRITICAL fix_deferred"* ]]
  [[ "${output}" == *"tolerated: CVE-2026-0003 CRITICAL affected"* ]]
  [ -s "${GITHUB_STEP_SUMMARY}" ]
  run grep -F 'Tolerated Ubuntu findings: registry.example/runtime:test (local)' "${GITHUB_STEP_SUMMARY}"
  [ "${status}" -eq 0 ]
  run grep -F '| CVE-2026-0001 | HIGH | will_not_fix | fixture-package | fixture-image | no |' "${GITHUB_STEP_SUMMARY}"
  [ "${status}" -eq 0 ]
  run grep -F '| CVE-2026-0003 | CRITICAL | affected | fixture-package | fixture-image | SEC-42 |' "${GITHUB_STEP_SUMMARY}"
  [ "${status}" -eq 0 ]
  run grep -F 'CVE-2026-0004' "${GITHUB_STEP_SUMMARY}"
  [ "${status}" -ne 0 ]

  # Without a job summary the gate still reports tolerated findings on stdout.
  GITHUB_STEP_SUMMARY=""
  run_image_scan ".trivyignore.gate-test"
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"tolerated: CVE-2026-0001 HIGH will_not_fix"* ]]
}

@test "golden Trivy report pins the os-pkgs and lang-pkgs schema" {
  # Trimmed from a real aquasec/trivy:0.75.0 scan of its own image
  # (docker.io/aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa,
  # alpine 3.24.2 base, gobinary /usr/local/bin/trivy); finding objects are
  # verbatim, only the finding selection and package lists were trimmed.
  local golden="test/ci/fixtures/trivy-0.75.0-os-lang.json"

  run jq -e '
    .SchemaVersion == 2
    and .ArtifactType == "container_image"
    and .Trivy.Version == "0.75.0"
    and ([.Results[].Class] == ["os-pkgs", "lang-pkgs"])
    and ([.Results[].Type] == ["alpine", "gobinary"])
    and all(.Results[].Vulnerabilities[];
      has("VulnerabilityID") and has("PkgName") and has("PkgID")
      and has("InstalledVersion") and has("Status") and has("Severity")
      and (.PkgIdentifier.PURL | type == "string")
      and (.Layer.DiffID | startswith("sha256:"))
      and (.DataSource | has("ID") and has("Name") and has("URL"))
      and (.Status == "fixed"))
  ' "${golden}"
  [ "${status}" -eq 0 ]

  # The gate reads the real schema: Alpine OS and Go findings block, and
  # UNKNOWN-severity findings never reach the HIGH/CRITICAL gate.
  write_gate_fake_docker
  SCAN_FIXTURE="${REPO_ROOT}/${golden}" run_image_scan
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"blocking: CVE-2026-111497 CRITICAL fixed brotli-libs"* ]]
  [[ "${output}" == *"blocking: CVE-2026-116587 HIGH fixed github.com/go-jose/go-jose/v4"* ]]
  [[ "${output}" != *"CVE-2026-114467"* ]]
  [[ "${output}" != *"GO-2026-5932"* ]]
}

@test "VEX-suppressed findings stay out of the gate" {
  # Real aquasec/trivy:0.75.0 scan of alpine:3.10.9 with a not_affected
  # OpenVEX statement and --show-suppressed: the suppressed finding lives in
  # ExperimentalModifiedFindings, never in Vulnerabilities.
  local suppressed="test/ci/fixtures/trivy-0.75.0-vex-suppressed.json"

  run jq -e '
    .SchemaVersion == 2
    and (.Results[0].Class == "os-pkgs")
    and (.Results[0].Vulnerabilities == null)
    and (.Results[0].ExperimentalModifiedFindings | length == 1)
    and (.Results[0].ExperimentalModifiedFindings[0] | (
      .Type == "vulnerability"
      and .Status == "not_affected"
      and .Statement == "vulnerable_code_not_present"
      and (.Source | endswith(".json"))
      and .Finding.VulnerabilityID == "CVE-2021-36159"
      and .Finding.PkgName == "apk-tools"
      and .Finding.Severity == "CRITICAL"))
  ' "${suppressed}"
  [ "${status}" -eq 0 ]

  write_gate_fake_docker
  SCAN_FIXTURE="${REPO_ROOT}/${suppressed}" run_image_scan
  [ "${status}" -eq 0 ]
  [[ "${output}" != *"blocking:"* ]]
}

@test "trivy.yaml and the gate scan keep severity and status filtering out" {
  run grep -nE '(^|[[:space:]])(severity|ignore-unfixed|ignore-status)[[:space:]]*:' trivy.yaml
  [ "${status}" -ne 0 ]

  run grep -nE -- '--ignorefile|--ignore-unfixed|--ignore-status' scripts/ci/security/scan-image.sh
  [ "${status}" -ne 0 ]

  run grep -F -- '--ignorefile' .github/workflows/rk3588-qualification.yml
  [ "${status}" -ne 0 ]
}

@test "SARIF export stays unfiltered and never decides the gate" {
  write_gate_fake_docker
  write_finding_fixture os-pkgs ubuntu fixed HIGH
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
  [[ "${scan_line}" != *--ignorefile* ]]
  [[ "${scan_line}" != *--severity* ]]
  [[ "${scan_line}" != *--ignore-status* ]]
  [[ "${scan_line}" != *--ignore-unfixed* ]]

  printf '{"Results":[]}\n' >"${BATS_TEST_TMPDIR}/fixture.json"
  run_image_scan
  [ "${status}" -eq 0 ]
  [ -s "${SECURITY_DIR}/candidate-local.sarif" ]
}

@test "real trivy keeps ticketless ignore entries blocking" {
  if ! command -v docker >/dev/null 2>&1 || ! docker info >/dev/null 2>&1; then
    skip "docker is not available for the real-trivy regression"
  fi
  local image="docker.io/library/alpine:3.10.9@sha256:451eee8bedcb2f029756dc3e9d73bab0e7943c1ac55cff3a4861c52a0fdd3e98"
  local trivy_image="${TRIVY_IMAGE:-aquasec/trivy:0.75.0@sha256:af6acf9a6b85dfe389a1941505c0ce9efef52a4719635e1a962f022a3d855daa}"
  docker pull "${image}"

  local environment=(
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}"
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${REPO_ROOT}/.trivy-cache"
    "TRIVY_IMAGE=${trivy_image}"
  )
  run env "${environment[@]}" \
    scripts/ci/security/scan-image.sh "${image}" regression
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"blocking: CVE-2021-36159 CRITICAL fixed apk-tools"* ]]
  run jq -e '
    [.Results[].Vulnerabilities[]?
      | select(.VulnerabilityID == "CVE-2021-36159")] | length > 0
  ' "${SECURITY_DIR}/regression-local.json"
  [ "${status}" -eq 0 ]

  # A well-formed ticketed exception still cannot pass: Alpine is not Ubuntu,
  # and trivy itself must not apply the ignore policy during the scan.
  local target exp
  target="$(jq -r '.Results[0].Target' "${SECURITY_DIR}/regression-local.json")"
  exp="$(gate_date_offset +30)"
  write_gate_ignore \
    "CVE-2021-36159 #reason: regression;pkg:apk-tools;target:${target};review:#107;exp:${exp}"
  run env "${environment[@]}" "ROBOTICS_CI_TRIVY_IGNORE_FILE=.trivyignore.gate-test" \
    scripts/ci/security/scan-image.sh "${image}" regression
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"blocking: CVE-2021-36159 CRITICAL fixed apk-tools"* ]]
  run jq -e '
    [.Results[].Vulnerabilities[]?
      | select(.VulnerabilityID == "CVE-2021-36159")] | length > 0
  ' "${SECURITY_DIR}/regression-local.json"
  [ "${status}" -eq 0 ]
  run jq -e '
    [.Results[].ExperimentalModifiedFindings[]?
      | select(.Finding.VulnerabilityID == "CVE-2021-36159")] | length == 0
  ' "${SECURITY_DIR}/regression-local.json"
  [ "${status}" -eq 0 ]

  # A ticketless entry fails the lint before any scan runs.
  write_gate_ignore 'CVE-2021-36159 # reason: accepted without review; exp:2999-01-01'
  run env "${environment[@]}" "ROBOTICS_CI_TRIVY_IGNORE_FILE=.trivyignore.gate-test" \
    scripts/ci/security/scan-image.sh "${image}" regression
  [ "${status}" -eq 1 ]
  [[ "${output}" == *"invalid .trivyignore entries"* ]]
}

@test "Ubuntu package snapshot and kernel headers are pinned together" {
  run grep -F 'ARG UBUNTU_SNAPSHOT=20261112T000000Z' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F 'ARG LINUX_LIBC_DEV_VERSION=6.8.0-149.149' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F 'ARG CA_CERTIFICATES_VERSION=20260816ubuntu0.24.04.2' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    'URIs: https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}' \
    docker/apt/use-package-snapshots
  [ "${status}" -eq 0 ]
  [ "$(grep -Fc '"linux-libc-dev=${LINUX_LIBC_DEV_VERSION}"' Dockerfile)" -eq 2 ]
  run grep -F 'ARG OPENSSL_VERSION=3.0.13-0ubuntu3.16' Dockerfile
  [ "${status}" -eq 0 ]
  [ "$(grep -Fc '"libssl3t64=${OPENSSL_VERSION}"' Dockerfile)" -eq 2 ]
  run grep -F 'default = "20261112T000000Z"' docker-bake.hcl
  [ "${status}" -eq 0 ]
  run grep -F 'default = "6.8.0-149.149"' docker-bake.hcl
  [ "${status}" -eq 0 ]
}
