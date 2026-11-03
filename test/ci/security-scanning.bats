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
  run grep -F 'ARG UBUNTU_SNAPSHOT=20261101T000000Z' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F 'ARG LINUX_LIBC_DEV_VERSION=6.8.0-147.147' Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F \
    'URIs: https://snapshot.ubuntu.com/ubuntu/${UBUNTU_SNAPSHOT}' \
    docker/apt/use-package-snapshots
  [ "${status}" -eq 0 ]
  [ "$(grep -Fc '"linux-libc-dev=${LINUX_LIBC_DEV_VERSION}"' Dockerfile)" -eq 2 ]
  run grep -F 'ARG OPENSSL_VERSION=3.0.13-0ubuntu3.16' Dockerfile
  [ "${status}" -eq 0 ]
  [ "$(grep -Fc '"libssl3t64=${OPENSSL_VERSION}"' Dockerfile)" -eq 2 ]
  run grep -F 'default = "20261101T000000Z"' docker-bake.hcl
  [ "${status}" -eq 0 ]
  run grep -F 'default = "6.8.0-147.147"' docker-bake.hcl
  [ "${status}" -eq 0 ]
}

@test "prepared vendor VEX is mounted read-only and retains native scan output" {
  local vendor_dir="${SECURITY_DIR}/vendor-vex"
  mkdir -p "${vendor_dir}"
  printf '{}\n' >"${vendor_dir}/canonical-ubuntu.openvex.json"
  printf '{}\n' >"${vendor_dir}/provenance.json"
  (cd "${vendor_dir}" && sha256sum canonical-ubuntu.openvex.json provenance.json >SHA256SUMS)
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${DOCKER_LOG}"
EOF
  chmod +x "${FAKE_BIN}/docker"

  environment=(
    "PATH=${FAKE_BIN}:${PATH}" "DOCKER_LOG=${DOCKER_LOG}"
    "HOME=${BATS_TEST_TMPDIR}" "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}"
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}"
    "ROBOTICS_CI_VENDOR_VEX_DIR=${vendor_dir}" TRIVY_IMAGE=trivy:test
  )
  run env "${environment[@]}" scripts/ci/security/scan-image.sh \
    registry.example/runtime:test candidate linux/amd64
  [ "${status}" -eq 0 ]
  grep -F -- "${vendor_dir}:/vendor-vex:ro" "${DOCKER_LOG}"
  grep -F -- '--vex /vendor-vex/canonical-ubuntu.openvex.json' "${DOCKER_LOG}"
  grep -F -- '--show-suppressed --list-all-pkgs' "${DOCKER_LOG}"

  rm "${DOCKER_LOG}"
  printf 'tampered\n' >>"${vendor_dir}/canonical-ubuntu.openvex.json"
  run env "${environment[@]}" scripts/ci/security/scan-image.sh \
    registry.example/runtime:test candidate linux/amd64
  [ "${status}" -ne 0 ]
  [ ! -e "${DOCKER_LOG}" ]
}

@test "explicit vendor VEX input fails when missing or outside retained artifacts" {
  run env "HOME=${BATS_TEST_TMPDIR}" TRIVY_IMAGE=trivy:test \
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}" \
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" \
    "ROBOTICS_CI_VENDOR_VEX_DIR=${BATS_TEST_TMPDIR}" \
    scripts/ci/security/scan-image.sh registry.example/runtime:test candidate
  [ "${status}" -ne 0 ]

  mkdir "${SECURITY_DIR}/incomplete-vex"
  run env "HOME=${BATS_TEST_TMPDIR}" TRIVY_IMAGE=trivy:test \
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}" \
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" \
    "ROBOTICS_CI_VENDOR_VEX_DIR=${SECURITY_DIR}/incomplete-vex" \
    scripts/ci/security/scan-image.sh registry.example/runtime:test candidate
  [ "${status}" -ne 0 ]
}

@test "explicit comprehensive detection uses the stock flag and rejects other values" {
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${DOCKER_LOG}"
EOF
  chmod +x "${FAKE_BIN}/docker"
  environment=(
    "PATH=${FAKE_BIN}:${PATH}" "DOCKER_LOG=${DOCKER_LOG}"
    "HOME=${BATS_TEST_TMPDIR}" "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}"
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}" TRIVY_IMAGE=trivy:test
  )
  run env "${environment[@]}" ROBOTICS_CI_TRIVY_DETECTION_PRIORITY=comprehensive \
    scripts/ci/security/scan-image.sh registry.example/runtime:test supplier linux/amd64
  [ "${status}" -eq 0 ]
  grep -F -- 'image --detection-priority comprehensive' "${DOCKER_LOG}"
  grep -F -- '--severity HIGH,CRITICAL --exit-code 1' "${DOCKER_LOG}"
  rm "${DOCKER_LOG}"
  for priority in precise unknown '--ignore-unfixed'; do
    run env "${environment[@]}" "ROBOTICS_CI_TRIVY_DETECTION_PRIORITY=${priority}" \
      scripts/ci/security/scan-image.sh registry.example/runtime:test supplier linux/amd64
    [ "${status}" -eq 65 ]
    [ ! -e "${DOCKER_LOG}" ]
  done
}

