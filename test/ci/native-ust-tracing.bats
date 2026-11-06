#!/usr/bin/env bats

setup() {
  export REPO_ROOT="$(cd "$BATS_TEST_DIRNAME/../.." && pwd)"
  export TRACE_CALLS="$BATS_TEST_TMPDIR/calls"
  export TRACE_INSPECT="$BATS_TEST_TMPDIR/inspect.json"
  export TRACE_MODEL="$BATS_TEST_TMPDIR/model.json"
  export TRACE_CONTAINER="$(printf '%064d' 1)"
  export TRACE_SECOND_CONTAINER="$(printf '%064d' 2)"
  export TRACE_THIRD_CONTAINER="$(printf '%064d' 3)"
  export TRACE_FOURTH_CONTAINER="$(printf '%064d' 4)"
  export TRACE_IMAGE="sha256:$(printf '%064d' 5)"
  export TRACE_ARTIFACT="$BATS_TEST_TMPDIR/artifact"
  mkdir -p "$BATS_TEST_TMPDIR/bin"
  cat >"$BATS_TEST_TMPDIR/bin/docker" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$TRACE_CALLS"
case "$1" in
  compose)
    case "${*: -1}" in
      runtime-probe-publisher) printf '%s\n' "$TRACE_SECOND_CONTAINER" ;;
      simulation) printf '%s\n' "$TRACE_THIRD_CONTAINER" ;;
      simulation-stepper)
        if [[ "${TRACE_MISSING_ACTOR:-0}" != 1 ]]; then printf '%s\n' "$TRACE_FOURTH_CONTAINER"; fi ;;
      *) printf '%s\n' "$TRACE_CONTAINER" ;;
    esac ;;
  inspect)
    case "$2" in
      "$TRACE_SECOND_CONTAINER") service=runtime-probe-publisher ;;
      "$TRACE_THIRD_CONTAINER") service=simulation ;;
      "$TRACE_FOURTH_CONTAINER") service=simulation-stepper ;;
      *) service=runtime-metrics ;;
    esac
    jq --arg id "$2" --arg service "$service" --slurpfile model "$TRACE_MODEL" '
      if $service != "runtime-metrics" then .[0].Id=$id else . end |
      .[0].Config.Labels["com.docker.compose.service"]=$service |
      .[0].Config.Cmd=$model[0].services[$service].command |
      .[0].Config.Entrypoint=$model[0].services[$service].entrypoint |
      if $service != "runtime-metrics" then .[0].State.Running=true else . end
    ' "$TRACE_INSPECT" |
    jq --arg service "$service" --arg foreign "${TRACE_FOREIGN_SERVICE:-}" '
      if $service == $foreign then .[0].Config.Labels["com.docker.compose.project"]="foreign" else . end
    ' |
    jq --arg bad "${TRACE_COMMAND_BAD:-0}" '
      if $bad == "1" then .[0].Config.Cmd=["id"] else . end
    ' |
    jq --arg bad "${TRACE_ENTRYPOINT_BAD:-0}" '
      if $bad == "1" then .[0].Config.Entrypoint=["sh","-c"] else . end
    ' ;;
  logs)
    case "${TRACE_LOG_MODE:-ordinary}" in
      oversized) head -c 2097154 /dev/zero | tr '\0' x ;;
      full-tail) for ((i=0; i<4097; i++)); do printf 'diagnostic line\n'; done ;;
      timeout) exit 124 ;;
      *) printf '{"diagnostic":"simulation-control","phase":"request_issued"}\n' ;;
    esac ;;
  exec|cp) exit 0 ;;
  *) exit 64 ;;
