#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

test "$#" -eq 4 || {
  printf 'usage: promote-candidates.sh MANIFEST CANDIDATE_DIR VERSION OUTPUT_DIR\n' >&2
  exit 64
}

manifest="$1"
candidate_dir="$2"
version="$3"
output_dir="$4"

[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]
[[ "${GITHUB_SHA:?GITHUB_SHA is required}" =~ ^[a-f0-9]{40}$ ]]
[[ "${GITHUB_REF:?GITHUB_REF is required}" =~ ^refs/tags/v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]
short_sha="${GITHUB_SHA:0:12}"
test -d "${candidate_dir}"

expected_ids="$(jq -r '.images[].id' "${manifest}" | LC_ALL=C sort)"
actual_ids="$(
  find "${candidate_dir}" -maxdepth 1 -type f -name '*.json' \
    -printf '%f\n' |
    sed 's/\.json$//' |
    LC_ALL=C sort
)"
test "${actual_ids}" = "${expected_ids}" || {
  printf 'release candidate set does not match the manifest\n' >&2
  diff -u <(printf '%s\n' "${expected_ids}") <(printf '%s\n' "${actual_ids}") >&2
  exit 65
}

mkdir -p "${output_dir}/digests" "${output_dir}/promotion"
{
  printf 'ROBOTICS_RUNTIME_MODE=released\n'
  printf 'ROBOTICS_RELEASE_SOURCE_SHA=%s\n' "${GITHUB_SHA}"
  printf 'ROBOTICS_RELEASE_SOURCE_REF=%s\n' "${GITHUB_REF}"
} >"${output_dir}/release.env"
: >"${output_dir}/release-notes.md"
: >"${output_dir}/promotion/plan.jsonl"
{
  printf '## OCI images\n\n'
  printf 'Every reference below was promoted after the source revision passed CI and every candidate passed build, vulnerability, and attestation gates. The simulation candidate additionally passed its packaged runtime smoke test.\n\n'
} >>"${output_dir}/release-notes.md"

while IFS= read -r row; do
  id="$(jq -r '.id' <<<"${row}")"
  repository="$(jq -r '.repository' <<<"${row}")"
  environment_variable="$(jq -r '.environment_variable' <<<"${row}")"
  platforms="$(jq -c '.platforms' <<<"${row}")"
  record="${candidate_dir}/${id}.json"
  image="ghcr.io/${GITHUB_REPOSITORY_OWNER,,}/robotics-runtime-infra/${repository}"

  jq -e \
    --arg environment_variable "${environment_variable}" \
    --arg id "${id}" \
    --arg image "${image}" \
    --argjson platforms "${platforms}" '
      .schema_version == "release-candidate.v1" and
      .id == $id and
      .environment_variable == $environment_variable and
      .image == $image and
      .platforms == $platforms and
      (.digest | test("^sha256:[a-f0-9]{64}$"))
    ' "${record}" >/dev/null
  digest="$(jq -r '.digest' "${record}")"

  jq -cn \
    --arg digest "${digest}" \
    --arg environment_variable "${environment_variable}" \
    --arg id "${id}" \
    --arg image "${image}" \
    --arg repository "${repository}" \
    --arg version "${version}" \
    --arg sha_tag "sha-${short_sha}" '
      {
        id: $id,
        repository: $repository,
        environment_variable: $environment_variable,
        image: $image,
        digest: $digest,
        version: $version,
        tags: [
          ($image + ":" + $version),
          ($image + ":" + $sha_tag)
        ]
      }
    ' >>"${output_dir}/promotion/plan.jsonl"
done < <(jq -c '.images[]' "${manifest}")

while IFS= read -r row; do
  mapfile -t tags < <(jq -r '.tags[]' <<<"${row}")
  scripts/ci/release/promote-immutable-tags.sh \
    check \
    "$(jq -r '.image' <<<"${row}")" \
    "$(jq -r '.digest' <<<"${row}")" \
    - \
    "${tags[@]}"
done <"${output_dir}/promotion/plan.jsonl"

while IFS= read -r row; do
  id="$(jq -r '.id' <<<"${row}")"
  environment_variable="$(jq -r '.environment_variable' <<<"${row}")"
  image="$(jq -r '.image' <<<"${row}")"
  digest="$(jq -r '.digest' <<<"${row}")"
  mapfile -t tags < <(jq -r '.tags[]' <<<"${row}")
  scripts/ci/release/promote-immutable-tags.sh \
    promote \
    "${image}" \
    "${digest}" \
    "${output_dir}/promotion/${id}.json" \
    "${tags[@]}"
  printf '%s=%s:%s@%s\n' \
    "${environment_variable}" "${image}" "${version}" "${digest}" \
    >>"${output_dir}/release.env"
  printf '%s:%s@%s\n' "${image}" "${version}" "${digest}" \
    >"${output_dir}/digests/${id}.txt"
  printf -- "- \`%s:%s@%s\`\n" "${image}" "${version}" "${digest}" \
    >>"${output_dir}/release-notes.md"
done <"${output_dir}/promotion/plan.jsonl"

{
  printf '\n'
  printf 'Each image includes BuildKit provenance and an SBOM and has a GitHub artifact attestation.\n'
  printf "The attached \`release.env\` is the canonical immutable Compose runtime lock.\n"
} >>"${output_dir}/release-notes.md"
