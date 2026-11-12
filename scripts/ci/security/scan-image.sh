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
# Repository-relative ignore policy; the override exists for gate tests.
ignore_file="${ROBOTICS_CI_TRIVY_IGNORE_FILE:-.trivyignore}"
mkdir -p "${security_artifact_dir}" "${trivy_cache_dir}"

trivy=(
  docker run --rm
  --volume /var/run/docker.sock:/var/run/docker.sock
  --volume "${HOME}/.docker:/root/.docker:ro"
  --volume "${PWD}:/work:ro"
  --volume "${security_artifact_dir}:/reports"
  --volume "${trivy_cache_dir}:/root/.cache/trivy"
  "${TRIVY_IMAGE}" image
  --config /work/trivy.yaml
  --ignorefile "/work/${ignore_file}"
  --vex /work/security/vex/linux-libc-dev.openvex.json
  --vex /work/security/vex/go-modules.openvex.json
  --show-suppressed
)

# Gate exceptions are .trivyignore entries that name a review ticket and an
# unexpired exp date. Only Ubuntu OS findings with status=affected may use
# them; trivy itself honours the same file during the scan.
gate_exceptions="$(
  jq -Rn --arg today "$(date -u +%F)" '
    [inputs
      | select(test("^\\s*CVE-[0-9]{4}-[0-9]+\\s*#"))
      | capture("^\\s*(?<cve>CVE-[0-9]{4}-[0-9]+)\\s*#(?<comment>.*)$")
      | select(.comment | test("review:\\s*[^\\s;]+"))
      | select(.comment | test("exp:\\s*[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01])"))
      | select((.comment
          | capture("exp:\\s*(?<exp>[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]))").exp) >= $today)
      | .cve]
  ' "${ignore_file}"
)"

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
  # Reporting stays complete: the SARIF export is never filtered and never
  # decides the gate.
  docker run --rm \
    --volume "${security_artifact_dir}:/reports" \
    "${TRIVY_IMAGE}" convert \
    --format sarif \
    --output "/reports/${report_id}-${platform_id}.sarif" \
    "${raw_report}"
  # The gate reads the raw JSON. HIGH/CRITICAL findings block when a fix
  # exists. Ubuntu OS packages narrowly tolerate will_not_fix/fix_deferred,
  # and affected only with a ticketed, unexpired .trivyignore entry.
  # end_of_life and language packages (Go, Python, Alpine) always block.
  blocking_findings="$(
    jq --argjson exceptions "${gate_exceptions}" '
      [
        .Results[]? as $result
        | ($result.Vulnerabilities[]?
            | select(.Severity == "HIGH" or .Severity == "CRITICAL")) as $finding
        | select(
            if $result.Class == "os" and $result.Type == "ubuntu" then
              ($finding.Status != "will_not_fix" and $finding.Status != "fix_deferred")
              and ($finding.Status != "affected"
                or ($exceptions | index($finding.VulnerabilityID)) == null)
            else true end
          )
        | {
            target: $result.Target,
            id: $finding.VulnerabilityID,
            severity: $finding.Severity,
            status: $finding.Status,
            package: $finding.PkgName
          }
      ]
    ' "${security_artifact_dir}/${report_id}-${platform_id}.json"
  )"
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
