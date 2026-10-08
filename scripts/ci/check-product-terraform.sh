#!/usr/bin/env sh
set -eu
if [ "${1:-}" = "--inside-container" ]; then
  terraform fmt -check -recursive /src/terraform
  for name in state-bootstrap foundation; do
    cd "/src/terraform/$name"
    terraform validate -no-color
    terraform test -no-color
  done
  printf '%s\n' 'Configuration checks passed; no AWS acceptance or resource operations were performed.'
  exit 0
fi
root="$(cd -- "$(dirname -- "$0")/../.." && pwd -P)"
engine="${ROBOTICS_IMAGE_ENGINE:-docker}"
image=localhost/robotics-product-terraform:1.16.5
case "$engine" in
  docker)
    docker build --file "$root/docker/product-terraform.Dockerfile" --tag "$image" "$root"
    ;;
  podman)
    podman build --ignorefile "$root/docker/product-terraform.Dockerfile.dockerignore" \
      --file "$root/docker/product-terraform.Dockerfile" --tag "$image" "$root"
    ;;
  *)
    printf '%s\n' 'ROBOTICS_IMAGE_ENGINE must be docker or podman.' >&2
    exit 64
    ;;
esac
"$engine" run --rm --memory=3g --cpus=2 --pids-limit=256 --network=none \
  --cap-drop=ALL --security-opt=no-new-privileges "$image"
