#!/usr/bin/env bats

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TRACE_IMAGE="sha256:$(printf '%064d' 7)"
  export TRACE_IMAGE_INFO="$BATS_TEST_TMPDIR/image.json"
  export TRACE_IMAGE_CALLS="$BATS_TEST_TMPDIR/image-calls"
  export TRACE_PROGRAM_MODEL="$BATS_TEST_TMPDIR/model.json"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TRACE_IMAGE_CALLS"
[[ "$1" == image && "$2" == inspect && "${*: -1}" == "$TRACE_IMAGE" ]] || exit 64
if [[ "${TRACE_IMAGE_MODE:-ordinary}" == hang ]]; then sleep 30; fi
cat "$TRACE_IMAGE_INFO"
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  jq -n '{services:{simulation:{command:null}}}' >"$TRACE_PROGRAM_MODEL"
  jq -n --arg id "$TRACE_IMAGE" '{
    image_id:$id, image_entrypoint:["/usr/local/bin/robotics-entrypoint"],
    command:["python3","-m","original_image_program","--literal","two words"]
  }' >"$TRACE_IMAGE_INFO"
}

prepare_program() {
  run bash "$REPO_ROOT/scripts/ci/diagnostics/prepare-simulation-trace-command.sh" \
    "$TRACE_PROGRAM_MODEL" "$1" "$BATS_TEST_TMPDIR/program"
}

@test "image default Cmd is retained from exactly the selected immutable image" {
  prepare_program "$TRACE_IMAGE"
  [ "$status" -eq 0 ]
  jq -e --slurpfile image "$TRACE_IMAGE_INFO" '
    .image_id == $image[0].image_id and .command == $image[0].command and
    .command_source == "image-config"
  ' "$BATS_TEST_TMPDIR/program/program.json"
  jq -e --slurpfile image "$TRACE_IMAGE_INFO" '
    .services.simulation.command == $image[0].command
  ' "$BATS_TEST_TMPDIR/program/compose.json"
  [ "$(wc -l <"$TRACE_IMAGE_CALLS")" -eq 1 ]
  grep -Fq "$TRACE_IMAGE" "$TRACE_IMAGE_CALLS"
}

@test "explicit Compose command is unchanged and needs no image-default lookup" {
  jq '.services.simulation.command=["declared","argument with spaces","$$literal"]' \
    "$TRACE_PROGRAM_MODEL" >"$TRACE_PROGRAM_MODEL.next"
  mv "$TRACE_PROGRAM_MODEL.next" "$TRACE_PROGRAM_MODEL"
  prepare_program "$TRACE_IMAGE"
  [ "$status" -eq 0 ]
  [ ! -e "$TRACE_IMAGE_CALLS" ]
  jq -e --slurpfile model "$TRACE_PROGRAM_MODEL" '
    .command_source == "compose" and
    .command == ($model[0].services.simulation.command | map(gsub("\\$\\$"; "$")))
  ' "$BATS_TEST_TMPDIR/program/program.json"
}

@test "mutable image reference is refused before any image lookup" {
  prepare_program source:latest
  [ "$status" -eq 65 ]
  [ ! -e "$TRACE_IMAGE_CALLS" ]
  [ ! -e "$BATS_TEST_TMPDIR/program/compose.json" ]
}

@test "wrong returned image ID is refused without a generated command" {
  jq '.image_id="sha256:foreign"' "$TRACE_IMAGE_INFO" >"$TRACE_IMAGE_INFO.next"
  mv "$TRACE_IMAGE_INFO.next" "$TRACE_IMAGE_INFO"
  prepare_program "$TRACE_IMAGE"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/program/compose.json" ]
}

@test "null or string image Cmd is unsupported rather than replaced with guessed argv" {
  for command in null '"ros2 launch guessed"'; do
    jq --argjson command "$command" '.command=$command' "$TRACE_IMAGE_INFO" >"$TRACE_IMAGE_INFO.next"
    mv "$TRACE_IMAGE_INFO.next" "$TRACE_IMAGE_INFO"
    prepare_program "$TRACE_IMAGE"
    [ "$status" -ne 0 ]
    [ ! -e "$BATS_TEST_TMPDIR/program/compose.json" ]
  done
}

@test "noncanonical owned-image entrypoint is refused" {
  jq '.image_entrypoint=["sh","-c"]' "$TRACE_IMAGE_INFO" >"$TRACE_IMAGE_INFO.next"
  mv "$TRACE_IMAGE_INFO.next" "$TRACE_IMAGE_INFO"
  prepare_program "$TRACE_IMAGE"
  [ "$status" -ne 0 ]
  [ ! -e "$BATS_TEST_TMPDIR/program/compose.json" ]
}

@test "explicit string or empty command is refused without an image fallback" {
  for command in '"shell command"' '[]'; do
    jq --argjson command "$command" '.services.simulation.command=$command' \
      "$TRACE_PROGRAM_MODEL" >"$TRACE_PROGRAM_MODEL.next"
    mv "$TRACE_PROGRAM_MODEL.next" "$TRACE_PROGRAM_MODEL"
    prepare_program "$TRACE_IMAGE"
    [ "$status" -ne 0 ]
    [ ! -e "$TRACE_IMAGE_CALLS" ]
    [ ! -e "$BATS_TEST_TMPDIR/program/compose.json" ]
  done
}

@test "lone dollar in serialized command is refused without environment substitution" {
  jq '.services.simulation.command=["declared","$NAME"]' "$TRACE_PROGRAM_MODEL" >"$TRACE_PROGRAM_MODEL.next"
  mv "$TRACE_PROGRAM_MODEL.next" "$TRACE_PROGRAM_MODEL"
  prepare_program "$TRACE_IMAGE"
  [ "$status" -ne 0 ]
  [ ! -e "$TRACE_IMAGE_CALLS" ]
  [ ! -e "$BATS_TEST_TMPDIR/program/compose.json" ]
}

@test "stock image inspect timeout refuses before generating executable configuration" {
  export TRACE_IMAGE_MODE=hang
  prepare_program "$TRACE_IMAGE"
  [ "$status" -eq 124 ]
  [ ! -e "$BATS_TEST_TMPDIR/program/compose.json" ]
}
