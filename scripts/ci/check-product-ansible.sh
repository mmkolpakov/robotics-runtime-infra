#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
engine="${ROBOTICS_IMAGE_ENGINE:-docker}"
case "${engine}" in docker|podman) ;; *) exit 64 ;; esac
image="localhost/robotics-product-ansible:2.21.4"
build_options=()
if [[ "${engine}" == podman ]]; then
  build_options+=(--ignorefile "$root/docker/product-ansible.Dockerfile.dockerignore")
fi
"${engine}" build "${build_options[@]}" --file "$root/docker/product-ansible.Dockerfile" --tag "$image" "$root"
"${engine}" run --rm --network=none --cap-drop=ALL --cap-add=CHOWN --cap-add=FOWNER --security-opt=no-new-privileges \
  --volume "$root:/src:ro" "$image"
