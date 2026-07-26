#!/usr/bin/env bash
set -Eeuo pipefail

image="${REGISTRY}/robotics-runtime-infra/inference-nvidia:${VERSION}"
docker run --rm --entrypoint test "${image}" \
  -s /usr/share/licenses/nvidia/NGC-DL-CONTAINER-LICENSE
docker run --rm --interactive --entrypoint /opt/venv/bin/python "${image}" - <<'PY'
import onnxruntime as ort

providers = ort.get_available_providers()
assert "CUDAExecutionProvider" in providers, providers
PY
