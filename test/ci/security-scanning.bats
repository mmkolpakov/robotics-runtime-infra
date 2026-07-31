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
    .["@context"] == "https://openvex.dev/ns/v0.2.0"
    and .author == "mmkolpakov"
    and .version == 2
    and (
      [.statements[].vulnerability.name]
      | length == (unique | length)
    )
    and all(
      .statements[];
      (.vulnerability.name | test("^CVE-[0-9]{4}-[0-9]+$"))
      and .products == [{"@id": "pkg:deb/ubuntu/linux-libc-dev"}]
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

@test "Ubuntu package snapshot and kernel headers are pinned together" {
  run grep -F 'ARG UBUNTU_SNAPSHOT=20260726T000000Z' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F 'ARG LINUX_LIBC_DEV_VERSION=6.8.0-136.136' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    'URIs: https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}' \
    docker/apt/use-package-snapshots
  [ "${status}" -eq 0 ]
  [ "$(grep -Fc '"linux-libc-dev=${LINUX_LIBC_DEV_VERSION}"' Dockerfile)" -eq 2 ]
  run grep -F 'default = "20260726T000000Z"' docker-bake.hcl
  [ "${status}" -eq 0 ]
  run grep -F 'default = "6.8.0-136.136"' docker-bake.hcl
  [ "${status}" -eq 0 ]
}