esac
SH
  chmod +x "$BATS_TEST_TMPDIR/bin/docker"
  export PATH="$BATS_TEST_TMPDIR/bin:$PATH"
  jq -n '{
    services: {
      "runtime-metrics": {
        command:["/bin/bash","/tmp/ros-native-trace.sh","ros2","run","robotics_observability","runtime_metrics"],
        entrypoint:["/usr/local/bin/robotics-entrypoint"]
      },
      "runtime-probe-publisher": {
        command:["/bin/bash","/tmp/ros-native-trace.sh","ros2","topic","pub"],
        entrypoint:["/usr/local/bin/robotics-entrypoint"]
      },
      simulation: {
        command:["ros2","launch","robotics_runtime_infra","headless.launch.py"],
        entrypoint:["/usr/local/bin/robotics-entrypoint","/bin/bash","/tmp/ros-native-trace.sh"]
      },
      "simulation-stepper": {
        command:["python3","-m","robotics_runtime_infra.simulation_control","--namespace","/simulator",
                 "step","--steps","1","--step-size-ns","1000000","--interval-sec","0.2"],
        entrypoint:["/usr/local/bin/robotics-entrypoint","/bin/bash","/tmp/ros-native-trace.sh"]
      }
    }
  }' >"$TRACE_MODEL"
  jq -n --arg id "$TRACE_CONTAINER" --arg image "$TRACE_IMAGE" '[{
    Id: $id, Image: $image,
    Config: {Env: ["ROBOTICS_RUN_ID=issued-run", "ROBOTICS_DOMAIN_ID=primary",
      "ROS_DOMAIN_ID=188", "GZ_PARTITION=owned-partition", "ROBOTICS_SIMULATION_DIAGNOSTICS=1"],
      Labels: {"com.docker.compose.project":"owned-project", "com.docker.compose.service":"runtime-metrics"}},
    State:{Running:true, Status:"running", StartedAt:"native"}
  }]' >"$TRACE_INSPECT"
}

run_capture() {
  run bash -c '
    set -o pipefail
    source <(sed -n "/^capture_native_ros_trace()/,/^capture_runtime_metrics_diagnostics()/p" \
      "$REPO_ROOT/scripts/ci/foundation/run-acceptance.sh" | head -n -1)
    native_trace="$1"; data_source="${TRACE_DATA_SOURCE:-simulator}"; project=owned-project
    ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="$TRACE_IMAGE"; ROBOTICS_RUN_ID=issued-run
    ROBOTICS_DOMAIN_ID=primary; ROS_DOMAIN_ID=188; GZ_PARTITION=owned-partition
    artifact_dir="$TRACE_ARTIFACT"; compose=(docker compose); resolved_model="$TRACE_MODEL"
    capture_native_ros_trace
  ' _ "$1"
}

@test "disabled capture has no daemon or filesystem effects" {
  run_capture 0
  [ "$status" -eq 0 ]
  [ ! -e "$TRACE_CALLS" ]
  [ ! -e "$TRACE_ARTIFACT" ]
}

@test "all simulator actors retain the exact resolved program and wrapper" {
  run_capture 1
  [ "$status" -eq 0 ]
  [ "$(grep -c '^cp ' "$TRACE_CALLS")" -eq 4 ]
  for service in runtime-metrics runtime-probe-publisher simulation simulation-stepper; do
    jq -e --arg service "$service" --slurpfile model "$TRACE_MODEL" '
      .command == $model[0].services[$service].command and
      .entrypoint == $model[0].services[$service].entrypoint
    ' "$TRACE_ARTIFACT/native-ust/$service/identity.json"
  done
  jq -e '.truncated == false and .absence_proven == false and .command_exit == 0' \
    "$TRACE_ARTIFACT/native-ust/simulation-stepper/phase-capture.json"
}

