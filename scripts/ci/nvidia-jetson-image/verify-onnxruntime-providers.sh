#!/usr/bin/env bash
set -Eeuo pipefail

# Check the source-built ONNX Runtime without a GPU: the wheel must match the
# recorded source version and expose the TensorRT and CUDA providers.
test "$#" -eq 1 || {
  printf 'usage: verify-onnxruntime-providers.sh IMAGE\n' >&2
  exit 64
}
image="$1"

docker run --rm --entrypoint python3 "${image}" -B -c '
from pathlib import Path

import onnxruntime as ort

source = dict(
    line.split("=", 1)
    for line in Path("/usr/share/robotics-runtime/onnxruntime-source.txt")
    .read_text()
    .splitlines()
    if "=" in line
)
providers = ort.get_available_providers()
print("onnxruntime", ort.__version__, source, providers)
assert source["onnxruntime"] == "v" + ort.__version__, source
for provider in ("TensorrtExecutionProvider", "CUDAExecutionProvider"):
    assert provider in providers, provider
'
