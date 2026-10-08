#!/usr/bin/env sh
set -eu
root="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
engine="${ROBOTICS_IMAGE_ENGINE:-docker}"
image=localhost/robotics-product-helm:4.3.0
case "$engine" in
  docker) docker build --file "$root/docker/product-kubernetes-tools.Dockerfile" --tag "$image" "$root" ;;
  podman) podman build --format=docker --ignorefile "$root/docker/product-kubernetes-tools.Dockerfile.dockerignore" --file "$root/docker/product-kubernetes-tools.Dockerfile" --tag "$image" "$root" ;;
  *) printf '%s\n' 'ROBOTICS_IMAGE_ENGINE must be docker or podman.' >&2; exit 64 ;;
esac
"$engine" run --rm --network=none --memory=2g --cpus=2 --pids-limit=128 \
  --cap-drop=ALL --security-opt=no-new-privileges "$image"
