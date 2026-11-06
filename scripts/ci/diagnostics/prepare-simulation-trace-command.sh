#!/usr/bin/env bash
set -Eeuo pipefail

(($# == 3)) || { printf 'model, immutable image ID and output directory are required\n' >&2; exit 64; }
model="$1"
image_id="$2"
output="$3"
[[ "$image_id" =~ ^sha256:[a-f0-9]{64}$ ]] || {
  printf 'diagnostic command requires an immutable local image ID\n' >&2
  exit 65
}
mkdir -p "$output"

if jq -e '.services.simulation.command != null' "$model" >/dev/null; then
  jq -e --arg image "$image_id" '{
    scope: "diagnostic-only", command_source: "compose",
    image_id: $image, command: (
      .services.simulation.command |
      if type == "array" and all(.[]; type == "string") and
        all(.[]; (gsub("\\$\\$"; "") | contains("$")) | not)
      then map(gsub("\\$\\$"; "$"))
      else error("unsupported serialized Compose command") end
    )
  }' "$model" >"$output/program.json"
else
  # No pull or producer runs: retain only this selected image's program fields.
  image_program="$(timeout 10 docker image inspect --format \
    '{"image_id":{{json .Id}},"command":{{json .Config.Cmd}},"image_entrypoint":{{json .Config.Entrypoint}}}' \
    "$image_id")"
  printf '%s\n' "$image_program" |
    jq -e --arg image "$image_id" '
      select(.image_id == $image and
        .image_entrypoint == ["/usr/local/bin/robotics-entrypoint"]) |
      . + {scope: "diagnostic-only", command_source: "image-config"}
    ' >"$output/program.json"
fi
jq -e '
  .command | type == "array" and length > 0 and length <= 64 and
  all(.[]; type == "string" and length <= 4096) and
  (map(length) | add) <= 65536
' "$output/program.json" >/dev/null || {
  printf 'diagnostic simulation command must be a bounded nonempty string array\n' >&2
  exit 65
}
# Compose interpolation is syntax, not part of the image's original argv.
jq '{services: {simulation: {command: (.command | map(gsub("\\$"; "$$")))}}}' \
  "$output/program.json" >"$output/compose.json"
