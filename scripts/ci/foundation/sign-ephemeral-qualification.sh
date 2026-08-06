#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'
umask 077

usage() {
  cat >&2 <<'EOF'
usage: sign-ephemeral-qualification.sh STATEMENT BUNDLE PUBLIC_KEY
EOF
  exit 64
}

[[ $# -eq 3 ]] || usage
statement="$1"
bundle="$2"
public_key="$3"

command -v cosign >/dev/null 2>&1 || {
  printf 'cosign is required\n' >&2
  exit 69
}
[[ -f "${statement}" && -r "${statement}" && ! -L "${statement}" ]] || {
  printf 'statement is not a readable regular file: %s\n' "${statement}" >&2
  exit 66
}

work="$(mktemp -d)"
cleanup() {
  rm -rf -- "${work}"
}
trap cleanup EXIT HUP INT TERM

export COSIGN_PASSWORD
COSIGN_PASSWORD="$(
  od -An -N32 -tx1 /dev/urandom |
    tr -d ' \n'
)"
cosign generate-key-pair \
  --output-key-prefix "${work}/qualification" >/dev/null
cosign signing-config create \
  --out "${work}/signing-config.json"
cosign trusted-root create \
  --out "${work}/trusted-root.json"
cosign attest-blob --yes \
  --key "${work}/qualification.key" \
  --signing-config "${work}/signing-config.json" \
  --trusted-root "${work}/trusted-root.json" \
  --statement "${statement}" \
  --bundle "${work}/qualification.sigstore.json"

install -D -m 0444 \
  "${work}/qualification.sigstore.json" "${bundle}"
install -D -m 0444 \
  "${work}/qualification.pub" "${public_key}"
