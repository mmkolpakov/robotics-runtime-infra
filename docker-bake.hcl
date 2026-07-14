variable "REGISTRY" {
  default = "ghcr.io/mmkolpakov"
}

variable "VERSION" {
  default = "dev"
}

variable "IMAGE_CREATED" {
  default = "1970-01-01T00:00:00Z"
}

variable "IMAGE_SOURCE" {
  default = "https://github.com/mmkolpakov/robotics-runtime-infra"
}

variable "VCS_REF" {
  default = "local"
}

variable "SOURCE_DATE_EPOCH" {
  default = "0"
}

variable "UBUNTU_SNAPSHOT" {
  default = "20260701T000000Z"
}

variable "ROS_SNAPSHOT" {
  default = "2026-06-18"
}

variable "ROSDISTRO_INDEX_REVISION" {
  default = "9f76014b84955f757306270d6860fa3bc1c30b57"
}

variable "ONNXRUNTIME_SOURCE" {
  default = "https://github.com/microsoft/onnxruntime.git?tag=v1.27.0&checksum=8f0278c77bf44b0cc83c098c6c722b92a36ac4b5"
}

variable "ONNXRUNTIME_SOURCE_DATE_EPOCH" {
  default = "1781277122"
}

group "default" {
  targets = ["simulation"]
}

group "cpu" {
  targets = [
    "simulation",
    "edge-runtime",
    "sensor-runtime",
    "inference-cpu",
    "acceptance-observer",
    "benchmark-runtime",
    "evidence-sink",
  ]
}

group "multiarch" {
  targets = [
    "edge-runtime",
    "sensor-runtime",
    "inference-cpu",
    "acceptance-observer",
    "benchmark-runtime",
    "evidence-sink",
  ]
}

group "conformance" {
  targets = [
    "provider-conformance-cpu",
    "provider-conformance-amd",
    "provider-conformance-intel",
    "provider-conformance-nvidia",
    "provider-conformance-nvidia-jetson-orin",
    "provider-conformance-nvidia-jetson-thor",
  ]
}

group "amd" {
  targets = [
    "inference-amd",
    "provider-conformance-amd",
  ]
}

group "intel" {
  targets = [
    "inference-intel",
    "provider-conformance-intel",
  ]
}

group "nvidia" {
  targets = [
    "inference-nvidia",
    "provider-conformance-nvidia",
  ]
}

group "nvidia-jetson" {
  targets = [
    "inference-nvidia-jetson-orin",
    "inference-nvidia-jetson-thor",
    "provider-conformance-nvidia-jetson-orin",
    "provider-conformance-nvidia-jetson-thor",
  ]
}

target "_common" {
  context    = "."
  dockerfile = "Dockerfile"
  args = {
    IMAGE_CREATED = IMAGE_CREATED
    IMAGE_SOURCE  = IMAGE_SOURCE
    IMAGE_VERSION = VERSION
    SOURCE_DATE_EPOCH = SOURCE_DATE_EPOCH
    VCS_REF       = VCS_REF
    UBUNTU_SNAPSHOT          = UBUNTU_SNAPSHOT
    ROS_SNAPSHOT             = ROS_SNAPSHOT
    ROSDISTRO_INDEX_REVISION = ROSDISTRO_INDEX_REVISION
  }
  labels = {
    "org.opencontainers.image.created"  = IMAGE_CREATED
    "org.opencontainers.image.revision" = VCS_REF
    "org.opencontainers.image.source"   = IMAGE_SOURCE
    "org.opencontainers.image.version"  = VERSION
  }
}

target "simulation" {
  inherits  = ["_common"]
  target    = "simulation"
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/simulation:${VERSION}"]
}

target "edge-runtime" {
  inherits  = ["_common"]
  target    = "edge-runtime"
  platforms = ["linux/amd64", "linux/arm64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/edge:${VERSION}"]
}

target "sensor-runtime" {
  inherits  = ["_common"]
  target    = "sensor-runtime"
  platforms = ["linux/amd64", "linux/arm64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/sensor:${VERSION}"]
}

target "inference-cpu" {
  inherits  = ["_common"]
  target    = "inference-cpu"
  platforms = ["linux/amd64", "linux/arm64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/inference-cpu:${VERSION}"]
}

