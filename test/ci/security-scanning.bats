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
  [ "$(grep -Fc -- '--vex /work/security/vex/linux-libc-dev.openvex.json' "${DOCKER_LOG}")" -eq 4 ]
  [ "$(grep -Fc -- '--vex /work/security/vex/grpc-go-cli.openvex.json' "${DOCKER_LOG}")" -eq 4 ]
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
if test "$1 $2 $3" = "buildx bake --print"; then
  cat "${BAKE_PLAN}"
  exit 0
fi
printf '%s\n' "$*" >>"${DOCKER_LOG}"
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
    and (.statements | length) == 53
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

@test "gRPC OpenVEX policy is limited to non-server CLI dependency paths" {
  run jq -e '
    .["@context"] == "https://openvex.dev/ns/v0.2.0"
    and .author == "mmkolpakov"
    and (.statements | length) == 2
    and all(
      .statements[];
      .vulnerability.name == "GHSA-hrxh-6v49-42gf"
      and .status == "not_affected"
      and .justification == "vulnerable_code_not_in_execute_path"
      and (.impact_statement | contains("HTTP/2 gRPC server"))
      and (.products | length) == 1
      and (
        .products[0]["@id"] ==
          "pkg:golang/github.com/sigstore/cosign/v3@v3.1.1"
        or .products[0]["@id"] ==
          "pkg:golang/github.com/open-policy-agent/opa"
      )
      and .products[0].subcomponents == [
        {"@id": "pkg:golang/google.golang.org/grpc@v1.81.1"}
      ]
    )
    and all(
      .statements[].products[];
      .["@id"] != "pkg:golang/google.golang.org/grpc@v1.81.1"
    )
  ' security/vex/grpc-go-cli.openvex.json
  [ "${status}" -eq 0 ]

  run grep -F -- '--vex /work/security/vex/grpc-go-cli.openvex.json' \
    .github/workflows/rk3588-qualification.yml
  [ "${status}" -eq 0 ]

  run grep -F 'ARG OPA_VERSION=1.18.2' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    'ARG OPA_REVISION=e695c9ef8edb0f8b9f13d014d7bc8a7fbcc57297' \
    Dockerfile
  [ "${status}" -eq 0 ]
  run grep -E '^[[:space:]]*opa (run|serve)([[:space:]]|$)' \
    Dockerfile docker/permit-preflight/permit-preflight
  [ "${status}" -eq 1 ]

  run grep -F \
    'https://raw.githubusercontent.com/sigstore/cosign/v3.1.1/LICENSE' \
    Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F 'install -d -m 0555 /usr/share/licenses/cosign' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F 'cosign.spdx.json' Dockerfile
  [ "${status}" -eq 1 ]
}

@test "Ubuntu package snapshot and kernel headers are pinned together" {
  run grep -F 'ARG UBUNTU_SNAPSHOT=20260726T000000Z' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F 'ARG LINUX_LIBC_DEV_VERSION=6.8.0-136.136' Dockerfile
  [ "${status}" -eq 0 ]
  [ "$(grep -Fc 'https://snapshot.ubuntu.com/ubuntu/20260726T000000Z/' Dockerfile)" -eq 4 ]
  [ "$(grep -Fc '"linux-libc-dev=${LINUX_LIBC_DEV_VERSION}"' Dockerfile)" -eq 2 ]
  run grep -F 'default = "20260726T000000Z"' docker-bake.hcl
  [ "${status}" -eq 0 ]
  run grep -F 'default = "6.8.0-136.136"' docker-bake.hcl
  [ "${status}" -eq 0 ]
}