@test "foreign project is refused before session or copy commands" {
  jq '.[0].Config.Labels["com.docker.compose.project"]="foreign"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "mismatched actual container is refused before session or copy commands" {
  jq '.[0].Id="wrong"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "last actor ownership is checked before retaining any actor trace or logs" {
  export TRACE_FOREIGN_SERVICE=simulation-stepper
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "changed actual program is refused before session or copy commands" {
  export TRACE_COMMAND_BAD=1
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "changed wrapper cannot hide the resolved underlying program" {
  export TRACE_ENTRYPOINT_BAD=1
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "naturally exited producer retains trace but refuses a complete trace claim" {
  jq '.[0].State.Running=false' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -eq 68 ]
  ! grep -Fq "exec $TRACE_CONTAINER " "$TRACE_CALLS"
  grep -Fq "exec $TRACE_SECOND_CONTAINER " "$TRACE_CALLS"
  [ "$(grep -c '^cp ' "$TRACE_CALLS")" -eq 4 ]
  [ -s "$TRACE_ARTIFACT/native-ust/runtime-metrics/partial-trace.log" ]
}

@test "same-label foreign image is refused before session-control side effects" {
  jq '.[0].Image="sha256:foreign"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "same-label stale issued run is refused before session-control side effects" {
  jq '.[0].Config.Env[0]="ROBOTICS_RUN_ID=stale-run"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "same-label foreign logical domain is refused before session-control side effects" {
  jq '.[0].Config.Env[1]="ROBOTICS_DOMAIN_ID=foreign"' "$TRACE_INSPECT" >"$TRACE_INSPECT.next"
  mv "$TRACE_INSPECT.next" "$TRACE_INSPECT"
  run_capture 1
  [ "$status" -ne 0 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "phase log byte overflow is bounded and explicitly partial" {
  export TRACE_LOG_MODE=oversized
  run_capture 1
  [ "$status" -eq 69 ]
  [ "$(wc -c <"$TRACE_ARTIFACT/native-ust/simulation-stepper/phase.log")" -eq 2097152 ]
  jq -e '.truncated and .absence_proven == false' "$TRACE_ARTIFACT/native-ust/simulation-stepper/phase-capture.json"
  [ -s "$TRACE_ARTIFACT/native-ust/simulation-stepper/partial-phase.log" ]
}

@test "a full tail cannot be represented as complete diagnostic evidence" {
  export TRACE_LOG_MODE=full-tail
  run_capture 1
  [ "$status" -eq 69 ]
  jq -e '.truncated and .absence_proven == false' "$TRACE_ARTIFACT/native-ust/simulation-stepper/phase-capture.json"
}

@test "failed log capture retains an explicit partial outcome" {
  export TRACE_LOG_MODE=timeout
  run_capture 1
  [ "$status" -eq 69 ]
  jq -e '.truncated and .command_exit == 124' "$TRACE_ARTIFACT/native-ust/simulation-stepper/phase-capture.json"
}

run_once_capture() {
  run bash -c '
    set -o pipefail
    source <(sed -n "/^capture_native_ros_trace()/,/^capture_runtime_metrics_diagnostics()/p"       "$REPO_ROOT/scripts/ci/foundation/run-acceptance.sh" | head -n -1)
    native_trace="$1"; data_source=simulator; project=owned-project
    ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="$TRACE_IMAGE"; ROBOTICS_RUN_ID=issued-run
    ROBOTICS_DOMAIN_ID=primary; ROS_DOMAIN_ID=188; GZ_PARTITION=owned-partition
    artifact_dir="$TRACE_ARTIFACT"; compose=(docker compose); resolved_model="$TRACE_MODEL"
    first=0; capture_native_ros_trace_once before_owned_cleanup || first=$?
    before="$(test ! -f "$TRACE_CALLS" || wc -l <"$TRACE_CALLS")"
    second=0; capture_native_ros_trace_once after_measurement || second=$?
    after="$(test ! -f "$TRACE_CALLS" || wc -l <"$TRACE_CALLS")"
    test "$before" = "$after"
    test "$first" = "$second"
    exit "$first"
  ' _ "$1"
}

@test "once-only disabled capture has no filesystem or engine effects" {
  run_once_capture 0
  [ "$status" -eq 0 ]
  [ ! -e "$TRACE_CALLS" ]
  [ ! -e "$TRACE_ARTIFACT" ]
}

@test "once-only partial capture cannot be retried into a fresh success" {
  export TRACE_LOG_MODE=timeout
  run_once_capture 1
  [ "$status" -eq 69 ]
  [ "$(cat "$TRACE_ARTIFACT/native-ust/capture.exit")" -eq 69 ]
  jq -e '.capture_phase == "before_owned_cleanup"' "$TRACE_ARTIFACT/native-ust/capture-attempt/phase.json"
}

@test "zero actor identity refuses once-only capture without harvesting" {
  export TRACE_MISSING_ACTOR=1
  run_once_capture 1
  [ "$status" -eq 65 ]
  [ "$(cat "$TRACE_ARTIFACT/native-ust/capture.exit")" -eq 65 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "early failure captures owned diagnostics before cleanup and preserves original failure" {
  run bash -c '
    set -o pipefail
    source <(sed -n "/^capture_native_ros_trace()/,/^capture_runtime_metrics_diagnostics()/p"       "$REPO_ROOT/scripts/ci/foundation/run-acceptance.sh" | head -n -1)
    source <(sed -n "/^cleanup()/,/^trap cleanup EXIT/p"       "$REPO_ROOT/scripts/ci/foundation/run-acceptance.sh" | head -n -1)
    native_trace=1; data_source=simulator; project=owned-project
    ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="$TRACE_IMAGE"; ROBOTICS_RUN_ID=issued-run
    ROBOTICS_DOMAIN_ID=primary; ROS_DOMAIN_ID=188; GZ_PARTITION=owned-partition
    artifact_dir="$TRACE_ARTIFACT"; compose=(docker compose); resolved_model="$TRACE_MODEL"
    observer=""; attached_compose=(); profiles=()
    foundation_compose_logs() { :; }
    publish_acceptance_results() { :; }
    publish_failure_evidence() { :; }
    foundation_cleanup_project() { printf "cleanup-owned-project\n" >>"$TRACE_CALLS"; }
    trap cleanup EXIT
    exit 73
  '
  [ "$status" -eq 73 ]
  [ "$(cat "$TRACE_ARTIFACT/native-ust/capture.exit")" -eq 0 ]
  capture_line="$(grep -n '^cp ' "$TRACE_CALLS" | tail -1 | cut -d: -f1)"
  cleanup_line="$(grep -n '^cleanup-owned-project$' "$TRACE_CALLS" | cut -d: -f1)"
  [ "$capture_line" -lt "$cleanup_line" ]
}

@test "diagnostic refusal does not replace original observer or timeout failure" {
  export TRACE_MISSING_ACTOR=1
  run bash -c '
    source <(sed -n "/^capture_native_ros_trace()/,/^capture_runtime_metrics_diagnostics()/p"       "$REPO_ROOT/scripts/ci/foundation/run-acceptance.sh" | head -n -1)
    source <(sed -n "/^cleanup()/,/^trap cleanup EXIT/p"       "$REPO_ROOT/scripts/ci/foundation/run-acceptance.sh" | head -n -1)
    native_trace=1; data_source=simulator; project=owned-project
    ROBOTICS_SIMULATION_LOCAL_IMAGE_ID="$TRACE_IMAGE"; ROBOTICS_RUN_ID=issued-run
    ROBOTICS_DOMAIN_ID=primary; ROS_DOMAIN_ID=188; GZ_PARTITION=owned-partition
    artifact_dir="$TRACE_ARTIFACT"; compose=(docker compose); resolved_model="$TRACE_MODEL"
    observer=""; attached_compose=(); profiles=(); observer_status=124
    foundation_compose_logs() { :; }
    publish_acceptance_results() { :; }
    publish_failure_evidence() { :; }
    foundation_cleanup_project() { :; }
    trap cleanup EXIT
    exit 1
  '
  [ "$status" -eq 124 ]
  [ "$(cat "$TRACE_ARTIFACT/native-ust/capture.exit")" -eq 65 ]
  ! grep -Eq '^(exec|cp|logs) ' "$TRACE_CALLS"
}

@test "previous successful diagnostic marker is refused and never reused as current proof" {
  mkdir -p "$TRACE_ARTIFACT/native-ust/capture-attempt"
  printf '0\n' >"$TRACE_ARTIFACT/native-ust/capture.exit"
  printf 'historical trace\n' >"$TRACE_ARTIFACT/native-ust/historical.txt"
  before="$(sha256sum "$TRACE_ARTIFACT/native-ust/capture.exit" "$TRACE_ARTIFACT/native-ust/historical.txt")"
  run_once_capture 1
  [ "$status" -eq 65 ]
  [ ! -e "$TRACE_CALLS" ]
  after="$(sha256sum "$TRACE_ARTIFACT/native-ust/capture.exit" "$TRACE_ARTIFACT/native-ust/historical.txt")"
  [ "$before" = "$after" ]
}

@test "pre-existing diagnostic leaf without a marker is refused unchanged" {
  mkdir -p "$TRACE_ARTIFACT/native-ust"
  printf 'old evidence\n' >"$TRACE_ARTIFACT/native-ust/old.txt"
  run_once_capture 1
  [ "$status" -eq 65 ]
  [ ! -e "$TRACE_CALLS" ]
  [ "$(cat "$TRACE_ARTIFACT/native-ust/old.txt")" = "old evidence" ]
  [ ! -e "$TRACE_ARTIFACT/native-ust/capture.exit" ]
}

@test "exclusive leaf acquisition refuses an intervening owner without capture effects" {
  run bash -c '
    source <(sed -n "/^capture_native_ros_trace()/,/^capture_runtime_metrics_diagnostics()/p"       "$REPO_ROOT/scripts/ci/foundation/run-acceptance.sh" | head -n -1)
    native_trace=1; artifact_dir="$TRACE_ARTIFACT"
    mkdir() {
      if [[ "$*" == "$TRACE_ARTIFACT/native-ust" ]]; then
        command mkdir "$TRACE_ARTIFACT/native-ust"
        printf "other invocation\n" >"$TRACE_ARTIFACT/native-ust/other.txt"
        return 1
      fi
      command mkdir "$@"
    }
    capture_native_ros_trace_once before_owned_cleanup
  '
  [ "$status" -eq 65 ]
  [ ! -e "$TRACE_CALLS" ]
  [ "$(cat "$TRACE_ARTIFACT/native-ust/other.txt")" = "other invocation" ]
  [ ! -e "$TRACE_ARTIFACT/native-ust/capture.exit" ]
}
