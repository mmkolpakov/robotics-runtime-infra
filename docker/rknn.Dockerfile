# syntax=docker/dockerfile:1.19

ARG PYTHON_BASE_IMAGE=python:3.12-slim-bookworm@sha256:8a7e7cc04fd3e2bd787f7f24e22d5d119aa590d429b50c95dfe12b3abe52f48b
ARG UBUNTU_BASE_IMAGE=ubuntu:24.04@sha256:4fbb8e6a8395de5a7550b33509421a2bafbc0aab6c06ba2cef9ebffbc7092d90
ARG UV_IMAGE=ghcr.io/astral-sh/uv:0.11.28@sha256:0f36cb9361a3346885ca3677e3767016687b5a170c1a6b88465ec14aefec90aa
ARG UBUNTU_SNAPSHOT=20260701T000000Z
ARG DEBIAN_SNAPSHOT=20260701T000000Z

FROM ${UV_IMAGE} AS uv

FROM ${UBUNTU_BASE_IMAGE} AS rknn-source-verification

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

# hadolint ignore=DL3022
COPY --from=rknn-source LICENSE /verification/LICENSE
# hadolint ignore=DL3022
COPY --from=rknn-source \
    rknn-toolkit2/packages/x86_64/rknn_toolkit2-2.3.2-cp312-cp312-manylinux_2_17_x86_64.manylinux2014_x86_64.whl \
    /verification/rknn_toolkit2.whl
# hadolint ignore=DL3022
COPY --from=rknn-source \
    rknn-toolkit-lite2/packages/rknn_toolkit_lite2-2.3.2-cp312-cp312-manylinux_2_17_aarch64.manylinux2014_aarch64.whl \
    /verification/rknn_toolkit_lite2.whl
# hadolint ignore=DL3022
COPY --from=rknn-source \
    rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so \
    /verification/librknnrt.so

RUN printf '%s  %s\n' \
      504d7fcf6a792dfa874e25155de0afb5d6650f04a1a0d49b0886934bec4741ef \
      /verification/rknn_toolkit2.whl \
      e1e4ec691fed900c0e6fde5e7d8eeba17f806aa45092b63b361ee775e2c1b50e \
      /verification/rknn_toolkit_lite2.whl \
      d31fc19c85b85f6091b2bd0f6af9d962d5264a4e410bfb536402ec92bac738e8 \
      /verification/librknnrt.so \
      | sha256sum --check --strict \
    && test -s /verification/LICENSE

FROM ${PYTHON_BASE_IMAGE} AS rknn-converter

ARG DEBIAN_SNAPSHOT

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

COPY --from=uv /uv /uvx /usr/local/bin/
# hadolint ignore=DL3022
COPY --from=rknn-source LICENSE /usr/share/licenses/rknn-toolkit2/LICENSE

