#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

# Validate the .trivyignore exception policy and print the accepted entries
# as a JSON array on stdout. jq is the only exception authority: the image
# gate consumes this output and CI runs the same script as a lint step.
# Malformed, expired or over-aged entries fail with a non-zero exit.
#
# Entry grammar (one finding per line, scoped to a package and a target):
# CVE-YYYY-NNNN #reason:<text>;pkg:<name>;target:<target>;review:<ticket>;exp:YYYY-MM-DD
# - review ticket: #<number> or <PROJECT>-<number>
# - exp: a real calendar date, strictly after today and at most 90 days ahead
# - no whitespace after the field colons; fields appear in the fixed order

ignore_file="${1:-.trivyignore}"
test -f "${ignore_file}" || {
  printf 'ignore policy not found: %s\n' "${ignore_file}" >&2
  exit 66
}

policy="$(
  jq -Rn --arg today "$(date -u +%F)" '
    def trim: sub("^\\s+"; "") | sub("\\s+$"; "");
    def entry:
      capture("^\\s*(?<cve>CVE-[0-9]{4}-[0-9]+)\\s*#\\s*reason:(?<reason>[^;]+);pkg:(?<pkg>[^;\\s]+);target:(?<target>[^;]+);review:(?<review>#[0-9]+|[A-Z]+-[0-9]+);exp:(?<exp>[0-9]{4}-(0[1-9]|1[0-2])-(0[1-9]|[12][0-9]|3[01]))\\s*$");
    def calendar($d):
      (($d + "T00:00:00Z") | fromdateiso8601 | strftime("%Y-%m-%d")) == $d;
    [ inputs
      | select(test("^\\s*(#|$)") | not)
      | . as $line
      | [try entry catch null] as $parsed
      | ($parsed[0] // null) as $e
      | if $e == null then
          {invalid: $line, why: "malformed entry"}
        elif ($e.reason | trim) == "" then
          {invalid: $line, why: "empty reason"}
        elif ($e.target | trim) == "" then
          {invalid: $line, why: "empty target"}
        elif (calendar($e.exp) | not) then
          {invalid: $line, why: "exp is not a real calendar date"}
        elif $e.exp <= $today then
          {invalid: $line, why: "exp must be strictly after today (\($today))"}
        elif (($e.exp + "T00:00:00Z") | fromdateiso8601)
            > ((($today + "T00:00:00Z") | fromdateiso8601) + 90 * 86400) then
          {invalid: $line, why: "exp is more than 90 days ahead"}
        else
          {cve: $e.cve, pkg: $e.pkg, target: ($e.target | trim), review: $e.review, exp: $e.exp}
        end
    ]
    | {
        exceptions: [.[] | select(has("invalid") | not)],
        invalid: [.[] | select(has("invalid"))]
      }
  ' "${ignore_file}"
)"

if test "$(jq '.invalid | length' <<<"${policy}")" -gt 0; then
  printf 'invalid .trivyignore entries in %s:\n' "${ignore_file}" >&2
  jq -r '.invalid[] | "  \(.invalid)  [\(.why)]"' <<<"${policy}" >&2
  exit 1
fi
jq -c '.exceptions' <<<"${policy}"
