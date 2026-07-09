unexport BASH_ENV

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c
.DEFAULT_GOAL := help

ifneq (,$(wildcard .env))
include .env
export
endif

PYTHON ?= python3
VENV_DIR ?= .venv
VENV_PYTHON := $(VENV_DIR)/bin/python
VENV_BIN := $(VENV_DIR)/bin
DEV_REQUIREMENTS := requirements-dev.txt
BOOTSTRAP_STAMP := $(VENV_DIR)/.requirements-dev.stamp
CHECK_JSONSCHEMA := $(VENV_BIN)/check-jsonschema
YAMLLINT := $(VENV_BIN)/yamllint
PRE_COMMIT := $(VENV_BIN)/pre-commit
IMAGE_TAG ?= robotics/ros-jazzy-simulation:2026-07-05
DDS_AGENT_IMAGE_TAG ?= robotics/dds-agent:2026-07-05
MEDIA_IMAGE_TAG ?= robotics/media-runtime:2026-07-05
DIAGNOSTICS_IMAGE_TAG ?= robotics/diagnostics-runtime:2026-07-05
INFERENCE_IMAGE_TAG ?= robotics/accelerated-inference:2026-07-05
NVIDIA_PYTORCH_BASE_IMAGE ?= nvcr.io/nvidia/pytorch:26.06-py3
ONNXRUNTIME_GPU_VERSION ?= 1.27.0
IMAGE_SOURCE ?= local
IMAGE_VERSION ?= 2026-07-05
VCS_REF ?= local
IMAGE_CREATED ?= unknown
DOCKER_BUILD_NETWORK ?= host
DOCKER_RUN_NETWORK ?= bridge
DOCKER_BUILD_RETRIES ?= 3
DOCKER_INSPECT_RETRIES ?= 6
COMPOSE ?= docker compose
BAKE ?= docker buildx bake
BAKE_ALLOW ?= --allow=network.host
COMPOSE_FILE := compose.yaml
DEV_SERVICE ?= simulation-dev
RUN_ID ?=
RUNS_ROOT ?= runs
REPORT_DIR ?= $(RUNS_ROOT)/$(RUN_ID)/reports
SECURITY_DIR ?= $(RUNS_ROOT)/$(RUN_ID)/security
ROS_DOMAIN_ID ?=
TRIVY_IMAGE ?= aquasec/trivy:0.72.0
TRIVY_DB_REPOSITORY ?= ghcr.io/aquasecurity/trivy-db:2
TRIVY_GATE_SEVERITY ?= HIGH,CRITICAL
TRIVY_IGNORE_FILE ?= .trivyignore
TRIVY_CACHE_DIR ?= tmp/trivy-cache
HADOLINT_IMAGE ?= hadolint/hadolint:v2.14.0
ACTIONLINT_IMAGE ?= rhysd/actionlint:1.7.12
STACK_MANIFEST := infra/stack/simulation-stack.json
STACK_SCHEMA := contracts/infra/stack.v1.schema.json
RUNTIME_PROFILES := infra/stack/runtime-profiles.json
RUNTIME_PROFILES_SCHEMA := contracts/infra/runtime-profiles.v1.schema.json
EVIDENCE_MANIFEST_EXAMPLE := infra/stack/evidence-manifest.example.json
EVIDENCE_MANIFEST_SCHEMA := contracts/infra/evidence-manifest.v1.schema.json
EVIDENCE_MANIFEST_FILTER := infra/stack/evidence-manifest.jq
EVIDENCE_MANIFEST := $(REPORT_DIR)/evidence-manifest.json
INFRA_RELEASE := infra/stack/infra-release.json
INFRA_RELEASE_SCHEMA := contracts/infra/infra-release.v1.schema.json
DOCKERFILE := infra/docker/ros-jazzy-mavros-gazebo.Dockerfile
DOCKERFILES := $(DOCKERFILE) infra/docker/accelerated-inference.Dockerfile infra/docker/dds-agent.Dockerfile infra/docker/media-runtime.Dockerfile infra/docker/diagnostics-runtime.Dockerfile

