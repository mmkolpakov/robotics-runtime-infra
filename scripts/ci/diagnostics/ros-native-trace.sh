#!/usr/bin/env bash
set -Eeuo pipefail

# Preserve the original ROS command and signal path; UST records native calls.
(($# > 0)) || { printf 'a native ROS command is required\n' >&2; exit 64; }
export LTTNG_HOME=/tmp/robotics-native-lttng

prepare_native_trace() {
  local directory
  for directory in "${LTTNG_HOME}" /tmp/robotics-native-ust; do
    [[ -d "${directory}" ]] || mkdir -m 0700 -- "${directory}" || return
  done
  timeout 5 lttng-sessiond --daemonize --no-kernel || return
  timeout 5 lttng create robotics-native-diagnostic \
    --output=/tmp/robotics-native-ust/trace || return
  # Two 64 KiB subbuffers bound buffer memory per CPU/process. Trace files
  # rotate at 1 MiB, two files per stream, within the existing producer lifetime.
  # Rotation/discarding can remove earlier events: absence is never proven.
  timeout 5 lttng enable-channel --userspace --buffers-pid \
    --subbuf-size=65536 --num-subbuf=2 --tracefile-size=1048576 --tracefile-count=2 native-ros || return
  timeout 5 lttng enable-event --userspace --channel=native-ros \
    'ros2:rcl_init,ros2:rcl_node_init,ros2:rcl_publisher_init,ros2:rmw_publisher_init,ros2:rcl_subscription_init,ros2:rmw_subscription_init,ros2:rcl_publish,ros2:rmw_publish,ros2:rcl_take,ros2:rmw_take' || return
  timeout 5 lttng add-context --userspace --channel=native-ros \
    --type=vpid --type=vtid || return
  timeout 5 lttng start robotics-native-diagnostic
}

trace_status=0
prepare_native_trace || trace_status=$?
printf 'diagnostic native UST setup exit: %s\n' "${trace_status}" >&2
# An unavailable diagnostic must not replace the original command's outcome.
exec "$@"
