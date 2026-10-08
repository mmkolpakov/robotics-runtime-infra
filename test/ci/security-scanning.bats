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

@test "image scanner accepts a quoted platform CSV without word splitting" {
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${DOCKER_LOG}"
EOF
  chmod +x "${FAKE_BIN}/docker"

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
  run jq -e '
    def reviewed_headers:
      [
        {"@id": "pkg:deb/ubuntu/linux-libc-dev@6.8.0-142.142?arch=amd64&distro=ubuntu-24.04"},
        {"@id": "pkg:deb/ubuntu/linux-libc-dev@6.8.0-142.142?arch=arm64&distro=ubuntu-24.04"}
      ];
    def scoped_cves:
      ["CVE-2024-46742", "CVE-2024-46833", "CVE-2024-52560", "CVE-2024-56591"];
    .["@context"] == "https://openvex.dev/ns/v0.2.0"
    and .author == "mmkolpakov"
    and .version == 11
    and (.statements | length == 193)
    and ([.statements[] | select(.products == reviewed_headers)] | length == 138)
    and (
      [.statements[].vulnerability.name]
      | length == (unique | length)
    )
    and (
      [.statements[].vulnerability.name
        | select(. as $name | scoped_cves | index($name) != null)]
      | sort == scoped_cves
    )
    and all(
      .statements[];
      (.vulnerability.name | test("^CVE-[0-9]{4}-[0-9]+$"))
      and (
        if (.vulnerability.name as $name | scoped_cves | index($name)) != null then
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
  ' security/vex/linux-libc-dev.openvex.json
  [ "${status}" -eq 0 ]

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
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if test "$1 $2 $3 $4 $5" = "buildx bake --file docker-bake.hcl --print"; then
  cat "${BAKE_PLAN}"
  exit 0
fi
printf '%s\n' "$*" >>"${DOCKER_LOG}"
if [[ " $* " == *" --format sarif "* && "$*" == *"/reports/accelerator-conformance-"* ]]; then
  exit 1
fi
EOF
  chmod +x "${FAKE_BIN}/docker"

  run env \
    "PATH=${FAKE_BIN}:${PATH}" \
    "BAKE_PLAN=${BATS_TEST_TMPDIR}/bake-plan.json" \
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
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${DOCKER_LOG}"
for argument in "$@"; do
  if [[ "${argument}" == convert ]]; then
    exit 1
  fi
done
EOF
  chmod +x "${FAKE_BIN}/docker"

  run env \
    "PATH=${FAKE_BIN}:${PATH}" \
    "DOCKER_LOG=${DOCKER_LOG}" \
    "HOME=${BATS_TEST_TMPDIR}" \
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}" \
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" \
    TRIVY_IMAGE=trivy:test \
    scripts/ci/security/scan-image.sh \
      registry.example/runtime:test candidate linux/amd64,linux/arm64

  [ "${status}" -eq 1 ]
  [ "$(wc -l <"${DOCKER_LOG}")" -eq 6 ]
  [ "$(grep -Fc -- '--format table' "${DOCKER_LOG}")" -eq 2 ]
  [[ "${output}" == *"vulnerability gate failed: registry.example/runtime:test linux-amd64"* ]]
  [[ "${output}" == *"vulnerability gate failed: registry.example/runtime:test linux-arm64"* ]]
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