RUN printf '%s\n' \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian/${DEBIAN_SNAPSHOT} bookworm main" \
      "deb [check-valid-until=no] https://snapshot.debian.org/archive/debian-security/${DEBIAN_SNAPSHOT} bookworm-security main" \
      > /etc/apt/sources.list \
    && rm -f /etc/apt/sources.list.d/debian.sources \
    && apt-get -o Acquire::Check-Valid-Until=false update \
    && apt-get install -y --no-install-recommends \
      libgl1=1.6.0-1 \
      libglib2.0-0=2.74.6-2+deb12u9 \
      libgomp1=12.2.0-14+deb12u1 \
    && groupadd --gid 1000 robotics \
    && useradd --create-home --uid 1000 --gid 1000 robotics \
    && rm -rf /var/lib/apt/lists/*

COPY docker/python/rknn-converter.lock /tmp/python/rknn-converter.lock

RUN --mount=type=cache,id=rknn-converter-uv,target=/root/.cache/uv,sharing=locked \
    uv venv --python /usr/local/bin/python3 /opt/venv \
    && uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-deps \
      --requirement /tmp/python/rknn-converter.lock \
    && uv pip check --python /opt/venv/bin/python \
    && install -d /usr/share/rknn-toolkit2 \
    && uv pip freeze --python /opt/venv/bin/python \
      > /usr/share/rknn-toolkit2/python-packages.txt \
    && /opt/venv/bin/python -c "import pkg_resources" \
    && python3 -c "from pathlib import Path; assert Path('/usr/share/licenses/rknn-toolkit2/LICENSE').stat().st_size > 0" \
    && rm -rf /tmp/python

ENV PATH="/opt/venv/bin:${PATH}" \
    PYTHONUNBUFFERED=1

LABEL org.opencontainers.image.title="RKNN Toolkit2 model converter" \
      org.opencontainers.image.description="Pinned x86 conversion environment for RK3588 model artifacts."

USER robotics
WORKDIR /workspace

ENTRYPOINT ["python3"]
CMD ["-c", "from rknn.api import RKNN; print(RKNN)"]

HEALTHCHECK NONE

FROM rknn-converter AS rknn-converter-verification

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3022
COPY --from=rknn-source --chown=robotics:robotics \
    rknn-toolkit2/examples/functions/onnx_edit/ \
    /opt/rknn-verification/

USER robotics
WORKDIR /opt/rknn-verification

RUN --network=none printf '%s  %s\n' \
      4924f6503a98194a75a32adc82ac4b9ff3016ac7e6cffa798b627c9ab4a063d4 \
      concat_block.onnx \
      56a2219543243e5d2222d6ae34b907c0bf492adc969ab07cbb6bcc1f539aa6e0 \
      concat_block_input_0.npy \
      1682ec66e2802abefcda21edc301d0cd8336da995a301a5bd1ca6768cc931557 \
      concat_block_input_1.npy \
      601f535b24524a58536c5b843c56c599e8530887b3913e57cb85bd08b7ef0e18 \
      dataset.txt \
      52f58253ab74736f2d4439ad2c2f1e3e3b4130fa0845d245a673b5e74b0f97c7 \
      test.py \
      | sha256sum --check --strict \
    && python3 test.py \
    && test -s concat_block.rknn \
    && test -s concat_block_edited.rknn \
    && sha256sum concat_block.rknn concat_block_edited.rknn \
      > /tmp/converter-output.sha256

ENTRYPOINT ["sha256sum"]
CMD ["concat_block.rknn", "concat_block_edited.rknn"]

# The image name is supplied by the BuildKit named context in docker-bake.hcl.
# hadolint ignore=DL3006
FROM ubuntu-ca AS rknn-benchmark-builder

ARG UBUNTU_SNAPSHOT

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
COPY --chmod=0555 docker/apt/use-package-snapshots /usr/local/sbin/use-package-snapshots
# hadolint ignore=DL3022
COPY --from=rknn-source rknpu2/ /src/rknpu2/

RUN --mount=type=cache,id=rknn-noble-arm64-apt-lists,target=/var/lib/apt/lists,sharing=locked \
    --mount=type=cache,id=rknn-noble-arm64-apt-cache,target=/var/cache/apt,sharing=locked \
    UBUNTU_SNAPSHOT="${UBUNTU_SNAPSHOT}" \
      /usr/local/sbin/use-package-snapshots \
    && apt-get update \
    && apt-get install -y --no-install-recommends \
      cmake \
      g++ \
      gcc \
      ninja-build \
      zlib1g-dev \
    && printf '%s  %s\n' \
      d31fc19c85b85f6091b2bd0f6af9d962d5264a4e410bfb536402ec92bac738e8 \
      /src/rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so \
      | sha256sum --check --strict \
    && command -v aarch64-linux-gnu-gcc \
    && command -v aarch64-linux-gnu-g++ \
    && cmake \
      -G Ninja \
      -S /src/rknpu2/examples/rknn_benchmark \
      -B /tmp/rknn-benchmark-build \
      -DCMAKE_BUILD_TYPE=Release \
      -DCMAKE_C_COMPILER=/usr/bin/aarch64-linux-gnu-gcc \
      -DCMAKE_CXX_COMPILER=/usr/bin/aarch64-linux-gnu-g++ \
      -DCMAKE_CXX_STANDARD_LIBRARIES=-lz \
      -DCMAKE_SKIP_RPATH=TRUE \
    && cmake --build /tmp/rknn-benchmark-build --parallel 2 \
    && install -D -m 0555 \
      /tmp/rknn-benchmark-build/rknn_benchmark \
      /out/rknn_benchmark \
    && readelf -d /out/rknn_benchmark \
      | grep -Fq 'Shared library: [librknnrt.so]' \
    && ! readelf -d /out/rknn_benchmark | grep -Eq 'RPATH|RUNPATH' \
    && rm -rf \
      /src/rknpu2 \
      /tmp/rknn-benchmark-build

USER 65534:65534

# The image name is supplied by the BuildKit named context in docker-bake.hcl.
# hadolint ignore=DL3006
FROM edge-runtime AS inference-rknn-rk3588

SHELL ["/bin/bash", "-o", "pipefail", "-c"]

USER root
COPY --from=uv /uv /uvx /usr/local/bin/
COPY --from=rknn-benchmark-builder /out/rknn_benchmark /usr/local/bin/rknn_benchmark
# hadolint ignore=DL3022
COPY --from=rknn-source \
    rknpu2/runtime/Linux/librknn_api/aarch64/librknnrt.so \
    /usr/lib/aarch64-linux-gnu/librknnrt.so
# hadolint ignore=DL3022
COPY --from=rknn-source LICENSE /usr/share/licenses/rknn-toolkit2/LICENSE
COPY docker/python/rknn-runtime.lock /tmp/python/rknn-runtime.lock

RUN --mount=type=cache,id=rknn-runtime-uv,target=/root/.cache/uv,sharing=locked \
    printf '%s  %s\n' \
      d31fc19c85b85f6091b2bd0f6af9d962d5264a4e410bfb536402ec92bac738e8 \
      /usr/lib/aarch64-linux-gnu/librknnrt.so \
      | sha256sum --check --strict \
    && ldconfig \
    && uv venv --python /usr/bin/python3 --system-site-packages /opt/venv \
    && uv pip install \
      --python /opt/venv/bin/python \
      --require-hashes \
      --no-deps \
      --requirement /tmp/python/rknn-runtime.lock \
    && uv pip check --python /opt/venv/bin/python \
    && /opt/venv/bin/python -c \
      "from rknnlite.api import RKNNLite; assert RKNNLite is not None; print('rknnlite-import-ok')" \
    && ldd /usr/local/bin/rknn_benchmark \
      | tee /tmp/rknn-benchmark.ldd \
    && grep -Eq \
      'librknnrt\.so => /(usr/)?lib/aarch64-linux-gnu/librknnrt\.so ' \
      /tmp/rknn-benchmark.ldd \
    && test -s /usr/share/licenses/rknn-toolkit2/LICENSE \
    && rm -rf /tmp/python /tmp/rknn-benchmark.ldd

ENV LD_LIBRARY_PATH=/usr/lib/aarch64-linux-gnu \
    PATH="/opt/venv/bin:${PATH}" \
    ROBOTICS_RKNN_TARGET=rk3588

LABEL org.opencontainers.image.title="RK3588 RKNN inference runtime" \
      org.opencontainers.image.description="ROS 2 Jazzy runtime with RKNN Lite2 and the official RKNN benchmark."

USER ubuntu
WORKDIR /workspace

CMD ["python3", "-c", "from rknnlite.api import RKNNLite; print(RKNNLite)"]

HEALTHCHECK NONE

FROM inference-rknn-rk3588 AS provider-conformance-rknn-rk3588

USER root
SHELL ["/bin/bash", "-o", "pipefail", "-c"]
# hadolint ignore=DL3022
COPY --from=rknn-source \
    rknn-toolkit-lite2/examples/resnet18/resnet18_for_rk3588.rknn \
    /opt/rknn-verification/resnet18_for_rk3588.rknn
# hadolint ignore=DL3022
COPY --from=rknn-source \
    rknn-toolkit-lite2/examples/resnet18/space_shuttle_224.jpg \
    /opt/rknn-verification/space_shuttle_224.jpg

RUN printf '%s  %s\n' \
      f56ade1677a2081e4bd8dbc84541b6d5da64654244c4ecb04f59f8d5c13006bf \
      /opt/rknn-verification/resnet18_for_rk3588.rknn \
      a827cc9060d15cd34b1b5ac512f4d6d8366416a5874a2075951991cbacef78d4 \
      /opt/rknn-verification/space_shuttle_224.jpg \
      | sha256sum --check --strict \
    && chown -R ubuntu:ubuntu /opt/rknn-verification

LABEL org.opencontainers.image.title="RK3588 RKNN hardware conformance" \
      org.opencontainers.image.description="Official RKNN benchmark and fixed RK3588 fixture for the protected hardware gate."

USER ubuntu
WORKDIR /opt/rknn-verification

ENTRYPOINT ["/usr/local/bin/rknn_benchmark"]
CMD ["resnet18_for_rk3588.rknn", "space_shuttle_224.jpg", "10", "7"]

HEALTHCHECK NONE
