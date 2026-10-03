#!/usr/bin/env bash
set -Eeuo pipefail

container="${1:?fresh neutral robot container is required}"
output="${2:?readiness log directory is required}"
mkdir -p -- "${output}"
# The caller bounds this whole gate with one native timeout. An interrupted
# ros_gz_sim/create can exit zero; require its fresh success and clean-exit logs.
while :; do
  docker logs "${container}" >"${output}/launch.log" 2>&1
  spawn_id="$(sed -nE '/^\[neutral_robot_create-[0-9]+\].*Entity creation successful\./ {
    s/^\[([^]]+)\].*/\1/p
  }' "${output}/launch.log" | sort --unique)"
  if [[ "${spawn_id}" =~ ^neutral_robot_create-[0-9]+$ ]] &&
    grep -F "[${spawn_id}]: process has finished cleanly" \
      "${output}/launch.log" >/dev/null; then
    break
  fi
  if grep -E '\[neutral_robot_create-[0-9]+\]: process has died' \
    "${output}/launch.log" >/dev/null ||
    [[ "$(docker inspect --format '{{.State.Running}}' "${container}")" != true ]]; then
    printf 'native robot creation failed before readiness\n' >&2
    exit 70
  fi
  sleep 0.2
done
docker exec "${container}" robotics-entrypoint timeout 85 ros2 topic echo \
  /clock rosgraph_msgs/msg/Clock --once --no-daemon \
  --qos-reliability reliable --qos-depth 1000 \
  --filter 'm.clock.sec > 0 or m.clock.nanosec > 0' >"${output}/clock.yaml"
docker exec "${container}" robotics-entrypoint timeout 85 ros2 topic echo \
  /joint_states sensor_msgs/msg/JointState --once --no-daemon \
  --filter 'm.name == ["slider_joint"] and len(m.position) == 1 and m.position[0] == 0.0 and (m.header.stamp.sec > 0 or m.header.stamp.nanosec > 0)' \
  >"${output}/joint-states.yaml"
docker exec "${container}" robotics-entrypoint timeout 85 ros2 topic echo \
  /tf tf2_msgs/msg/TFMessage --once --no-daemon \
  --filter 'any(t.header.frame_id == "base_link" and t.child_frame_id == "slider_link" and t.transform.translation.x == 0.2 and t.transform.translation.y == 0.0 and t.transform.translation.z == 0.0 and t.transform.rotation.x == 0.0 and t.transform.rotation.y == 0.0 and t.transform.rotation.z == 0.0 and t.transform.rotation.w == 1.0 and (t.header.stamp.sec > 0 or t.header.stamp.nanosec > 0) for t in m.transforms)' \
  >"${output}/tf.yaml"
test -s "${output}/clock.yaml"
test -s "${output}/joint-states.yaml"
test -s "${output}/tf.yaml"
