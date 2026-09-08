#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

[[ $# -eq 4 ]] || {
  printf 'usage: collect-simulation-provider.sh CONTAINER RUN_DIR OUTPUT_DIR SUBJECT_DIGEST\n' >&2
  exit 64
}
container="$1"
run_dir="$2"
output="$3"
subject_digest="$4"
script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
root="$(cd "${script_dir}/../../.." && pwd -P)"
python="${ROBOTICS_FOUNDATION_PYTHON:-${root}/dependencies/robotics-runtime/.venv/bin/python}"
namespace="${ROBOTICS_SIMULATOR_SERVICE_NAMESPACE:-/simulator}"
[[ "${namespace}" =~ ^/([a-zA-Z_][a-zA-Z0-9_]*)(/[a-zA-Z_][a-zA-Z0-9_]*)*$ ]] || {
  printf 'invalid simulator service namespace: %s\n' "${namespace}" >&2
  exit 64
}
# The retained directory is new for this invocation. A failed probe cannot leave
# a previously successful binding for the caller to reuse.
mkdir "${output}"
world_parameter="$(
  docker exec "${container}" robotics-entrypoint timeout 35 \
    ros2 param get "${namespace}" world_sdf_file --hide-type --timeout 30
)"
world_path="$(docker exec "${container}" readlink -e -- "${world_parameter}")"
[[ "${world_path}" != *$'\n'* && "${world_path}" != *$'\r'* && "${world_path}" != *$'\t'* ]] || {
  printf 'simulator returned an invalid world path\n' >&2
  exit 65
}
case "${world_path}" in
  /opt/robotics_ws/*|/run/robotics/*) ;;
  *)
    printf 'simulator world is outside the runtime asset directories: %s\n' "${world_path}" >&2
    exit 65
    ;;
esac
docker exec "${container}" test -f "${world_path}"
docker cp "${container}:${world_path}" "${output}/world.sdf"
version="$(docker exec "${container}" robotics-entrypoint gz sim --versions)"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+([.+-][a-zA-Z0-9.+-]+)?$ ]] || {
  printf 'expected exactly one installed Gazebo Sim version, got: %s\n' "${version}" >&2
  exit 65
}
docker exec "${container}" robotics-entrypoint timeout 150 python3 -m \
  robotics_runtime_infra.simulation_control --namespace "${namespace}" \
  verify --steps 5 --step-size-ns 1000000 >"${output}/observation.json"
world_parameter_after="$(
  docker exec "${container}" robotics-entrypoint timeout 35 \
    ros2 param get "${namespace}" world_sdf_file --hide-type --timeout 30
)"
[[ "${world_parameter_after}" == "${world_parameter}" ]] || {
  printf 'simulator world parameter changed during conformance\n' >&2
  exit 65
}
docker cp "${container}:${world_path}" "${output}/world-after.sdf"
cmp -s "${output}/world.sdf" "${output}/world-after.sdf" || {
  printf 'simulator world bytes changed during conformance\n' >&2
  exit 65
}
rm -- "${output}/world-after.sdf"
world_sha256="$(sha256sum "${output}/world.sdf" | cut -d' ' -f1)"
world_size="$(wc -c <"${output}/world.sdf" | tr -d '[:space:]')"
jq -n --arg version "${version}" --arg namespace "${namespace}" \
  --arg path "${world_path}" --arg sha256 "${world_sha256}" --argjson size "${world_size}" \
  '{implementation_id: "gz_sim", version: $version, service_namespace: $namespace,
    world_path: $path, world_sha256: $sha256, world_size_bytes: $size}' \
  >"${output}/configuration.json"
cp "${root}/config/qualification/simulation-interfaces.json" "${output}/profile.json"
"${python}" "${script_dir}/create-simulation-provider.py" \
  --scenario "${run_dir}/scenario.yaml" --run-context "${run_dir}/acceptance-run.json" \
  --profile "${output}/profile.json" --configuration "${output}/configuration.json" \
  --observation "${output}/observation.json" --world "${output}/world.sdf" \
  --subject-digest "${subject_digest}" --output "${output}/conformance.json" \
  >"${output}/bindings.pending.json"
mv -- "${output}/bindings.pending.json" "${output}/bindings.json"
