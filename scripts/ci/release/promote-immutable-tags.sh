#!/usr/bin/env bash
set -Eeuo pipefail

test "$#" -ge 5 || {
  printf 'usage: promote-immutable-tags.sh check|promote IMAGE DIGEST METADATA|- TAG...\n' >&2
  exit 64
}

mode="$1"
image="$2"
digest="$3"
metadata="$4"
shift 4
tags=("$@")

case "${mode}" in
  check | promote) ;;
  *) exit 64 ;;
esac
[[ "${image}" =~ ^ghcr\.io/[a-z0-9._-]+/[a-z0-9._/-]+$ ]]
[[ "${digest}" =~ ^sha256:[a-f0-9]{64}$ ]]
test "${#tags[@]}" -gt 0
for tag in "${tags[@]}"; do
  [[ "${tag}" == "${image}:"* ]]
done

work="$(mktemp -d)"
trap 'rm -rf -- "${work}"' EXIT HUP INT TERM

inspect_digest() {
  local reference="$1"
  local output="$2"
  local error="$3"
  local status

  set +e
  docker buildx imagetools inspect \
    --format '{{json .Manifest}}' \
    "${reference}" >"${output}" 2>"${error}"
  status=$?
  set -e
  if test "${status}" -eq 0; then
    jq -er '.digest' "${output}"
    return 0
  fi
  if grep -Eiq \
    '(manifest unknown|name unknown|manifest[^[:space:]]* not found)' \
    "${error}"; then
    return 1
  fi
  cat "${error}" >&2
  printf 'registry state could not be determined for %s\n' \
    "${reference}" >&2
  return 70
}

missing=()
index=0
for tag in "${tags[@]}"; do
  actual=
  status=0
  actual="$(
    inspect_digest \
      "${tag}" \
      "${work}/inspect-${index}.json" \
      "${work}/inspect-${index}.err"
  )" || status=$?
  case "${status}" in
    0)
      test "${actual}" = "${digest}" || {
        printf 'refusing to overwrite immutable tag %s (%s != %s)\n' \
          "${tag}" "${actual}" "${digest}" >&2
        exit 73
      }
      ;;
    1)
      missing+=("${tag}")
      ;;
    *)
      exit "${status}"
      ;;
  esac
  index=$((index + 1))
done

if test "${mode}" = check; then
  exit 0
fi

if test "${#missing[@]}" -ne 0; then
  command=(docker buildx imagetools create)
  for tag in "${missing[@]}"; do
    command+=(--tag "${tag}")
  done
  if test "${metadata}" != -; then
    mkdir -p "$(dirname -- "${metadata}")"
    command+=(--metadata-file "${metadata}")
  fi
  command+=("${image}@${digest}")
  "${command[@]}"
elif test "${metadata}" != -; then
  mkdir -p "$(dirname -- "${metadata}")"
  jq -n \
    --arg digest "${digest}" \
    --arg image "${image}" \
    --argjson tags "$(printf '%s\n' "${tags[@]}" | jq -R . | jq -s .)" '
      {
        schema_version: "oci-tag-promotion.v1",
        image: $image,
        digest: $digest,
        tags: $tags,
        status: "already_present"
      }
    ' >"${metadata}"
fi

index=0
for tag in "${tags[@]}"; do
  actual="$(
    inspect_digest \
      "${tag}" \
      "${work}/verify-${index}.json" \
      "${work}/verify-${index}.err"
  )"
  test "${actual}" = "${digest}"
  index=$((index + 1))
done