setup_canonical_scan() {
  export IMAGE_ID="sha256:$(printf 'a%.0s' {1..64})"
  export CAPTURE_CID="$(printf 'c%.0s' {1..64})"
  mkdir -p "${SECURITY_DIR}/canonical-raw"
  cat >"${FAKE_BIN}/docker" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
printf '%s\n' "$*" >>"${DOCKER_LOG}"
case "$1 $2" in
  'image inspect')
    jq -n --arg id "$IMAGE_ID" --arg arch "$FAKE_ARCH" \
      --arg os "${FAKE_IMAGE_OS:-linux}" '{Id:$id, Architecture:$arch, Os:$os}'
    ;;
  'container inspect')
    observed_id="$IMAGE_ID"
    observed_state=created
    count="$(grep -c '^container inspect ' "${DOCKER_LOG}")"
    if test "$FAKE_MODE" = container-id || { test "$FAKE_MODE" = container-after && test "$count" -eq 2; }; then
      observed_id=sha256:foreign
    fi
    test "$FAKE_MODE" != container-running || observed_state=running
    jq -n --arg id "$CAPTURE_CID" --arg image "$observed_id" --arg state "$observed_state" \
      '{Id:$id, Image:$image, State:{Status:$state, Running:($state == "running")}}'
    ;;
  *)
    case "$1" in
      create)
        while test "$1" != --cidfile; do shift; done
        printf '%s\n' "$CAPTURE_CID" >"$2"
        printf '%s\n' "$CAPTURE_CID"
        test "$FAKE_MODE" != create-fail || exit 35
        ;;
      cp)
        test "$2" = -L
        test "$FAKE_MODE" != missing-os || exit 31
        printf 'ID=ubuntu\nVERSION_ID="24.04"\nVERSION_CODENAME=noble\n' >"${@: -1}"
        test "$FAKE_MODE" != wrong-os || printf 'VERSION_CODENAME=jammy\n' >"${@: -1}"
        ;;
      rm)
        test "$*" = "rm --volumes $CAPTURE_CID"
        test "$FAKE_MODE" != cleanup-fail || exit 36
        ;;
      run)
        output=
        for ((i=1; i<=$#; i++)); do
          if test "${!i}" = --output; then j=$((i+1)); output="${!j}"; fi
        done
        if [[ " $* " == *' trivy:test image '* ]]; then
          target="${SECURITY_DIR}/$(basename "$output")"
          jq -n --arg id "$IMAGE_ID" --arg arch "$FAKE_ARCH" --arg mode "$FAKE_MODE" '
            {SchemaVersion:2, ArtifactName:"fixture", Metadata:{
              ImageID:(if $mode == "report-id" then "sha256:foreign" else $id end),
              ImageConfig:{architecture:(if $mode == "report-arch" then "foreign" else $arch end)},
              OS:{Family:"ubuntu", Name:(if $mode == "report-os" then "22.04" else "24.04" end)}},
             Results:[{Packages:[{Name:"linux-libc-dev", Identifier:{PURL:
              ("pkg:deb/ubuntu/linux-libc-dev@6.8.0-147.147?arch="+$arch+"&distro=ubuntu-24.04")}}],
              Vulnerabilities:["CVE-2026-63825","CVE-2026-100074","CVE-2026-112393","CVE-2026-41316"]}]}
          ' >"$target"
          if [[ " $* " == *' --vex /canonical-vex/'* ]]; then
            jq '.Results[0].Vulnerabilities |= map(select(. != "CVE-2026-63825"))' "$target" >"$target.next"
            mv "$target.next" "$target"
            test "$FAKE_MODE" != second-scan || exit 32
          else
            test "$FAKE_MODE" != first-scan || exit 33
          fi
        elif [[ " $* " == *' convert '* && " $* " == *' --format sarif '* ]]; then
          exit 1
        fi
        ;;
      *) exit 99 ;;
    esac
    ;;
esac
EOF
  chmod +x "${FAKE_BIN}/docker"
  cat >"${FAKE_BIN}/security-python" <<'EOF'
#!/usr/bin/env bash
set -Eeuo pipefail
if test "$1" = -c; then exit 0; fi
printf '%s\n' "$*" >"${DOCKER_LOG}.prepare"
while test "$#" -gt 0; do
  case "$1" in
    --output-dir) destination="$2"; shift ;;
    --os-release) original_os="$2"; shift ;;
    --scan-report) original_report="$2"; shift ;;
  esac
  shift
