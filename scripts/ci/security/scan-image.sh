#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

test "$#" -ge 2 || {
  printf 'usage: scan-image.sh IMAGE REPORT_ID [PLATFORM_OR_CSV...]\n' >&2
  exit 64
}

image="$1"
report_id="$2"
shift 2
platform_inputs=("$@")
platforms=()

: "${TRIVY_IMAGE:?TRIVY_IMAGE is required}"
[[ "${report_id}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
if test "${#platform_inputs[@]}" -eq 0; then
  platforms=("")
else
  for platform_input in "${platform_inputs[@]}"; do
    IFS=',' read -r -a parsed_platforms <<<"${platform_input}"
    test "${#parsed_platforms[@]}" -gt 0
    for platform in "${parsed_platforms[@]}"; do
      test -n "${platform}"
      platforms+=("${platform}")
    done
  done
fi

security_artifact_dir="${ROBOTICS_CI_SECURITY_ARTIFACT_DIR:-${PWD}/artifacts/security}"
trivy_cache_dir="${ROBOTICS_CI_TRIVY_CACHE_DIR:-${PWD}/.trivy-cache}"
# Repository-relative ignore policy. The override exists for gate tests and
# must stay inside the repository: the scan mounts ${PWD} at /work.
ignore_file="${ROBOTICS_CI_TRIVY_IGNORE_FILE:-.trivyignore}"
case "${ignore_file}" in
  /*)
    printf 'ignore file must be repository-relative: %s\n' "${ignore_file}" >&2
    exit 64
    ;;
esac
IFS='/' read -r -a ignore_parts <<<"${ignore_file}"
for ignore_part in "${ignore_parts[@]}"; do
  if test "${ignore_part}" = ".."; then
    printf 'ignore file must not leave the repository: %s\n' "${ignore_file}" >&2
    exit 64
  fi
done
test -f "${ignore_file}" || {
  printf 'ignore file not found: %s\n' "${ignore_file}" >&2
  exit 66
}
mkdir -p "${security_artifact_dir}" "${trivy_cache_dir}"

# jq is the only exception authority: trivy never reads the ignore policy.
# The lint step fails the gate on malformed, expired or over-aged entries
# before any scan runs, and prints the accepted exceptions as JSON.
gate_exceptions="$(scripts/ci/security/lint-trivyignore.sh "${ignore_file}")"

trivy=(
  docker run --rm
  --volume /var/run/docker.sock:/var/run/docker.sock
  --volume "${HOME}/.docker:/root/.docker:ro"
  --volume "${PWD}:/work:ro"
  --volume "${security_artifact_dir}:/reports"
  --volume "${trivy_cache_dir}:/root/.cache/trivy"
  "${TRIVY_IMAGE}" image
  --config /work/trivy.yaml
  --vex /work/security/vex/linux-libc-dev.openvex.json
  --vex /work/security/vex/go-modules.openvex.json
  --show-suppressed
)

failed=()
for platform in "${platforms[@]}"; do
  platform_args=()
  platform_id=local
  if test -n "${platform}"; then
    case "${platform}" in
      linux/amd64 | linux/arm64) ;;
      *)
        printf 'unsupported scan platform: %s\n' "${platform}" >&2
        exit 65
        ;;
    esac
    platform_args=(--platform "${platform}")
    platform_id="${platform//\//-}"
  fi
  raw_report="/reports/${report_id}-${platform_id}.json"
  "${trivy[@]}" \
    "${platform_args[@]}" \
    --format json \
    --output "${raw_report}" \
    "${image}"
  # Reporting stays complete: the SARIF export keeps every unsuppressed
  # finding and never decides the gate. VEX-suppressed findings stay visible
  # in the raw JSON as ExperimentalModifiedFindings records.
  docker run --rm \
    --volume "${security_artifact_dir}:/reports" \
    "${TRIVY_IMAGE}" convert \
    --format sarif \
    --output "/reports/${report_id}-${platform_id}.sarif" \
    "${raw_report}"
  # The gate reads the raw JSON. HIGH/CRITICAL findings block when a fix
  # exists. Ubuntu OS packages (Class=os-pkgs, Type=ubuntu) narrowly tolerate
  # will_not_fix/fix_deferred; a CRITICAL will_not_fix or an affected finding
  # passes only with a ticketed, unexpired, package/target-scoped exception.
  # The header-only package linux-libc-dev is tolerated only at HIGH for
  # affected/will_not_fix/fix_deferred (ADR 0011); its CRITICAL and fixed
  # findings block. Every other status (including unknown, under_investigation
  # and missing) blocks. Non-Ubuntu OS ecosystems such as Alpine and all
  # language packages (Go, Python, ...) always block.
  gate_decision="$(
    jq --argjson exceptions "${gate_exceptions}" '
      def excepted($finding; $target):
        any($exceptions[];
          .cve == $finding.VulnerabilityID
          and .pkg == $finding.PkgName
          and .target == $target);
      def header_only($finding; $result):
        $result.Class == "os-pkgs" and $result.Type == "ubuntu"
        and $finding.PkgName == "linux-libc-dev";
      [
        .Results[]? as $result
        | ($result.Vulnerabilities[]?
            | select(.Severity == "HIGH" or .Severity == "CRITICAL")) as $finding
        | (excepted($finding; $result.Target)) as $excepted
        | (
            if header_only($finding; $result) then
              ($finding.Severity == "HIGH"
                and ($finding.Status == "affected"
                  or $finding.Status == "will_not_fix"
                  or $finding.Status == "fix_deferred"))
            elif $result.Class == "os-pkgs" and $result.Type == "ubuntu" then
              ($finding.Status == "fix_deferred")
              or ($finding.Status == "will_not_fix"
                and ($finding.Severity == "HIGH" or $excepted))
              or ($finding.Status == "affected" and $excepted)
            else false end
          ) as $tolerated
        | {
            target: $result.Target,
            id: $finding.VulnerabilityID,
            severity: $finding.Severity,
            status: ($finding.Status // "missing"),
            package: $finding.PkgName,
            excepted: $excepted,
            header_only: (header_only($finding; $result) and $tolerated),
            tolerated: $tolerated
          }
      ]
      | {
          blocking: [.[] | select(.tolerated | not)],
          tolerated: [.[] | select(.tolerated)]
        }
    ' "${security_artifact_dir}/${report_id}-${platform_id}.json"
  )"
  blocking_findings="$(jq '.blocking' <<<"${gate_decision}")"
  tolerated_findings="$(jq '.tolerated' <<<"${gate_decision}")"
  if test "$(jq 'length' <<<"${tolerated_findings}")" -gt 0; then
    # Tolerated findings stay visible: stdout locally, job summary in CI.
    jq -r '.[] | "tolerated: \(.id) \(.severity) \(.status) \(.package) (\(.target))"
      + (if .header_only then " [header-only: ADR 0011]" else "" end)' \
      <<<"${tolerated_findings}"
    if test -n "${GITHUB_STEP_SUMMARY:-}"; then
      {
        printf '### Tolerated Ubuntu findings: %s (%s)\n\n' "${image}" "${platform_id}"
        printf '| CVE | Severity | Status | Package | Target | Review |\n'
        printf '| --- | --- | --- | --- | --- | --- |\n'
        jq -r --argjson exceptions "${gate_exceptions}" '
          .[]
          | . as $finding
          | (if .header_only then "header-only (ADR 0011)"
            elif .excepted then
              ([$exceptions[]
                | select(.cve == $finding.id
                  and .pkg == $finding.package
                  and .target == $finding.target)][0].review // "yes")
            else "no" end) as $review
          | "| \(.id) | \(.severity) | \(.status) | \(.package) | \(.target) | \($review) |"
        ' <<<"${tolerated_findings}"
        printf '\n'
      } >>"${GITHUB_STEP_SUMMARY}"
    fi
  fi
  if test "$(jq 'length' <<<"${blocking_findings}")" -gt 0; then
    failed+=("${image} ${platform_id}")
    # Print the blocking findings; the reports stay in the artifact.
    jq -r '.[] | "blocking: \(.id) \(.severity) \(.status) \(.package) (\(.target))"' \
      <<<"${blocking_findings}" >&2
    docker run --rm \
      --volume "${security_artifact_dir}:/reports" \
      "${TRIVY_IMAGE}" convert \
      --format table \
      --severity HIGH,CRITICAL \
      "${raw_report}" || true
  fi
done

if test "${#failed[@]}" -gt 0; then
  printf 'vulnerability gate failed: %s\n' "${failed[@]}" >&2
  exit 1
fi
