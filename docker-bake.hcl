variable "IMAGE_TAG" {
  default = "robotics/ros-jazzy-simulation:2026-07-05"
}

variable "DDS_AGENT_IMAGE_TAG" {
  default = "robotics/dds-agent:2026-07-05"
}

variable "MEDIA_IMAGE_TAG" {
  default = "robotics/media-runtime:2026-07-05"
}

variable "DIAGNOSTICS_IMAGE_TAG" {
  default = "robotics/diagnostics-runtime:2026-07-05"
}

variable "INFERENCE_IMAGE_TAG" {
  default = "robotics/accelerated-inference:2026-07-05"
}

variable "NVIDIA_PYTORCH_BASE_IMAGE" {
  default = "nvcr.io/nvidia/pytorch:26.06-py3"
}

variable "ONNXRUNTIME_GPU_VERSION" {
  default = "1.27.0"
}

variable "IMAGE_CREATED" {
  default = "unknown"
}

variable "IMAGE_SOURCE" {
  default = "local"
}

variable "IMAGE_VERSION" {
  default = "2026-07-05"
}

variable "VCS_REF" {
  default = "local"
}

variable "DOCKER_BUILD_NETWORK" {
  default = "host"
}

group "default" {
  targets = ["simulation"]
}

group "optional" {
  targets = ["dds-agent", "media-runtime", "diagnostics-runtime", "accelerated-inference"]
}

group "all" {
  targets = ["simulation", "dds-agent", "media-runtime", "diagnostics-runtime", "accelerated-inference"]
}

target "simulation" {
  context = "."
  dockerfile = "infra/docker/ros-jazzy-mavros-gazebo.Dockerfile"
  tags = [IMAGE_TAG]
  network = DOCKER_BUILD_NETWORK
  args = {
    IMAGE_CREATED = IMAGE_CREATED
    IMAGE_SOURCE = IMAGE_SOURCE
    IMAGE_VERSION = IMAGE_VERSION
    VCS_REF = VCS_REF
  }
}

target "dds-agent" {
  context = "."
  dockerfile = "infra/docker/dds-agent.Dockerfile"
  tags = [DDS_AGENT_IMAGE_TAG]
  network = DOCKER_BUILD_NETWORK
  args = {
    IMAGE_CREATED = IMAGE_CREATED
    IMAGE_SOURCE = IMAGE_SOURCE
    IMAGE_VERSION = IMAGE_VERSION
    VCS_REF = VCS_REF
  }
}

target "media-runtime" {
  context = "."
  dockerfile = "infra/docker/media-runtime.Dockerfile"
  tags = [MEDIA_IMAGE_TAG]
  network = DOCKER_BUILD_NETWORK
  args = {
    IMAGE_CREATED = IMAGE_CREATED
    IMAGE_SOURCE = IMAGE_SOURCE
    IMAGE_VERSION = IMAGE_VERSION
    VCS_REF = VCS_REF
    RUNTIME_BASE_IMAGE = IMAGE_TAG
  }
}

target "diagnostics-runtime" {
  context = "."
  dockerfile = "infra/docker/diagnostics-runtime.Dockerfile"
  tags = [DIAGNOSTICS_IMAGE_TAG]
  network = DOCKER_BUILD_NETWORK
  args = {
    IMAGE_CREATED = IMAGE_CREATED
    IMAGE_SOURCE = IMAGE_SOURCE
    IMAGE_VERSION = IMAGE_VERSION
    VCS_REF = VCS_REF
    RUNTIME_BASE_IMAGE = IMAGE_TAG
  }
}

target "accelerated-inference" {
  context = "."
  dockerfile = "infra/docker/accelerated-inference.Dockerfile"
  tags = [INFERENCE_IMAGE_TAG]
  network = DOCKER_BUILD_NETWORK
  args = {
    NVIDIA_PYTORCH_BASE_IMAGE = NVIDIA_PYTORCH_BASE_IMAGE
    ONNXRUNTIME_GPU_VERSION = ONNXRUNTIME_GPU_VERSION
    IMAGE_CREATED = IMAGE_CREATED
    IMAGE_SOURCE = IMAGE_SOURCE
    IMAGE_VERSION = IMAGE_VERSION
    VCS_REF = VCS_REF
  }
}
