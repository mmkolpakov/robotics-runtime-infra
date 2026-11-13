#!/usr/bin/env bash
set -Eeuo pipefail

# Derive and classify the image-input watch list for the conditional
# ci-supply-chain gate. The committed manifest config/ci/image-inputs.txt is
# generated from the named bake contexts and the COPY/ADD sources of every
# Dockerfile that docker-bake.hcl references. test/ci/supply-chain-decouple.bats
# fails when the manifest drifts from the derivation, so a new COPY source
# cannot silently escape the gate.

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

manifest="config/ci/image-inputs.txt"
bake="docker-bake.hcl"

usage() {
  printf 'usage: image-inputs.sh list|check|classify [--github-output]\n' >&2
  exit 64
}

# Emit "name<TAB>default" for every variable default in the bake definition.
bake_variable_defaults() {
  awk '
    /^variable[[:space:]]+"/ {
      name = $2
      gsub(/"/, "", name)
      pending = 1
      next
    }
    pending && /^[[:space:]]*default[[:space:]]*=/ {
      value = $0
      sub(/^[[:space:]]*default[[:space:]]*=[[:space:]]*/, "", value)
      gsub(/^"|"$/, "", value)
      printf "%s\t%s\n", name, value
      pending = 0
    }
  ' "${bake}"
}

