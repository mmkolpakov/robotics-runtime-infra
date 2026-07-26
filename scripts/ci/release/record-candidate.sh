#!/usr/bin/env bash
set -Eeuo pipefail

test "$#" -eq 6 || {
  printf 'usage: record-candidate.sh ID ENVIRONMENT_VARIABLE IMAGE DIGEST PLATFORMS OUTPUT\n' >&2
  exit 64
}

id="$1"
environment_variable="$2"
image="$3"
digest="$4"
platforms_csv="$5"
output="$6"

[[ "${id}" =~ ^[a-z0-9]+(-[a-z0-9]+)*$ ]]
[[ "${environment_variable}" =~ ^[A-Z][A-Z0-9_]+_IMAGE$ ]]
[[ "${image}" =~ ^ghcr\.io/[a-z0-9._-]+/[a-z0-9._/-]+$ ]]
[[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]

IFS=, read -r -a platforms <<<"${platforms_csv}"
test "${#platforms[@]}" -gt 0
for platform in "${platforms[@]}"; do
  case "${platform}" in
    linux/amd64 | linux/arm64) ;;
    *)
      printf 'unsupported release platform: %s\n' "${platform}" >&2
      exit 65
      ;;
  esac
done

mkdir -p "$(dirname -- "${output}")"
jq -n \
  --arg digest "${digest}" \
  --arg environment_variable "${environment_variable}" \
  --arg id "${id}" \
  --arg image "${image}" \
  --arg platforms_csv "${platforms_csv}" '
    {
      schema_version: "release-candidate.v1",
      id: $id,
      environment_variable: $environment_variable,
      image: $image,
      digest: $digest,
      platforms: ($platforms_csv | split(","))
    }
  ' >"${output}"
