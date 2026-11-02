#!/usr/bin/env bash
set -Eeuo pipefail

# The CUDA inference build image and the ONNX Runtime build tree need more
# space than a hosted runner leaves free; drop preinstalled toolchains the
# Jetson build does not use.
df -h /
for path in \
  /usr/local/lib/android \
  /usr/local/.ghcup \
  /usr/share/dotnet \
  /usr/share/swift \
  /opt/ghc \
  /opt/hostedtoolcache/CodeQL; do
  if [[ -e "${path}" ]]; then
    sudo rm -rf "${path}"
  fi
done
docker image prune --all --force >/dev/null
df -h /