# Emit "name<TAB>value" for every named bake context. Values are either quoted
# literals or bake variables resolved through bake_variable_defaults.
bake_contexts() {
  awk '
    /contexts[[:space:]]*=[[:space:]]*\{/ { in_contexts = 1 }
    in_contexts {
      line = $0
      while (match(line, /"[A-Za-z0-9_-]+"[[:space:]]*=[[:space:]]*("[^"]*"|[A-Za-z_][A-Za-z0-9_]*)/)) {
        pair = substr(line, RSTART, RLENGTH)
        line = substr(line, RSTART + RLENGTH)
        eq = index(pair, "=")
        key = substr(pair, 1, eq - 1)
        value = substr(pair, eq + 1)
        gsub(/[[:space:]]/, "", key)
        gsub(/"/, "", key)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", value)
        printf "%s\t%s\n", key, value
      }
      if ($0 ~ /\}/) { in_contexts = 0 }
    }
  ' "${bake}"
}

# Emit the stage names declared by a Dockerfile.
dockerfile_stages() {
  awk '
    /^FROM[[:space:]]/ {
      n = split($0, tok, /[[:space:]]+/)
      for (i = 1; i < n; i++) {
        if (tok[i] == "AS" || tok[i] == "as") { print tok[i + 1] }
      }
    }
  ' "$1"
}

# Emit "CTX<TAB>name" for COPY/ADD --from references and "SRC<TAB>path" for
# build-context sources. Continuation lines are joined first. Remote ADD URLs
# are checksum-pinned in the Dockerfile and are not local watch paths.
dockerfile_sources() {
  awk '
    {
      line = $0
      sub(/\r$/, "", line)
      if (continued) { buffer = buffer " " line } else { buffer = line }
      if (buffer ~ /\\$/) {
        sub(/\\$/, "", buffer)
        continued = 1
        next
      }
      continued = 0
      if (buffer !~ /^(COPY|ADD)[[:space:]]/) { buffer = ""; next }
      n = split(buffer, tok, /[[:space:]]+/)
      from = ""
      count = 0
      for (i = 2; i <= n; i++) {
        t = tok[i]
        if (t ~ /^--from=/) { from = substr(t, 8); continue }
        if (t ~ /^--/) { continue }
        args[++count] = t
      }
      if (from != "") {
        printf "CTX\t%s\n", from
        buffer = ""
        next
      }
      for (i = 1; i < count; i++) {
        if (args[i] ~ /^https?:\/\//) { continue }
        printf "SRC\t%s\n", args[i]
      }
      buffer = ""
    }
  ' "$1"
}

# Watch a directory recursively, a file exactly. Generated contexts such as
# host/.tools/host-asset do not exist at derivation time and are directories.
emit_path() {
  local path="$1"
  path="${path%/}"
  test -n "${path}" || return 0
  if test -d "${path}"; then
    printf '%s/*\n' "${path}"
  elif test -e "${path}"; then
    printf '%s\n' "${path}"
  else
    printf '%s/*\n' "${path}"
  fi
}

resolve_context_value() {
  local value="$1" default
  if [[ "${value}" == \"*\" ]]; then
    printf '%s\n' "${value:1:${#value}-2}"
    return 0
  fi
  default="$(awk -F'\t' -v name="${value}" '$1 == name { print $2; exit }' <<<"${variable_defaults}")"
  if test -z "${default}"; then
    printf 'unresolved bake context variable: %s\n' "${value}" >&2
    return 1
  fi
  printf '%s\n' "${default}"
}

context_value() {
  local name="$1" value
  value="$(awk -F'\t' -v name="${name}" '$1 == name { print $2; exit }' <<<"${contexts}")"
  if test -z "${value}"; then
    printf 'unknown bake context reference: %s\n' "${name}" >&2
    return 1
  fi
  resolve_context_value "${value}"
}

derive() {
  variable_defaults="$(bake_variable_defaults)"
  contexts="$(bake_contexts)"
  local fixed=(
    .dockerignore
    .trivyignore
    Dockerfile
    docker-bake.hcl
    'docker/*'
    'security/*'
    trivy.yaml
    config/foundation-lock.json
    config/ros-cohort-source.lock.json
    foundation.repos
    host/source-lock.json
    # Foundation qualification runs against these consumer projects.
    'examples/minimal-consumer/*'
    'examples/neutral-robot/*'
  )
  printf '%s\n' "${fixed[@]}"

  # Local named contexts are image inputs. Remote contexts are git pins that
  # live in docker-bake.hcl, which is watched itself; target: references are
  # covered through the Dockerfile sources.
  local name value resolved
  while IFS=$'\t' read -r name value; do
    resolved="$(resolve_context_value "${value}")" || return 1
    case "${resolved}" in
      target:* | http://* | https://* | git::*) continue ;;
    esac
    emit_path "${resolved}"
  done < <(printf '%s\n' "${contexts}")

  local dockerfile kind path stages
  while IFS= read -r dockerfile; do
    if ! test -f "${dockerfile}"; then
      printf 'missing bake dockerfile: %s\n' "${dockerfile}" >&2
      return 1
    fi
    stages="$(dockerfile_stages "${dockerfile}")"
    while IFS=$'\t' read -r kind path; do
      if test "${kind}" = CTX; then
        if grep -Fxq "${path}" <<<"${stages}"; then
          continue
        fi
        resolved="$(context_value "${path}")" || return 1
        case "${resolved}" in
          target:* | http://* | https://* | git::*) continue ;;
        esac
        emit_path "${resolved}"
      else
        emit_path "${path}"
      fi
    done < <(dockerfile_sources "${dockerfile}")
  done < <(sed -n 's/^[[:space:]]*dockerfile[[:space:]]*=[[:space:]]*"\([^"]*\)".*/\1/p' "${bake}" | sort -u)
}

classify() {
  local github_output=0
  if test "${1:-}" = --github-output; then
    github_output=1
    shift
  fi
  test "$#" -eq 0 || usage
  if ! test -f "${manifest}"; then
    printf 'missing image-input manifest: %s\n' "${manifest}" >&2
    exit 65
  fi
  local -a patterns=()
  mapfile -t patterns <"${manifest}"
  local affected=false path pattern
  while IFS= read -r path; do
    test -n "${path}" || continue
    for pattern in "${patterns[@]}"; do
      test -n "${pattern}" || continue
      # Unquoted on purpose: manifest patterns are globs and * spans /.
      # shellcheck disable=SC2053
      if [[ "${path}" == ${pattern} ]]; then
        affected=true
        break 2
      fi
    done
  done
  if test "${github_output}" = 1; then
    : "${GITHUB_OUTPUT:?GITHUB_OUTPUT must identify the GitHub Actions output file}"
    printf 'affected=%s\n' "${affected}" >>"${GITHUB_OUTPUT}"
  fi
  printf '%s\n' "${affected}"
}

check() {
  local derived
  derived="$(derive | sort -u)"
  if ! diff -u "${manifest}" <(printf '%s\n' "${derived}"); then
    printf 'image-input manifest is stale; regenerate with: scripts/ci/supply-chain/image-inputs.sh list > %s\n' "${manifest}" >&2
    exit 1
  fi
}

case "${1:-}" in
  list)
    shift
    test "$#" -eq 0 || usage
    derive | sort -u
    ;;
  check)
    shift
    test "$#" -eq 0 || usage
    check
    ;;
  classify)
    shift
    classify "$@"
    ;;
  *) usage ;;
esac
