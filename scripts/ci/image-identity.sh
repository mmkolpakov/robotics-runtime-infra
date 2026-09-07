#!/usr/bin/env bash

# Resolve one Docker image to JSON: reference, digest, kind, config_digest.
# Docker validates repository/tag syntax; jq reads structured inspect data.
# Pinned references must match an actual RepoDigest, including through an alias.
# Tags prefer their own repository; ties and local aliases use lexical ordering
# of RepoDigests so image-store ordering never determines the recorded identity.
#
# Callers explicitly select source or released mode. Released requires a pin and
# never uses .Id as the registry digest. In source mode only, an unpinned image
# without RepoDigests uses its config digest with kind=local-config and a warning.
# The synthetic local-config/image reference preserves development runs through
# emit-runtime-manifest's mandatory reference@digest interface. It is NOT a
# pullable registry identity or release evidence. The current manifest schema
# lacks an identity-kind field; the reference marker keeps this limitation visible
# in the artifact. Permits/build records with only a digest retain this legacy
# source-mode limitation. config_digest separately identifies local execution.
ci_image_identity() {
  local image="$1"
  local mode="$2"
  local requested_digest=
  local inspected
  local identity

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
    --arg mode "${mode}" \
    --arg requested_digest "${requested_digest}" '
      def sha256: type == "string" and test("^sha256:[a-f0-9]{64}$");
      # Strip a tag from the final path component only (registry ports survive).
      # Normalize Dockers familiar Docker Hub names for repository preference.
      def repository:
        split("@")[0] | sub(":[^/:]+$"; "") |
        split("/") |
        if length == 1 then ["docker.io", "library"] + .
        elif (.[0] | test("[.:]") or . == "localhost") then .
        else ["docker.io"] + . end |
        if .[0] == "index.docker.io" then .[0] = "docker.io" else . end |
        if .[0] == "docker.io" and length == 2 then
          [.[0], "library", .[1]] else . end | join("/");
      if length != 1 then error("expected one Docker inspect document") else .[0] end |
      if type != "array" or length != 1 then
        error("expected one inspected Docker image") else .[0] end |
      if (.Id | sha256 | not) then error("invalid Docker config digest") else . end |
      . as $inspected |
      (if .RepoDigests == null then [] else .RepoDigests end) as $digests |
      if ($digests | type) != "array" then error("invalid RepoDigests") else . end |
      if all($digests[]; type == "string" and test("^[^@]+@sha256:[a-f0-9]{64}$"))
        then . else error("malformed RepoDigest") end |
      ($digests | sort | unique) as $digests |
      ($image | repository) as $repository |
      if $requested_digest != "" then
        if any($digests[]; split("@")[1] == $requested_digest) then
          {reference: $image, digest: $requested_digest, kind: "registry"}
        else error("requested digest is absent from inspected RepoDigests") end
      elif ($digests | length) > 0 then
        ([$digests[] | select(repository == $repository)][0] // $digests[0]) as $selected |
        ($selected | split("@")[1]) as $digest |
        {reference: (if ($selected | repository) == $repository then
           $image + "@" + $digest else $selected end), digest: $digest, kind: "registry"}
      elif $mode == "source" then
        {reference: ("local-config/image@" + .Id), digest: .Id, kind: "local-config"}
      else error("released image has no registry digest") end |
      . + {config_digest: $inspected.Id}
    ' <<<"${inspected}")" || return 65
  if [[ "$(jq -r '.kind' <<<"${identity}")" == local-config ]]; then
    printf 'source image %s has no RepoDigests; using local-config identity, not verified registry identity\n' \
      "${image}" >&2
  fi
  printf '%s\n' "${identity}"
}