.PHONY: help bootstrap validate validate-json validate-yaml compose-config lint lint-dockerfile lint-actions profiles review \
	dev-up dev-shell dev-logs dev-ps dev-down \
	docker-manifests docker-pull bake-build compose-build compose-smoke compose-autopilot-smoke compose-ardupilot-smoke \
	compose-px4-smoke compose-dds-smoke compose-comms-smoke compose-media-smoke compose-diagnostics-smoke \
	compose-sensor-smoke compose-artifact-tooling-smoke integration-smoke joint-motion-smoke \
	compose-gpu-smoke compose-accelerated-inference-smoke \
	compose-render-smoke compose-edge-config optional-smoke docker-metadata docker-update-check \
	evidence-manifest sbom security-scan security-gate pre-commit ci clean allocate-run prepare-run parallel-isolation-smoke unit-tests


allocate-run:
	@if [[ -z "$(RUN_ID)" ]]; then echo "RUN_ID is required" >&2; exit 2; fi
	@mkdir -p "$(RUNS_ROOT)/$(RUN_ID)/dds" "$(REPORT_DIR)" "$(SECURITY_DIR)" "$(RUNS_ROOT)/$(RUN_ID)/smoke" "$(RUNS_ROOT)/$(RUN_ID)/data"
	@cp infra/dds/fastdds-profile.template.xml "$(RUNS_ROOT)/$(RUN_ID)/dds/fastdds-profile.xml"
	@ln -sfn "$(RUN_ID)" "$(RUNS_ROOT)/current"
	@$(PYTHON) infra/scripts/allocate_domain_id.py --run-id "$(RUN_ID)" --runs-root "$(RUNS_ROOT)" > "$(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt"
	@echo "Allocated ROS_DOMAIN_ID=$$(cat "$(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt") for RUN_ID=$(RUN_ID)"

prepare-run: allocate-run
	@test -s "$(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt"

unit-tests:
	"$(VENV_PYTHON)" -m pytest tests/test_check_apt_versions.py tests/test_allocate_domain_id.py -q

help:
	@printf '%s\n' \
		'Common commands:' \
		'  docker compose build simulation' \
		'  docker compose --profile dev up --detach --wait simulation-dev' \
		'  docker compose --profile dev exec simulation-dev bash' \
		'' \
		'Make shortcuts:' \
		'  make bootstrap      Install local validation tools into .venv' \
		'  make validate       Validate schemas, YAML and Compose config' \
		'  make bake-build     Build simulation image with Docker Buildx Bake' \
		'  make dev-up         Build and start the background dev container' \
		'  make dev-shell      Open a shell in the background dev container' \
		'  make dev-down       Stop and remove the background dev container' \
		'  make review         Run the review gate used before handoff' \
		'  make ci             Run the full local CI gate'

bootstrap: $(BOOTSTRAP_STAMP)

$(BOOTSTRAP_STAMP): $(DEV_REQUIREMENTS)
	$(PYTHON) -m venv "$(VENV_DIR)"
	"$(VENV_PYTHON)" -m pip install --upgrade pip
	"$(VENV_PYTHON)" -m pip install --disable-pip-version-check -r "$(DEV_REQUIREMENTS)"
	touch "$(BOOTSTRAP_STAMP)"

validate: bootstrap unit-tests validate-json validate-yaml compose-config

validate-json: bootstrap
	@if [[ -z "$(RUN_ID)" ]]; then $(MAKE) RUN_ID=validate allocate-run; fi
	$(eval RUN_ID := $(if $(RUN_ID),$(RUN_ID),validate))
	mkdir -p "$(RUNS_ROOT)/$(RUN_ID)/reports"
	"$(CHECK_JSONSCHEMA)" --schemafile "$(STACK_SCHEMA)" "$(STACK_MANIFEST)"
	"$(CHECK_JSONSCHEMA)" --schemafile "$(INFRA_RELEASE_SCHEMA)" "$(INFRA_RELEASE)"
	"$(CHECK_JSONSCHEMA)" --schemafile "$(RUNTIME_PROFILES_SCHEMA)" "$(RUNTIME_PROFILES)"
	"$(CHECK_JSONSCHEMA)" --schemafile "$(EVIDENCE_MANIFEST_SCHEMA)" "$(EVIDENCE_MANIFEST_EXAMPLE)"
	"$(VENV_PYTHON)" -m json.tool .devcontainer/devcontainer.json > "$(REPORT_DIR)/devcontainer.json"
	"$(VENV_PYTHON)" -m json.tool "$(STACK_MANIFEST)" > "$(REPORT_DIR)/simulation-stack.json"
	"$(VENV_PYTHON)" -m json.tool "$(STACK_SCHEMA)" > "$(REPORT_DIR)/stack.v1.schema.json"
	"$(VENV_PYTHON)" -m json.tool "$(INFRA_RELEASE)" > "$(REPORT_DIR)/infra-release.json"
	"$(VENV_PYTHON)" -m json.tool "$(INFRA_RELEASE_SCHEMA)" > "$(REPORT_DIR)/infra-release.v1.schema.json"
	"$(VENV_PYTHON)" -m json.tool "$(RUNTIME_PROFILES)" > "$(REPORT_DIR)/runtime-profiles.json"
	"$(VENV_PYTHON)" -m json.tool "$(RUNTIME_PROFILES_SCHEMA)" > "$(REPORT_DIR)/runtime-profiles.v1.schema.json"
	"$(VENV_PYTHON)" -m json.tool "$(EVIDENCE_MANIFEST_EXAMPLE)" > "$(REPORT_DIR)/evidence-manifest.example.json"
	"$(VENV_PYTHON)" -m json.tool "$(EVIDENCE_MANIFEST_SCHEMA)" > "$(REPORT_DIR)/evidence-manifest.v1.schema.json"

validate-yaml: bootstrap
	"$(YAMLLINT)" .github .yamllint.yml "$(COMPOSE_FILE)" compose.override.yaml.example config

compose-config:
	@if [[ -z "$(RUN_ID)" ]]; then $(MAKE) RUN_ID=compose-config allocate-run; RUN_ID=compose-config; else $(MAKE) RUN_ID="$(RUN_ID)" allocate-run; fi
	@run_id="$(if $(RUN_ID),$(RUN_ID),compose-config)"; \
	ros_domain_id="$$(cat "$(RUNS_ROOT)/$${run_id}/ros_domain_id.txt")"; \
	mkdir -p "$(RUNS_ROOT)/$${run_id}/reports"; \
	for profile_args in \
		"" \
		"--profile autopilot" \
		"--profile ardupilot" \
		"--profile px4" \
		"--profile dds" \
		"--profile comms" \
		"--profile media" \
		"--profile diagnostics" \
		"--profile dev" \
		"--profile render" \
		"--profile nvidia" \
		"--profile inference" \
		"--profile edge"; do \
		name="default"; \
		if [[ -n "$${profile_args}" ]]; then name="$${profile_args##* }"; fi; \
		ROS_DOMAIN_ID="$${ros_domain_id}" FASTRTPS_DEFAULT_PROFILES_FILE="$(RUNS_ROOT)/$${run_id}/dds/fastdds-profile.xml" \
			$(COMPOSE) -f "$(COMPOSE_FILE)" $${profile_args} config > "$(RUNS_ROOT)/$${run_id}/reports/compose.$${name}.yaml"; \
	done; \
	if grep -n 'network_mode:[[:space:]]*host' "$(RUNS_ROOT)/$${run_id}/reports/compose.default.yaml"; then exit 1; fi

lint: lint-dockerfile lint-actions

lint-dockerfile:
	@if [[ -z "$(RUN_ID)" ]]; then $(MAKE) RUN_ID=lint allocate-run; fi
	$(eval RUN_ID := $(if $(RUN_ID),$(RUN_ID),lint))
	mkdir -p "$(RUNS_ROOT)/$(RUN_ID)/reports"
	docker run --rm \
		-v "$(CURDIR):/repo:ro" \
		-w /repo \
		"$(HADOLINT_IMAGE)" \
		hadolint $(DOCKERFILES) 2>&1 | tee "$(REPORT_DIR)/hadolint.txt"

lint-actions:
	@if [[ -z "$(RUN_ID)" ]]; then $(MAKE) RUN_ID=lint allocate-run; fi
	$(eval RUN_ID := $(if $(RUN_ID),$(RUN_ID),lint))
	mkdir -p "$(RUNS_ROOT)/$(RUN_ID)/reports"
	docker run --rm \
		-v "$(CURDIR):/repo:ro" \
		-w /repo \
		"$(ACTIONLINT_IMAGE)" \
		-color=false .github/workflows/*.yml 2>&1 | tee "$(REPORT_DIR)/actionlint.txt"

profiles:
	@if [[ -z "$(RUN_ID)" ]]; then $(MAKE) RUN_ID=lint allocate-run; fi
	$(eval RUN_ID := $(if $(RUN_ID),$(RUN_ID),lint))
	mkdir -p "$(RUNS_ROOT)/$(RUN_ID)/reports"
	jq -r '.profiles | to_entries[] | [.key, .value.status, .value.release_gate, .value.purpose] | @tsv' \
		"$(RUNTIME_PROFILES)" | tee "$(REPORT_DIR)/runtime-profiles.tsv"

review: validate lint profiles compose-build compose-smoke compose-sensor-smoke compose-artifact-tooling-smoke integration-smoke joint-motion-smoke \
	compose-autopilot-smoke docker-metadata security-scan security-gate sbom evidence-manifest

docker-manifests:
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until docker buildx imagetools inspect osrf/ros:jazzy-simulation > "$(REPORT_DIR)/ros-base-image.txt"; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_INSPECT_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done
	n=0; \
	until docker buildx imagetools inspect ardupilot/ardupilot-dev-base:v0.2.0 > "$(REPORT_DIR)/ardupilot-base-image.txt"; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_INSPECT_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done

docker-pull:
	docker pull osrf/ros:jazzy-simulation
	docker pull ardupilot/ardupilot-dev-base:v0.2.0

bake-build:
	mkdir -p "$(REPORT_DIR)"
	IMAGE_TAG="$(IMAGE_TAG)" \
		DDS_AGENT_IMAGE_TAG="$(DDS_AGENT_IMAGE_TAG)" \
		MEDIA_IMAGE_TAG="$(MEDIA_IMAGE_TAG)" \
		DIAGNOSTICS_IMAGE_TAG="$(DIAGNOSTICS_IMAGE_TAG)" \
		INFERENCE_IMAGE_TAG="$(INFERENCE_IMAGE_TAG)" \
		NVIDIA_PYTORCH_BASE_IMAGE="$(NVIDIA_PYTORCH_BASE_IMAGE)" \
		ONNXRUNTIME_GPU_VERSION="$(ONNXRUNTIME_GPU_VERSION)" \
		IMAGE_CREATED="$(IMAGE_CREATED)" \
		IMAGE_SOURCE="$(IMAGE_SOURCE)" \
		IMAGE_VERSION="$(IMAGE_VERSION)" \
		VCS_REF="$(VCS_REF)" \
		DOCKER_BUILD_NETWORK="$(DOCKER_BUILD_NETWORK)" \
			$(BAKE) $(BAKE_ALLOW) simulation

compose-build: prepare-run
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until IMAGE_TAG="$(IMAGE_TAG)" \
		IMAGE_CREATED="$(IMAGE_CREATED)" \
		IMAGE_SOURCE="$(IMAGE_SOURCE)" \
		IMAGE_VERSION="$(IMAGE_VERSION)" \
		VCS_REF="$(VCS_REF)" \
		DOCKER_BUILD_NETWORK="$(DOCKER_BUILD_NETWORK)" \
		ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" \
		FASTRTPS_DEFAULT_PROFILES_FILE="$(RUNS_ROOT)/$(RUN_ID)/dds/fastdds-profile.xml" \
			$(COMPOSE) -f "$(COMPOSE_FILE)" build simulation; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_BUILD_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done

dev-up: compose-build
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev up --detach --wait --no-build "$(DEV_SERVICE)"

dev-shell: prepare-run
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev exec "$(DEV_SERVICE)" \
		bash -lc 'source /etc/profile.d/robotics_ros_setup.sh && exec bash -i'

dev-logs: prepare-run
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev logs --follow "$(DEV_SERVICE)"

dev-ps: prepare-run
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev ps "$(DEV_SERVICE)"

dev-down: prepare-run
	# `down` (not `stop` + `rm`) so the per-run `robotics-sim` bridge network
	# this run's dev container joined is also removed; `stop`+`rm` leaves it
	# behind, which leaks resources across parallel/serial runs.
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev down --remove-orphans "$(DEV_SERVICE)" || true

compose-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" run --rm --no-deps simulation \
		2>&1 | tee "$(REPORT_DIR)/compose-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" down --remove-orphans || true; \
	exit $$rc

compose-autopilot-smoke:
	$(MAKE) compose-ardupilot-smoke

compose-ardupilot-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile ardupilot run --rm --no-deps autopilot-base \
		2>&1 | tee "$(REPORT_DIR)/compose-autopilot-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" --profile ardupilot down --remove-orphans || true; \
	exit $$rc

compose-px4-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile px4 run --rm --no-deps px4-sitl \
		2>&1 | tee "$(REPORT_DIR)/compose-px4-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" --profile px4 down --remove-orphans || true; \
	exit $$rc

compose-dds-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until $(COMPOSE) -f "$(COMPOSE_FILE)" --profile dds build dds-agent; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_BUILD_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done
	rc=0; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dds run --rm --no-deps dds-agent \
		2>&1 | tee "$(REPORT_DIR)/compose-dds-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" --profile dds down --remove-orphans || true; \
	exit $$rc

compose-comms-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile comms run --rm --no-deps comms-bridge \
		2>&1 | tee "$(REPORT_DIR)/compose-comms-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" --profile comms down --remove-orphans || true; \
	exit $$rc

compose-media-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until $(COMPOSE) -f "$(COMPOSE_FILE)" --profile media build media-runtime; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_BUILD_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile media run --rm --no-deps media-runtime \
		2>&1 | tee "$(REPORT_DIR)/compose-media-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" --profile media down --remove-orphans || true; \
	exit $$rc

compose-diagnostics-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until $(COMPOSE) -f "$(COMPOSE_FILE)" --profile diagnostics build diagnostics-runtime; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_BUILD_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile diagnostics run --rm --no-deps diagnostics-runtime \
		2>&1 | tee "$(REPORT_DIR)/compose-diagnostics-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" --profile diagnostics down --remove-orphans || true; \
	exit $$rc

compose-sensor-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" run --rm --no-deps simulation \
		bash -lc 'source /etc/profile.d/robotics_ros_setup.sh \
			&& ros2 interface show sensor_msgs/msg/Image >/dev/null \
			&& ros2 interface show sensor_msgs/msg/CameraInfo >/dev/null \
			&& ros2 interface show sensor_msgs/msg/PointCloud2 >/dev/null \
			&& ros2 interface show tf2_msgs/msg/TFMessage >/dev/null \
			&& image_transport_prefix="$$(ros2 pkg prefix image_transport)" \
			&& printf "%s\n" \
				"sensor_msgs/msg/Image: ok" \
				"sensor_msgs/msg/CameraInfo: ok" \
				"sensor_msgs/msg/PointCloud2: ok" \
				"tf2_msgs/msg/TFMessage: ok" \
				"image_transport: $${image_transport_prefix}"' \
		2>&1 | tee "$(REPORT_DIR)/compose-sensor-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" down --remove-orphans || true; \
	exit $$rc

compose-artifact-tooling-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" run --rm --no-deps simulation \
		bash -lc 'aws --version | grep -E "^aws-cli/2\.35\.17 " && source /etc/profile.d/robotics_ros_setup.sh && ros2 pkg prefix ros_gz_sim >/dev/null' \
		2>&1 | tee "$(REPORT_DIR)/compose-artifact-tooling-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" down --remove-orphans || true; \
	exit $$rc

integration-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" run --rm --no-deps \
		-e SMOKE_LOG_DIR=/workspace/runs/$(RUN_ID)/smoke \
		simulation \
		python3 /workspace/infra/smoke/launch_testing/test_integration.py \
		2>&1 | tee "$(REPORT_DIR)/integration-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" -p "robotics-$(RUN_ID)" down --remove-orphans || true; \
	exit $$rc

joint-motion-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" run --rm --no-deps \
		-e SMOKE_LOG_DIR=/workspace/runs/$(RUN_ID)/smoke \
		-e SMOKE_JOINT_METRICS_PATH=/workspace/runs/$(RUN_ID)/reports/joint_motion_metrics.json \
		simulation \
		python3 /workspace/infra/smoke/launch_testing/test_joint_motion.py \
		2>&1 | tee "$(REPORT_DIR)/joint-motion-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" -p "robotics-$(RUN_ID)" down --remove-orphans || true; \
	exit $$rc

compose-gpu-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile nvidia run --rm --no-deps nvidia-gpu \
		2>&1 | tee "$(REPORT_DIR)/compose-gpu-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" --profile nvidia down --remove-orphans || true; \
	exit $$rc

compose-accelerated-inference-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until INFERENCE_IMAGE_TAG="$(INFERENCE_IMAGE_TAG)" \
		NVIDIA_PYTORCH_BASE_IMAGE="$(NVIDIA_PYTORCH_BASE_IMAGE)" \
		ONNXRUNTIME_GPU_VERSION="$(ONNXRUNTIME_GPU_VERSION)" \
		IMAGE_CREATED="$(IMAGE_CREATED)" \
		IMAGE_SOURCE="$(IMAGE_SOURCE)" \
		IMAGE_VERSION="$(IMAGE_VERSION)" \
		VCS_REF="$(VCS_REF)" \
		DOCKER_BUILD_NETWORK="$(DOCKER_BUILD_NETWORK)" \
			$(COMPOSE) -f "$(COMPOSE_FILE)" --profile inference build accelerated-inference; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_BUILD_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done
	rc=0; \
	INFERENCE_IMAGE_TAG="$(INFERENCE_IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile inference run --rm --no-deps accelerated-inference \
		2>&1 | tee "$(REPORT_DIR)/compose-accelerated-inference-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" --profile inference down --remove-orphans || true; \
	exit $$rc

compose-render-smoke: prepare-run
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" FASTRTPS_DEFAULT_PROFILES_FILE="/workspace/runs/$(RUN_ID)/dds/fastdds-profile.xml" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile render run --rm --no-deps local-render \
		2>&1 | tee "$(REPORT_DIR)/compose-render-smoke.txt" || rc=$$?; \
	ROS_DOMAIN_ID="$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" COMPOSE_PROJECT_NAME="robotics-$(RUN_ID)" $(COMPOSE) -f "$(COMPOSE_FILE)" --profile render down --remove-orphans || true; \
	exit $$rc

compose-edge-config:
	mkdir -p "$(REPORT_DIR)"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile edge config > "$(REPORT_DIR)/compose.edge.yaml"

optional-smoke: compose-render-smoke compose-px4-smoke compose-dds-smoke compose-comms-smoke compose-media-smoke compose-diagnostics-smoke compose-edge-config

docker-metadata:
	mkdir -p "$(REPORT_DIR)"
	docker image inspect "$(IMAGE_TAG)" > "$(REPORT_DIR)/docker-image-inspect.json"

evidence-manifest: bootstrap prepare-run
	mkdir -p "$(REPORT_DIR)"
	if [[ ! -s "$(REPORT_DIR)/compose-smoke.txt" ]]; then echo "Missing $(REPORT_DIR)/compose-smoke.txt" >&2; exit 1; fi
	if [[ ! -s "$(REPORT_DIR)/compose-sensor-smoke.txt" ]]; then echo "Missing $(REPORT_DIR)/compose-sensor-smoke.txt" >&2; exit 1; fi
	if [[ ! -s "$(REPORT_DIR)/compose-artifact-tooling-smoke.txt" ]]; then echo "Missing $(REPORT_DIR)/compose-artifact-tooling-smoke.txt" >&2; exit 1; fi
	if [[ ! -s "$(REPORT_DIR)/integration-smoke.txt" ]]; then echo "Missing $(REPORT_DIR)/integration-smoke.txt" >&2; exit 1; fi
	if [[ ! -s "$(REPORT_DIR)/joint-motion-smoke.txt" ]]; then echo "Missing $(REPORT_DIR)/joint-motion-smoke.txt" >&2; exit 1; fi
	if [[ ! -s "$(REPORT_DIR)/compose-autopilot-smoke.txt" ]]; then echo "Missing $(REPORT_DIR)/compose-autopilot-smoke.txt" >&2; exit 1; fi
	if [[ ! -s "$(REPORT_DIR)/docker-image-inspect.json" ]]; then echo "Missing $(REPORT_DIR)/docker-image-inspect.json" >&2; exit 1; fi
	if [[ ! -s "$(SECURITY_DIR)/trivy-gate.txt" ]]; then echo "Missing $(SECURITY_DIR)/trivy-gate.txt" >&2; exit 1; fi
	image_digest="$$(jq -r '.[0].RepoDigests[0] // empty' "$(REPORT_DIR)/docker-image-inspect.json")"; \
	source_ref="$$(jq -r '.[0].Config.Labels["org.opencontainers.image.revision"] // empty' "$(REPORT_DIR)/docker-image-inspect.json")"; \
	sarif_result="$$(if [[ -s "$(SECURITY_DIR)/trivy-image.sarif" ]]; then echo pass; else echo not_run; fi)"; \
	jq -n \
		--arg created_at "$$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
		--arg run_id "$(RUN_ID)" \
		--argjson ros_domain_id "$$(cat $(RUNS_ROOT)/$(RUN_ID)/ros_domain_id.txt)" \
		--arg image "$(IMAGE_TAG)" \
		--arg image_digest "$${image_digest}" \
		--arg source_ref "$${source_ref}" \
		--arg sarif_result "$${sarif_result}" \
		-f "$(EVIDENCE_MANIFEST_FILTER)" > "$(EVIDENCE_MANIFEST)"
	"$(CHECK_JSONSCHEMA)" --schemafile "$(EVIDENCE_MANIFEST_SCHEMA)" "$(EVIDENCE_MANIFEST)"

docker-update-check: prepare-run
	mkdir -p "$(REPORT_DIR)"
	jq -r '.packages | to_entries[] | select((.value.package_manager // "apt") == "apt") | [.key, .value.package, .value.version] | @tsv' \
		"$(STACK_MANIFEST)" > "$(REPORT_DIR)/package-refs.tsv"
	docker run --rm \
		--network "$(DOCKER_RUN_NETWORK)" \
		-v "$(CURDIR)/$(REPORT_DIR)/package-refs.tsv:/tmp/package-refs.tsv:ro" \
		-v "$(CURDIR)/infra/scripts/check_apt_versions.py:/tmp/check_apt_versions.py:ro" \
		osrf/ros:jazzy-simulation \
		bash -lc 'set -euo pipefail; apt-get update >/dev/null; status=0; \
			while IFS=$$'\''\t'\'' read -r key package expected; do \
				apt-cache policy "$${package}" > /tmp/policy.txt; \
				candidate="$$(python3 /tmp/check_apt_versions.py --policy-file /tmp/policy.txt)" || candidate=""; \
				if [[ -z "$${candidate}" || "$${candidate}" == "(none)" ]]; then \
					echo "missing $${package}"; status=1; \
				elif [[ "$${candidate}" != "$${expected}" ]]; then \
					echo "changed $${key}: $${package} expected $${expected}, current $${candidate}"; status=1; \
				else \
					echo "$${key}: $${package} $${candidate}"; \
				fi; \
			done < /tmp/package-refs.tsv; \
			exit "$${status}"' \
		| tee "$(REPORT_DIR)/package-update-check.txt"

security-scan:
	mkdir -p "$(SECURITY_DIR)" "$(TRIVY_CACHE_DIR)"
	docker run --rm \
		--network "$(DOCKER_RUN_NETWORK)" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$(CURDIR)/$(SECURITY_DIR):/out" \
		-v "$(CURDIR)/$(TRIVY_CACHE_DIR):/root/.cache/trivy" \
		"$(TRIVY_IMAGE)" image \
		--db-repository "$(TRIVY_DB_REPOSITORY)" \
		--format sarif \
		--output /out/trivy-image.sarif \
		--exit-code 0 \
		"$(IMAGE_TAG)"

security-gate:
	mkdir -p "$(SECURITY_DIR)" "$(TRIVY_CACHE_DIR)"
	docker run --rm \
		--network "$(DOCKER_RUN_NETWORK)" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$(CURDIR)/$(SECURITY_DIR):/out" \
		-v "$(CURDIR)/$(TRIVY_IGNORE_FILE):/trivyignore:ro" \
		-v "$(CURDIR)/$(TRIVY_CACHE_DIR):/root/.cache/trivy" \
		"$(TRIVY_IMAGE)" image \
		--db-repository "$(TRIVY_DB_REPOSITORY)" \
		--scanners vuln \
		--ignorefile /trivyignore \
		--ignore-unfixed \
		--severity "$(TRIVY_GATE_SEVERITY)" \
		--exit-code 1 \
		"$(IMAGE_TAG)" \
		2>&1 | tee "$(SECURITY_DIR)/trivy-gate.txt"

sbom:
	mkdir -p "$(SECURITY_DIR)" "$(TRIVY_CACHE_DIR)"
	docker run --rm \
		--network "$(DOCKER_RUN_NETWORK)" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$(CURDIR)/$(SECURITY_DIR):/out" \
		-v "$(CURDIR)/$(TRIVY_CACHE_DIR):/root/.cache/trivy" \
		"$(TRIVY_IMAGE)" image \
		--format cyclonedx \
		--output /out/sbom.cdx.json \
		"$(IMAGE_TAG)"

parallel-isolation-smoke:
	@if [[ -z "$(RUN_ID)" ]]; then echo "RUN_ID is required" >&2; exit 2; fi
	mkdir -p "$(RUNS_ROOT)"
	rc_a=0; rc_b=0; \
	( $(MAKE) RUN_ID=$(RUN_ID)-a compose-smoke > "$(RUNS_ROOT)/$(RUN_ID)-a.parallel-smoke.log" 2>&1 ) & pid_a=$$!; \
	( $(MAKE) RUN_ID=$(RUN_ID)-b compose-smoke > "$(RUNS_ROOT)/$(RUN_ID)-b.parallel-smoke.log" 2>&1 ) & pid_b=$$!; \
	wait "$$pid_a" || rc_a=$$?; \
	wait "$$pid_b" || rc_b=$$?; \
	cat "$(RUNS_ROOT)/$(RUN_ID)-a.parallel-smoke.log"; \
	cat "$(RUNS_ROOT)/$(RUN_ID)-b.parallel-smoke.log"; \
	if [[ "$$rc_a" -ne 0 || "$$rc_b" -ne 0 ]]; then \
		echo "parallel-isolation-smoke failed: rc_a=$$rc_a rc_b=$$rc_b" >&2; \
		exit 1; \
	fi
	@test -d "$(RUNS_ROOT)/$(RUN_ID)-a/reports"
	@test -d "$(RUNS_ROOT)/$(RUN_ID)-b/reports"
	@test "$$(cat $(RUNS_ROOT)/$(RUN_ID)-a/ros_domain_id.txt)" != "$$(cat $(RUNS_ROOT)/$(RUN_ID)-b/ros_domain_id.txt)"

ci: validate lint docker-manifests compose-build compose-smoke compose-sensor-smoke compose-artifact-tooling-smoke compose-autopilot-smoke docker-metadata \
	integration-smoke joint-motion-smoke docker-update-check security-scan security-gate sbom evidence-manifest

pre-commit: bootstrap
	"$(PRE_COMMIT)" run --all-files

clean:
	rm -rf artifacts runs
