#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"

manifest="${1:-config/ci/release-images.json}"
version="${GITHUB_REF_NAME#v}"
[[ "${GITHUB_REF_NAME}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]

jq -e '
  .schema_version == "release-images.v1" and
  (.images | type == "array" and length > 0) and
  ([.images[].id] | length == (unique | length)) and
  ([.images[].environment_variable] | length == (unique | length)) and
  ([.images[].repository] | length == (unique | length)) and
  all(.images[];
    (.id | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
    (.target | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
    (.repository | test("^[a-z0-9]+(-[a-z0-9]+)*$")) and
    (.environment_variable | test("^[A-Z][A-Z0-9_]+_IMAGE$")) and
    (.platforms | type == "array" and length > 0) and
    all(.platforms[]; . == "linux/amd64" or . == "linux/arm64")
  )
' "${manifest}" >/dev/null

matrix="$(
  jq -c '{
    include: [
      .images[] |
      . + {platforms_csv: (.platforms | join(","))}
    ]
  }' "${manifest}"
)"
{
  printf 'matrix=%s\n' "${matrix}"
  printf 'version=%s\n' "${version}"
} >>"${GITHUB_OUTPUT}"