done
test "$FAKE_MODE" != unknown-vendor || exit 34
grep -Fx 'VERSION_CODENAME=noble' "$original_os" >/dev/null
jq -e '.Results[0].Vulnerabilities | index("CVE-2026-63825") != null' "$original_report" >/dev/null
mkdir "$destination"
printf '{}\n' >"$destination/canonical-ubuntu.openvex.json"
printf '{}\n' >"$destination/provenance.json"
(cd "$destination" && sha256sum canonical-ubuntu.openvex.json provenance.json >SHA256SUMS)
EOF
  chmod +x "${FAKE_BIN}/security-python"
  environment=(
    "PATH=${FAKE_BIN}:${PATH}" "DOCKER_LOG=${DOCKER_LOG}" "HOME=${BATS_TEST_TMPDIR}"
    "SECURITY_DIR=${SECURITY_DIR}"
    "ROBOTICS_CI_SECURITY_ARTIFACT_DIR=${SECURITY_DIR}"
    "ROBOTICS_CI_TRIVY_CACHE_DIR=${TRIVY_CACHE_DIR}"
    "ROBOTICS_CI_CANONICAL_SOURCE_DIR=${SECURITY_DIR}/canonical-raw"
    "ROBOTICS_CI_SECURITY_PYTHON=${FAKE_BIN}/security-python"
    ROBOTICS_CI_TRIVY_DETECTION_PRIORITY=comprehensive TRIVY_IMAGE=trivy:test
  )
}

@test "Canonical orchestration keeps both reports and the unresolved gate for each architecture" {
  setup_canonical_scan
  for arch in amd64 arm64; do
    : >"${DOCKER_LOG}"
    run env "${environment[@]}" FAKE_MODE=valid "FAKE_ARCH=${arch}" \
      scripts/ci/security/scan-image.sh registry.example/runtime:test "candidate-${arch}" "linux/${arch}"
    [ "${status}" -eq 1 ]
    [[ "${output}" == *'vulnerability gate failed:'* ]]
    [ "$(grep -c '^image inspect ' "${DOCKER_LOG}")" -eq 1 ]
    [ "$(grep -c '^create ' "${DOCKER_LOG}")" -eq 1 ]
    [ "$(grep -c '^rm --volumes ' "${DOCKER_LOG}")" -eq 1 ]
    [ "$(grep -c '^container inspect ' "${DOCKER_LOG}")" -eq 2 ]
    [ "$(grep -c 'trivy:test image --detection-priority comprehensive' "${DOCKER_LOG}")" -eq 2 ]
    [ "$(grep -c -- '--skip-db-update --skip-java-db-update' "${DOCKER_LOG}")" -eq 1 ]
    [ "$(grep -c -- '--show-suppressed --list-all-pkgs' "${DOCKER_LOG}")" -eq 2 ]
    [ "$(grep -c -- "--platform linux/${arch}.*${IMAGE_ID}$" "${DOCKER_LOG}")" -eq 3 ]
    ! grep -E '^(start|restart|exec) |^run.*registry.example/runtime' "${DOCKER_LOG}"
    local original="${SECURITY_DIR}/candidate-${arch}-linux-${arch}-raw.json"
    local final="${SECURITY_DIR}/candidate-${arch}-linux-${arch}.json"
    jq -e '.Results[0].Vulnerabilities | length == 4 and index("CVE-2026-63825") != null' "$original"
    jq -e '.Results[0].Vulnerabilities == ["CVE-2026-100074","CVE-2026-112393","CVE-2026-41316"]' "$final"
    grep -F -- '--severity HIGH,CRITICAL --exit-code 1' "${DOCKER_LOG}"
    grep -F -- "--scan-report ${original}" "${DOCKER_LOG}.prepare"
  done
}

@test "Canonical observation rejects identity errors before creating a container" {
  setup_canonical_scan
  for mode in report-id report-arch report-os; do
    : >"${DOCKER_LOG}"
    run env "${environment[@]}" "FAKE_MODE=${mode}" FAKE_ARCH=arm64 \
      scripts/ci/security/scan-image.sh registry.example/runtime:test "$mode" linux/arm64
    [ "${status}" -ne 0 ]
    ! grep -q '^create ' "${DOCKER_LOG}"
    [ -s "${SECURITY_DIR}/${mode}-linux-arm64-raw.json" ]
  done
  for arch in amd64 arm64; do
    : >"${DOCKER_LOG}"
    other=amd64
    test "$arch" != amd64 || other=arm64
    run env "${environment[@]}" FAKE_MODE=valid "FAKE_ARCH=${arch}" \
      scripts/ci/security/scan-image.sh registry.example/runtime:test "wrong-${arch}" "linux/${other}"
    [ "${status}" -ne 0 ]
    ! grep -q '^create ' "${DOCKER_LOG}"
    ! grep -q 'trivy:test image' "${DOCKER_LOG}"
  done
}

