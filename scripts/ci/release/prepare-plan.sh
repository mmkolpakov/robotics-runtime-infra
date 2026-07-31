#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

: "${GITHUB_OUTPUT:?GITHUB_OUTPUT is required}"
: "${GITHUB_REF_NAME:?GITHUB_REF_NAME is required}"

environment_map="${1:-config/ci/release-environment.json}"
manifest="${2:-artifacts/release-plan.json}"
version="${GITHUB_REF_NAME#v}"
[[ "${GITHUB_REF_NAME}" =~ ^v[0-9]+\.[0-9]+\.[0-9]+([-.][0-9A-Za-z.-]+)?$ ]]

mkdir -p "$(dirname -- "${manifest}")"
bake_plan="$(mktemp)"
manifest_tmp="$(mktemp "${manifest}.tmp.XXXXXX")"
trap 'rm -f "${bake_plan}" "${manifest_tmp}"' EXIT HUP INT TERM
docker buildx bake --file docker-bake.hcl --print release >"${bake_plan}"

jq -e -n \
  --slurpfile bake "${bake_plan}" \
  --slurpfile environment "${environment_map}" '
    $bake[0].target as $targets |
    $environment[0] as $environment |
    if ($targets | keys | sort) != ($environment | keys | sort)
    then error("release targets and environment mapping differ")
    else
      [
        $targets | to_entries[] |
        (.value.tags // []) as $tags |
        (.value.platforms // []) as $platforms |
        if ($tags | length) != 1 or ($platforms | length) == 0
        then error("release target \(.key) has an invalid Bake definition")
        else
          ($tags[0] | split("/")[-1] | split(":")[0]) as $repository |
          {
            id: $repository,
            target: .key,
            repository: $repository,
            environment_variable: $environment[.key],
            platforms: $platforms
          }
        end
      ] | sort_by(.id) |
      if ([.[].id] | length) != ([.[].id] | unique | length) or
         ([.[].environment_variable] | length) !=
           ([.[].environment_variable] | unique | length) or
         any(.[];
           (.environment_variable |
             test("^[A-Z][A-Z0-9_]+_IMAGE$") | not) or
           any(.platforms[];
             . != "linux/amd64" and . != "linux/arm64"))
      then error("derived release plan is invalid")
      else {schema_version: "release-images.v1", images: .}
      end
    end
  ' >"${manifest_tmp}"
mv "${manifest_tmp}" "${manifest}"

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
