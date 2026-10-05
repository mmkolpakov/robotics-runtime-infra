#!/usr/bin/env sh
# Regenerate provider checksums only. No backend/account is contacted.
set -eu
root="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
engine="${ROBOTICS_IMAGE_ENGINE:-docker}"
case "$engine" in
  docker|podman) ;;
  *) printf '%s\n' 'ROBOTICS_IMAGE_ENGINE must be docker or podman.' >&2; exit 64 ;;
esac
task_uid="$(id -u)"
task_gid="$(id -g)"
image=docker.io/hashicorp/terraform:1.16.5@sha256:c7926feace05d0f7e73542842bf3945924e955a1f782cf000ccbb8d18fa42d77
set -- run --rm --user "$task_uid:$task_gid"
if [ "$engine" = podman ]; then
  set -- "$@" --userns=keep-id
fi
"$engine" "$@" --volume "$root/terraform:/src/terraform:rw" \
  --env CHECKPOINT_DISABLE=1 --env TF_IN_AUTOMATION=1 --env AWS_EC2_METADATA_DISABLED=true \
  --env TF_CLI_CONFIG_FILE=/dev/null --env GIT_CONFIG_GLOBAL=/dev/null \
  --entrypoint /bin/sh "$image" -ec '
    export TF_PLUGIN_CACHE_DIR=/tmp/provider-cache
    mkdir -p "$TF_PLUGIN_CACHE_DIR"
    for root in state-bootstrap foundation; do
      export TF_DATA_DIR="/tmp/terraform-$root"
      cd "/src/terraform/$root"
      terraform init -backend=false -input=false
    done
  '