@test "Canonical capture cleans only its stopped container on copy and binding failures" {
  setup_canonical_scan
  for mode in create-fail missing-os wrong-os container-id container-after container-running unknown-vendor; do
    : >"${DOCKER_LOG}"
    run env "${environment[@]}" "FAKE_MODE=${mode}" FAKE_ARCH=arm64 \
      scripts/ci/security/scan-image.sh registry.example/runtime:test "$mode" linux/arm64
    [ "${status}" -ne 0 ]
    [ "$(grep -c '^create ' "${DOCKER_LOG}")" -eq 1 ]
    [ "$(grep -c '^rm --volumes ' "${DOCKER_LOG}")" -eq 1 ]
    [ "$(grep -c 'trivy:test image' "${DOCKER_LOG}")" -eq 1 ]
    ! grep -q -- '--skip-db-update' "${DOCKER_LOG}"
    ! grep -E '^(start|restart|exec) |^run.*registry.example/runtime' "${DOCKER_LOG}"
    [ -s "${SECURITY_DIR}/${mode}-linux-arm64-raw.json" ]
  done
}

@test "Canonical scan errors preserve originals and do not reach format conversion" {
  setup_canonical_scan
  for mode in first-scan second-scan; do
    : >"${DOCKER_LOG}"
    run env "${environment[@]}" "FAKE_MODE=${mode}" FAKE_ARCH=arm64 \
      scripts/ci/security/scan-image.sh registry.example/runtime:test "$mode" linux/arm64
    [ "${status}" -ne 0 ]
    ! grep -q ' convert ' "${DOCKER_LOG}"
    [ -s "${SECURITY_DIR}/${mode}-linux-arm64-raw.json" ]
    if test "$mode" = first-scan; then
      ! grep -q '^create ' "${DOCKER_LOG}"
    else
      [ "$(grep -c '^create ' "${DOCKER_LOG}")" -eq 1 ]
      [ "$(grep -c '^rm --volumes ' "${DOCKER_LOG}")" -eq 1 ]
    fi
  done
}

@test "Canonical opt-in requires comprehensive and cannot mix prebuilt VEX" {
  setup_canonical_scan
  local prebuilt="${SECURITY_DIR}/prebuilt"
  mkdir "$prebuilt"
  printf '{}\n' >"$prebuilt/canonical-ubuntu.openvex.json"
  printf '{}\n' >"$prebuilt/provenance.json"
  (cd "$prebuilt" && sha256sum canonical-ubuntu.openvex.json provenance.json >SHA256SUMS)
  for mode in default mixed; do
    : >"${DOCKER_LOG}"
    if test "$mode" = default; then
      run env "${environment[@]}" ROBOTICS_CI_TRIVY_DETECTION_PRIORITY= \
        scripts/ci/security/scan-image.sh registry.example/runtime:test candidate
    else
      run env "${environment[@]}" "ROBOTICS_CI_VENDOR_VEX_DIR=${prebuilt}" \
        scripts/ci/security/scan-image.sh registry.example/runtime:test candidate
    fi
    [ "${status}" -ne 0 ]
    [ ! -s "${DOCKER_LOG}" ]
  done
}

@test "Canonical local image scan derives its platform without rebuilding" {
  setup_canonical_scan
  run env "${environment[@]}" FAKE_MODE=valid FAKE_ARCH=arm64 \
    scripts/ci/security/scan-image.sh registry.example/runtime:test candidate
  [ "${status}" -eq 1 ]
  [[ "${output}" == *'vulnerability gate failed:'* ]]
  [ "$(grep -c -- '--platform linux/arm64' "${DOCKER_LOG}")" -eq 3 ]
  ! grep -q '^build' "${DOCKER_LOG}"
}

@test "Canonical cleanup failure cannot proceed to the VEX scan" {
  setup_canonical_scan
  run env "${environment[@]}" FAKE_MODE=cleanup-fail FAKE_ARCH=arm64 \
    scripts/ci/security/scan-image.sh registry.example/runtime:test cleanup-fail linux/arm64
  [ "${status}" -ne 0 ]
  [ "$(grep -c '^create ' "${DOCKER_LOG}")" -eq 1 ]
  [ "$(grep -c 'trivy:test image' "${DOCKER_LOG}")" -eq 1 ]
  [ "$(grep -c '^rm --volumes ' "${DOCKER_LOG}")" -eq 2 ]
  ! grep -q -- '--skip-db-update' "${DOCKER_LOG}"
  ! grep -q ' convert ' "${DOCKER_LOG}"
  [ -s "${SECURITY_DIR}/cleanup-fail-linux-arm64-raw.json" ]
}
