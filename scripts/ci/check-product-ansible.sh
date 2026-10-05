#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/../.." && pwd -P)"
image="localhost/robotics-product-ansible:2.21.4"
podman build --ignorefile "$root/docker/product-ansible.Dockerfile.dockerignore" --file "$root/docker/product-ansible.Dockerfile" --tag "$image" "$root"
podman run --rm --network=none --cap-drop=ALL --cap-add=CHOWN --cap-add=FOWNER --security-opt=no-new-privileges \
  --volume "$root:/src:ro" "$image"
