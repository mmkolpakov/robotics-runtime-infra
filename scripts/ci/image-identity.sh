#!/usr/bin/env bash

# Resolve one Docker image to JSON: reference, digest, kind, local_image_id.
# RepoDigests bind the local lookup to a digest but do not prove publication:
# the containerd image store also synthesizes them for unpublished local tags.
# Every pin requires a matching remote descriptor from Buildx imagetools.
# A remote lookup is not a signature/provenance check; callers retain those gates.
#
# Released requires a pin. Unpinned source images stay explicitly local, even
# with RepoDigests, and require no registry access. local_image_id is Docker's
# opaque .Id: a config digest in the classic store, a manifest/index digest in
# the containerd store. It is deliberately not exposed as config_digest.
# The synthetic local-image/image reference preserves development runs through
# emit-runtime-manifest's mandatory reference@digest interface. It is NOT a
# pullable registry identity or release evidence. The current manifest schema
# lacks an identity-kind field; the reference marker keeps this limitation visible
# in the artifact. Permits/build records with only a digest retain this legacy
# source-mode limitation. See docs/supply-chain.md for the identity contract.
ci_image_identity() {
  local image="$1"
  local mode="$2"
  local requested_digest=
  local inspected
  local identity
  local remote_manifest

  case "${mode}" in
    source | released) ;;
    *)
      printf 'unsupported image identity mode: %s\n' "${mode}" >&2
      return 64
      ;;
  esac
  if [[ "${image}" == *@* ]]; then
    requested_digest="${image#*@}"
    if [[ -z "${image%%@*}" ||
      ! "${requested_digest}" =~ ^sha256:[a-f0-9]{64}$ ]]; then
      printf 'malformed digest-pinned image reference: %s\n' "${image}" >&2
      return 65
    fi
  elif [[ "${mode}" == released ]]; then
    printf 'released image identity requires a digest-pinned reference: %s\n' "${image}" >&2
    return 65
  fi

  inspected="$(docker image inspect "${image}")" || return
  identity="$(jq -cse \
    --arg image "${image}" \
    --arg requested_digest "${requested_digest}" '
      def sha256: type == "string" and test("^sha256:[a-f0-9]{64}$");
      if length != 1 then error("expected one Docker inspect document") else .[0] end |
      if type != "array" or length != 1 then
        error("expected one inspected Docker image") else .[0] end |
      if (.Id | sha256 | not) then error("invalid Docker local image ID") else . end |
      . as $inspected |
      (if .RepoDigests == null then [] else .RepoDigests end) as $digests |
      if ($digests | type) != "array" then error("invalid RepoDigests") else . end |
      if all($digests[]; type == "string" and test("^[^@]+@sha256:[a-f0-9]{64}$"))
        then . else error("malformed RepoDigest") end |
      if $requested_digest != "" then
        if any($digests[]; split("@")[1] == $requested_digest) then
          {reference: $image, digest: $requested_digest, kind: "registry"}
        else error("requested digest is absent from inspected RepoDigests") end
      else
        {reference: ("local-image/image@" + .Id), digest: .Id, kind: "local-image-id"}
      end |
      . + {local_image_id: $inspected.Id}
    ' <<<"${inspected}")" || return 65

  if [[ -n "${requested_digest}" ]]; then
    # Inspect the exact requested repository and pin, never an alias or a tag
    # resolved remotely at a different time. Buildx talks to the registry.
    remote_manifest="$(docker buildx imagetools inspect \
      --format '{{json .Manifest}}' "${image}")" || return
    jq -se --arg digest "${requested_digest}" '
      length == 1 and (.[0] |
        type == "object" and .digest == $digest and
        (.mediaType == "application/vnd.oci.image.manifest.v1+json" or
         .mediaType == "application/vnd.oci.image.index.v1+json" or
         .mediaType == "application/vnd.docker.distribution.manifest.v2+json" or
         .mediaType == "application/vnd.docker.distribution.manifest.list.v2+json"))
    ' <<<"${remote_manifest}" >/dev/null || {
      printf 'registry manifest does not match the requested image pin: %s\n' "${image}" >&2
      return 65
    }
  else
    printf 'source image %s uses a local-image-id identity, not verified registry identity\n' \
      "${image}" >&2
  fi
  printf '%s\n' "${identity}"
}
