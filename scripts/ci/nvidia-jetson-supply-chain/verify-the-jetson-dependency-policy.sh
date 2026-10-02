#!/usr/bin/env bash
set -Eeuo pipefail

lock=docker/python/inference-nvidia-jetson.lock
grep -Fq 'numpy==1.26.4' "${lock}"
grep -Fq 'nvidia-cublas==13.5.1.27' "${lock}"
grep -Fq 'nvidia-cuda-nvrtc==13.3.33' "${lock}"
grep -Fq 'nvidia-cudnn-cu13==9.23.0.39' "${lock}"
grep -Fq 'tensorrt-cu13-libs @' "${lock}"
grep -Fq \
  'sha256=58debb693e0708cf7722868845f3e5286fb9c4d5ac2a1bf3b3806eb4706be39b' \
  "${lock}"

# The Jetson image builds ONNX Runtime from source because the published
# aarch64 wheel lacks the TensorRT provider. Fail once that changes.
version="$(
  sed -nE 's#.*github[.]com/microsoft/onnxruntime[.]git[?]tag=v([0-9.]+)&checksum=.*#\1#p' \
    docker-bake.hcl
)"
[[ "${version}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
wheel_url="$(
  curl --fail --location --silent --show-error \
    "https://pypi.org/pypi/onnxruntime-gpu/${version}/json" \
    | jq -er '[.urls[] | select(.filename | test("cp312-cp312-manylinux.*aarch64"))]
      | if length == 0 then "" else .[0].url end'
)"
if [[ -n "${wheel_url}" ]]; then
  python3 - "${wheel_url}" <<'PY'
import io
import sys
import urllib.request
import zipfile


class RangeReader(io.RawIOBase):
    """Read a remote file through HTTP range requests."""

    def __init__(self, url):
        self.url = url
        request = urllib.request.Request(url, method="HEAD")
        with urllib.request.urlopen(request, timeout=60) as response:
            self.size = int(response.headers["Content-Length"])
        self.position = 0

    def readable(self):
        return True

    def seekable(self):
        return True

    def tell(self):
        return self.position

    def seek(self, offset, whence=io.SEEK_SET):
        start = {io.SEEK_SET: 0, io.SEEK_CUR: self.position, io.SEEK_END: self.size}
        self.position = start[whence] + offset
        return self.position

    def readinto(self, buffer):
        if self.position >= self.size:
            return 0
        end = min(self.position + len(buffer), self.size) - 1
        headers = {"Range": f"bytes={self.position}-{end}"}
        request = urllib.request.Request(self.url, headers=headers)
        with urllib.request.urlopen(request, timeout=60) as response:
            data = response.read()
        buffer[: len(data)] = data
        self.position += len(data)
        return len(data)


reader = io.BufferedReader(RangeReader(sys.argv[1]), buffer_size=1 << 20)
names = zipfile.ZipFile(reader).namelist()
if not any(name.endswith("/libonnxruntime_providers_cuda.so") for name in names):
    sys.exit("the aarch64 wheel listing has no CUDA provider; check the wheel layout")
if any(name.endswith("/libonnxruntime_providers_tensorrt.so") for name in names):
    sys.exit("the aarch64 wheel ships the TensorRT provider; replace the source build")
PY
fi
