#!/usr/bin/env bats

setup() {
  MODULE="${BATS_TEST_DIRNAME}/../../scripts/ci/physical-attach/devices.sh"
  export work_root="${BATS_TEST_TMPDIR}/work"
  mkdir -p "${work_root}"
  export ROBOTICS_RELEASE_SOURCE_SHA=aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa
  export ROBOTICS_RELEASE_SOURCE_REF=refs/tags/v0.8.0
  export PERMIT_PREFLIGHT_IMAGE="ghcr.io/mmkolpakov/robotics-runtime-infra/permit-preflight@sha256:$(printf '%064d' 1)"
  export GH_TOKEN=fixture-token
}

@test "released provenance retains caller umask and evidence path" {
  run bash -c '
    set -Eeuo pipefail
    source "$1"
    gh() { printf "[{\"verified\":true}]\n"; }
    umask 022
    verify_released_verifier_provenance
    test "$(umask)" = 0022
    test "${ROBOTICS_VERIFIER_PROVENANCE_EVIDENCE}" = "${work_root}/verifier-attestation.json"
    test "$(stat -c %a "${ROBOTICS_VERIFIER_PROVENANCE_EVIDENCE}")" = 444
    printf permit >"${work_root}/permit.json"
    test "$(stat -c %a "${work_root}/permit.json")" = 644
  ' _ "${MODULE}"
  [ "${status}" -eq 0 ]
}

@test "failed provenance preserves umask and cannot publish partial evidence" {
  run bash -c '
    set -Eeuo pipefail
    source "$1"
    gh() { printf "[{\"partial\":true}]\n"; return 23; }
    umask 027
    if verify_released_verifier_provenance; then
      exit 1
    else
      test "$?" -eq 23
    fi
    test "$(umask)" = 0027
    test ! -e "${work_root}/verifier-attestation.json"
    test ! -e "${work_root}/verifier-attestation.json.tmp"
  ' _ "${MODULE}"
  [ "${status}" -eq 0 ]
}

@test "empty provenance preserves umask and is rejected" {
  run bash -c '
    set -Eeuo pipefail
    source "$1"
    gh() { printf "[]\n"; }
    umask 022
    if verify_released_verifier_provenance; then
      exit 1
    else
      test "$?" -eq 65
    fi
    test "$(umask)" = 0022
    test ! -e "${work_root}/verifier-attestation.json"
    test ! -e "${work_root}/verifier-attestation.json.tmp"
  ' _ "${MODULE}"
  [ "${status}" -eq 0 ]
}
