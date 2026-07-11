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