target "provider-conformance-cpu" {
  inherits  = ["_common"]
  target    = "provider-conformance-cpu"
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/provider-conformance-cpu:${VERSION}"]
}

target "inference-amd" {
  inherits  = ["_common"]
  target    = "inference-amd"
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/inference-amd:${VERSION}"]
}

target "provider-conformance-amd" {
  inherits  = ["_common"]
  target    = "provider-conformance-amd"
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/provider-conformance-amd:${VERSION}"]
}

target "inference-intel" {
  inherits  = ["_common"]
  target    = "inference-intel"
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/inference-intel:${VERSION}"]
}

target "provider-conformance-intel" {
  inherits  = ["_common"]
  target    = "provider-conformance-intel"
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/provider-conformance-intel:${VERSION}"]
}

target "inference-nvidia" {
  inherits  = ["_common"]
  target    = "inference-nvidia"
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/inference-nvidia:${VERSION}"]
}

target "inference-nvidia-verification" {
  inherits  = ["_common"]
  target    = "inference-nvidia-verification"
  platforms = ["linux/amd64"]
}

target "provider-conformance-nvidia" {
  inherits  = ["_common"]
  target    = "provider-conformance-nvidia"
  platforms = ["linux/amd64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/provider-conformance-nvidia:${VERSION}"]
}

target "_onnxruntime-jetson-source" {
  inherits  = ["_common"]
  contexts = {
    "onnxruntime-source" = ONNXRUNTIME_SOURCE
  }
}

target "onnxruntime-jetson-source-verification" {
  inherits  = ["_onnxruntime-jetson-source"]
  target    = "onnxruntime-jetson-source-verification"
  platforms = ["linux/amd64"]
}

target "onnxruntime-jetson-build-dependencies" {
  inherits  = ["_common"]
  target    = "onnxruntime-jetson-build-dependencies"
  platforms = ["linux/arm64"]
}

target "_nvidia-jetson" {
  inherits  = ["_onnxruntime-jetson-source"]
  platforms = ["linux/arm64"]
  args = {
    ONNXRUNTIME_SOURCE_DATE_EPOCH = ONNXRUNTIME_SOURCE_DATE_EPOCH
  }
}

target "onnxruntime-jetson-wheel" {
  inherits = ["_nvidia-jetson"]
  target   = "onnxruntime-jetson-wheel"
}

target "inference-nvidia-jetson-orin" {
  inherits = ["_nvidia-jetson"]
  target   = "inference-nvidia-jetson-orin"
  tags     = ["${REGISTRY}/robotics-runtime-infra/inference-nvidia-jetson-orin:${VERSION}"]
}

target "inference-nvidia-jetson-thor" {
  inherits = ["_nvidia-jetson"]
  target   = "inference-nvidia-jetson-thor"
  tags     = ["${REGISTRY}/robotics-runtime-infra/inference-nvidia-jetson-thor:${VERSION}"]
}

target "provider-conformance-nvidia-jetson-orin" {
  inherits = ["_nvidia-jetson"]
  target   = "provider-conformance-nvidia-jetson-orin"
  tags     = ["${REGISTRY}/robotics-runtime-infra/provider-conformance-nvidia-jetson-orin:${VERSION}"]
}

target "provider-conformance-nvidia-jetson-thor" {
  inherits = ["_nvidia-jetson"]
  target   = "provider-conformance-nvidia-jetson-thor"
  tags     = ["${REGISTRY}/robotics-runtime-infra/provider-conformance-nvidia-jetson-thor:${VERSION}"]
}

target "acceptance-observer" {
  inherits  = ["_common"]
  target    = "acceptance-observer"
  platforms = ["linux/amd64", "linux/arm64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/acceptance-observer:${VERSION}"]
}

target "benchmark-runtime" {
  inherits  = ["_common"]
  target    = "benchmark-runtime"
  platforms = ["linux/amd64", "linux/arm64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/benchmark:${VERSION}"]
}

target "evidence-sink" {
  inherits  = ["_common"]
  target    = "evidence-sink"
  platforms = ["linux/amd64", "linux/arm64"]
  tags      = ["${REGISTRY}/robotics-runtime-infra/evidence-sink:${VERSION}"]
}
