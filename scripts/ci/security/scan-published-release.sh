#!/usr/bin/env bash
set -Eeuo pipefail

# Scan the published release digests with the reviewed Trivy and OpenVEX
# policy. Used by the nightly and post-merge security gate; it never rebuilds
# an image and never accepts a mutable tag.

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

test "$#" -eq 2 || {
  printf 'usage: scan-published-release.sh RELEASE_ENV DIGESTS_DIR\n' >&2
  exit 64
}

release_env="$1"
digests_dir="$2"
test -f "${release_env}"
test -d "${digests_dir}"

: "${TRIVY_IMAGE:?TRIVY_IMAGE is required}"

failed=()
while IFS='=' read -r variable reference; do
  case "${variable}" in
    *_IMAGE) ;;
    *) continue ;;
  esac
  if [[ ! "${reference}" =~ @sha256:[a-f0-9]{64}$ ]]; then
    printf 'unpinned published reference: %s\n' "${reference}" >&2
    exit 65
  fi
  id="$(basename -- "${reference%%@*}")"
  id="${id%%:*}"
  if [[ "${reference}" == ghcr.io/*/robotics-runtime-infra/* ]]; then
    if ! grep -Fxq "${reference}" "${digests_dir}/${id}.txt"; then
      printf 'digest record does not match the release lock: %s\n' "${id}" >&2
      exit 65
    fi
    if ! inspection="$(docker buildx imagetools inspect \
      --format '{"manifest":{{json .Manifest}},"image":{{json .Image}}}' "${reference}")"; then
      printf 'cannot inspect published image: %s\n' "${reference}" >&2
      exit 65
    fi
    # Buildx config maps omit reference descriptors and collapse duplicate platforms.
    platforms="$(jq -ser --arg digest "${reference##*@}" '
      def image_manifest:
        .mediaType == "application/vnd.oci.image.manifest.v1+json" or
        .mediaType == "application/vnd.docker.distribution.manifest.v2+json";
      def platform_name:
        if type == "object" and .os == "linux" and
          (.architecture == "amd64" or .architecture == "arm64") and
          (.variant // "") == ""
        then "linux/" + .architecture
        else error("unsupported or missing runtime platform") end;
      def sha256_digest: type == "string" and test("^sha256:[a-f0-9]{64}$");

      if length != 1 then error("expected one inspect result") else .[0] end |
      .manifest as $manifest |
      if $manifest.digest != $digest then error("published digest mismatch") else . end |
      (.image |
        if type != "object" then error("missing image configs")
        elif has("architecture") then [platform_name]
        else [to_entries[] | .key as $key | .value | platform_name |
          if . == $key then . else error("image config platform mismatch") end]
        end) as $platforms |
      if ($platforms | length) == 0 or
        ($platforms | unique | length) != ($platforms | length)
      then error("empty or duplicate runtime platforms") else . end |

      if $manifest | image_manifest then
        if ($platforms | length) != 1 then error("ambiguous single image")
        else $platforms end
      elif $manifest.mediaType == "application/vnd.oci.image.index.v1+json" or
        $manifest.mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"
      then
        $manifest.manifests |
        if type != "array" or length == 0 then error("missing index descriptors") else . end |
        . as $descriptors |
        map(select(.annotations["vnd.docker.reference.type"] != "attestation-manifest")) as $runtime |
        [$runtime[].platform | platform_name] as $declared |
        [$runtime[].digest] as $runtime_digests |
        if ($declared | sort) != ($platforms | sort) or
          ($descriptors | map(.digest) | unique | length) != ($descriptors | length)
        then error("index does not match image configs") else . end |
        if all($descriptors[];
          image_manifest and (.digest | sha256_digest) and
          (if .annotations["vnd.docker.reference.type"] == "attestation-manifest" then
            .platform.os == "unknown" and .platform.architecture == "unknown" and
            (.annotations["vnd.docker.reference.digest"] as $ref |
              ($runtime_digests | index($ref) != null) and
              (.annotations["com.docker.reference.digest"] // $ref) == $ref)
          else
            (.annotations["vnd.docker.reference.digest"] // null) == null and
            (.annotations["com.docker.reference.digest"] // null) == null
          end))
        then $platforms else error("invalid runtime or attestation descriptor") end
      else error("unsupported published manifest type") end |
      sort | join(",")
    ' <<<"${inspection}")" || {
      printf 'invalid published image platforms: %s\n' "${reference}" >&2
      exit 65
    }
  else
    platforms="linux/amd64,linux/arm64"
  fi
  if ! scripts/ci/security/scan-image.sh "${reference}" "published-${id}" "${platforms}"; then
    failed+=("${reference}")
  fi
done <"${release_env}"

if test "${#failed[@]}" -gt 0; then
  printf 'published image security gate failed for %s\n' "${failed[@]}" >&2
  exit 1
fi
