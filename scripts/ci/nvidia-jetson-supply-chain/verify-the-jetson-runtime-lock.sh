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
