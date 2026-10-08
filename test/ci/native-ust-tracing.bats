#!/usr/bin/env bats

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TRACE_CALLS="$BATS_TEST_TMPDIR/calls"
  export TRACE_INSPECT="$BATS_TEST_TMPDIR/inspect.json"
  export TRACE_CONTAINER="$(printf '%064d' 1)"
  export TRACE_SECOND_CONTAINER="$(printf '%064d' 2)"
  export TRACE_IMAGE="sha256:$(printf '%064d' 3)"
  export TRACE_ARTIFACT="$BATS_TEST_TMPDIR/artifact"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TRACE_CALLS"
case "$1" in
  compose)
    if [[ "${*: -1}" == runtime-probe-publisher ]]; then
      printf '%s\n' "$TRACE_SECOND_CONTAINER"
    else
      printf '%s\n' "$TRACE_CONTAINER"
    fi ;;
  inspect)
    if [[ "$2" == "$TRACE_SECOND_CONTAINER" ]]; then
      jq --arg id "$TRACE_SECOND_CONTAINER" '
        .[0].Id=$id |
        .[0].Config.Labels["com.docker.compose.service"]="runtime-probe-publisher" |
        .[0].State.Running=true' "$TRACE_INSPECT"
    else
      cat "$TRACE_INSPECT"
    fi ;;
  exec|cp) exit 0 ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  jq -n --arg id "$TRACE_CONTAINER" --arg image "$TRACE_IMAGE" '[{
    Id: $id, Image: $image,
    Config: {Env: ["ROBOTICS_RUN_ID=issued-run", "ROBOTICS_DOMAIN_ID=primary",
      "ROS_DOMAIN_ID=188", "GZ_PARTITION=owned-partition"], Labels: {"com.docker.compose.project":"owned-project",
      "com.docker.compose.service":"runtime-metrics"}, Cmd:["ros2","run"]},
    State:{Running:true, Status:"running", StartedAt:"native"}
  }]' >"$TRACE_INSPECT"
}

run_capture() {
  run bash -c '
    source <(sed -n "/^capture_native_ros_trace()/,/^capture_runtime_metrics_diagnostics()/p" \
      "$REPO_ROOT/scripts/ci/foundation/run-acceptance.sh" | head -n -1)
    native_trace="$1"; data_source=simulator; project=owned-project
    ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="$TRACE_IMAGE"; ROBOTICS_RUN_ID=issued-run
    ROBOTICS_DOMAIN_ID=primary; ROS_DOMAIN_ID=188; GZ_PARTITION=owned-partition
    artifact_dir="$TRACE_ARTIFACT"; compose=(docker compose)
    capture_native_ros_trace
  ' _ "$1"
}

@test "disabled capture has no daemon or filesystem effects" {
  run_capture 0
  [ "$status" -eq 0 ]
  [ ! -e "$TRACE_CALLS" ]
  [ ! -e "$TRACE_ARTIFACT" ]
}

@test "foreign project is refused before session or copy commands" {
  jq '.[0].Config.Labels["com.docker.compose.project"]="foreign"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp) ' "$TRACE_CALLS"
}

@test "mismatched actual container is refused before session or copy commands" {
  jq '.[0].Id="wrong"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp) ' "$TRACE_CALLS"
}

@test "naturally exited producer retains trace but refuses a complete trace claim" {
  jq '.[0].State.Running=false' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -eq 68 ]
  ! grep -Fq "exec $TRACE_CONTAINER " "$TRACE_CALLS"
  grep -Fq "exec $TRACE_SECOND_CONTAINER " "$TRACE_CALLS"
  [ "$(grep -c '^cp ' "$TRACE_CALLS")" -eq 2 ]
  [ -s "$TRACE_ARTIFACT/native-ust/runtime-metrics/partial-trace.log" ]
}


@test "same-label foreign image is refused before any session-control side effect" {
  jq '.[0].Image="sha256:foreign"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp) ' "$TRACE_CALLS"
}

@test "same-label stale issued run is refused before any session-control side effect" {
  jq '.[0].Config.Env[0]="ROBOTICS_RUN_ID=stale-run"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp) ' "$TRACE_CALLS"
}

@test "same-label foreign logical domain is refused before any session-control side effect" {
  jq '.[0].Config.Env[1]="ROBOTICS_DOMAIN_ID=foreign"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp) ' "$TRACE_CALLS"
}
