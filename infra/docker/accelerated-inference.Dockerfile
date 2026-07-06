ARG NVIDIA_PYTORCH_BASE_IMAGE=nvcr.io/nvidia/pytorch:26.06-py3
FROM ${NVIDIA_PYTORCH_BASE_IMAGE}

ARG IMAGE_CREATED=unknown
ARG IMAGE_SOURCE=unknown
ARG IMAGE_VERSION=2026-07-05
ARG VCS_REF=unknown
ARG ONNXRUNTIME_GPU_VERSION=1.27.0

LABEL org.opencontainers.image.title="robotics accelerated inference runtime" \
      org.opencontainers.image.description="Optional NVIDIA inference runtime with ONNX Runtime GPU, PyTorch CUDA, and TensorRT checks." \
      org.opencontainers.image.version="${IMAGE_VERSION}" \
      org.opencontainers.image.created="${IMAGE_CREATED}" \
      org.opencontainers.image.revision="${VCS_REF}" \
      org.opencontainers.image.source="${IMAGE_SOURCE}" \
      org.opencontainers.image.licenses="MIT"

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

RUN python3 -m pip install --no-cache-dir \
    "onnxruntime-gpu==${ONNXRUNTIME_GPU_VERSION}"

CMD ["bash", "-lc", "python3 -c \"import onnxruntime; import torch; import tensorrt; print('torch_cuda_available=' + str(torch.cuda.is_available())); raise SystemExit(0 if torch.cuda.is_available() else 1)\""]
