unexport BASH_ENV

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

ifneq (,$(wildcard .env))
include .env
export
endif

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
DOCKER_RUN_NETWORK ?= host
DOCKER_BUILD_RETRIES ?= 3
DOCKER_INSPECT_RETRIES ?= 6
COMPOSE ?= docker compose
COMPOSE_FILE := compose.yaml
DEV_SERVICE ?= simulation-dev
REPORT_DIR ?= artifacts/reports
SECURITY_DIR ?= artifacts/security
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

.PHONY: validate validate-json validate-yaml compose-config lint lint-dockerfile lint-actions profiles review \
	dev-up dev-shell dev-logs dev-ps dev-down \
	docker-manifests docker-pull compose-build compose-smoke compose-autopilot-smoke compose-ardupilot-smoke \
	compose-px4-smoke compose-dds-smoke compose-comms-smoke compose-media-smoke compose-diagnostics-smoke \
	compose-sensor-smoke compose-artifact-tooling-smoke integration-smoke joint-motion-smoke \
	compose-gpu-smoke compose-accelerated-inference-smoke \
	compose-render-smoke compose-edge-config optional-smoke docker-metadata docker-update-check \
	evidence-manifest sbom security-scan security-gate pre-commit ci clean

validate: validate-json validate-yaml compose-config

validate-json:
	mkdir -p "$(REPORT_DIR)"
	check-jsonschema --schemafile "$(STACK_SCHEMA)" "$(STACK_MANIFEST)"
	check-jsonschema --schemafile "$(INFRA_RELEASE_SCHEMA)" "$(INFRA_RELEASE)"
	check-jsonschema --schemafile "$(RUNTIME_PROFILES_SCHEMA)" "$(RUNTIME_PROFILES)"
	check-jsonschema --schemafile "$(EVIDENCE_MANIFEST_SCHEMA)" "$(EVIDENCE_MANIFEST_EXAMPLE)"
	python3 -m json.tool .devcontainer/devcontainer.json > "$(REPORT_DIR)/devcontainer.json"
	python3 -m json.tool "$(STACK_MANIFEST)" > "$(REPORT_DIR)/simulation-stack.json"
	python3 -m json.tool "$(STACK_SCHEMA)" > "$(REPORT_DIR)/stack.v1.schema.json"
	python3 -m json.tool "$(INFRA_RELEASE)" > "$(REPORT_DIR)/infra-release.json"
	python3 -m json.tool "$(INFRA_RELEASE_SCHEMA)" > "$(REPORT_DIR)/infra-release.v1.schema.json"
	python3 -m json.tool "$(RUNTIME_PROFILES)" > "$(REPORT_DIR)/runtime-profiles.json"
	python3 -m json.tool "$(RUNTIME_PROFILES_SCHEMA)" > "$(REPORT_DIR)/runtime-profiles.v1.schema.json"
	python3 -m json.tool "$(EVIDENCE_MANIFEST_EXAMPLE)" > "$(REPORT_DIR)/evidence-manifest.example.json"
	python3 -m json.tool "$(EVIDENCE_MANIFEST_SCHEMA)" > "$(REPORT_DIR)/evidence-manifest.v1.schema.json"

validate-yaml:
	yamllint .github .yamllint.yml "$(COMPOSE_FILE)" compose.override.yaml.example config

compose-config:
	mkdir -p "$(REPORT_DIR)"
	$(COMPOSE) -f "$(COMPOSE_FILE)" config > "$(REPORT_DIR)/compose.default.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile autopilot config > "$(REPORT_DIR)/compose.autopilot.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile ardupilot config > "$(REPORT_DIR)/compose.ardupilot.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile px4 config > "$(REPORT_DIR)/compose.px4.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dds config > "$(REPORT_DIR)/compose.dds.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile comms config > "$(REPORT_DIR)/compose.comms.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile media config > "$(REPORT_DIR)/compose.media.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile diagnostics config > "$(REPORT_DIR)/compose.diagnostics.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev config > "$(REPORT_DIR)/compose.dev.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile render config > "$(REPORT_DIR)/compose.render.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile nvidia config > "$(REPORT_DIR)/compose.nvidia.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile inference config > "$(REPORT_DIR)/compose.inference.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile edge config > "$(REPORT_DIR)/compose.edge.yaml"

lint: lint-dockerfile lint-actions

lint-dockerfile:
	mkdir -p "$(REPORT_DIR)"
	docker run --rm \
		-v "$(CURDIR):/repo:ro" \
		-w /repo \
		"$(HADOLINT_IMAGE)" \
		hadolint $(DOCKERFILES) 2>&1 | tee "$(REPORT_DIR)/hadolint.txt"

lint-actions:
	mkdir -p "$(REPORT_DIR)"
	docker run --rm \
		-v "$(CURDIR):/repo:ro" \
		-w /repo \
		"$(ACTIONLINT_IMAGE)" \
		-color=false .github/workflows/*.yml 2>&1 | tee "$(REPORT_DIR)/actionlint.txt"

profiles:
	mkdir -p "$(REPORT_DIR)"
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

compose-build:
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until IMAGE_TAG="$(IMAGE_TAG)" \
		IMAGE_CREATED="$(IMAGE_CREATED)" \
		IMAGE_SOURCE="$(IMAGE_SOURCE)" \
		IMAGE_VERSION="$(IMAGE_VERSION)" \
		VCS_REF="$(VCS_REF)" \
		DOCKER_BUILD_NETWORK="$(DOCKER_BUILD_NETWORK)" \
			$(COMPOSE) -f "$(COMPOSE_FILE)" build simulation; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_BUILD_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done

dev-up: compose-build
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev up --detach --wait --no-build "$(DEV_SERVICE)"

dev-shell:
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev exec "$(DEV_SERVICE)" \
		bash -lc 'source /etc/profile.d/robotics_ros_setup.sh && exec bash -i'

dev-logs:
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev logs --follow "$(DEV_SERVICE)"

dev-ps:
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev ps "$(DEV_SERVICE)"

dev-down:
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev stop "$(DEV_SERVICE)" || true
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dev rm --force "$(DEV_SERVICE)" || true

compose-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" run --rm --no-deps simulation \
		2>&1 | tee "$(REPORT_DIR)/compose-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" down --remove-orphans || true; \
	exit $$rc

compose-autopilot-smoke:
	$(MAKE) compose-ardupilot-smoke

compose-ardupilot-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile ardupilot run --rm --no-deps autopilot-base \
		2>&1 | tee "$(REPORT_DIR)/compose-autopilot-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile ardupilot down --remove-orphans || true; \
	exit $$rc

compose-px4-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile px4 run --rm --no-deps px4-sitl \
		2>&1 | tee "$(REPORT_DIR)/compose-px4-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile px4 down --remove-orphans || true; \
	exit $$rc

compose-dds-smoke:
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until $(COMPOSE) -f "$(COMPOSE_FILE)" --profile dds build dds-agent; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_BUILD_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done
	rc=0; \
	COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dds run --rm --no-deps dds-agent \
		2>&1 | tee "$(REPORT_DIR)/compose-dds-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dds down --remove-orphans || true; \
	exit $$rc

compose-comms-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile comms run --rm --no-deps comms-bridge \
		2>&1 | tee "$(REPORT_DIR)/compose-comms-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile comms down --remove-orphans || true; \
	exit $$rc

compose-media-smoke:
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until $(COMPOSE) -f "$(COMPOSE_FILE)" --profile media build media-runtime; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_BUILD_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile media run --rm --no-deps media-runtime \
		2>&1 | tee "$(REPORT_DIR)/compose-media-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile media down --remove-orphans || true; \
	exit $$rc

compose-diagnostics-smoke:
	mkdir -p "$(REPORT_DIR)"
	n=0; \
	until $(COMPOSE) -f "$(COMPOSE_FILE)" --profile diagnostics build diagnostics-runtime; do \
		n=$$((n + 1)); \
		if [[ "$$n" -ge "$(DOCKER_BUILD_RETRIES)" ]]; then exit 1; fi; \
		sleep $$((5 * n)); \
	done
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile diagnostics run --rm --no-deps diagnostics-runtime \
		2>&1 | tee "$(REPORT_DIR)/compose-diagnostics-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile diagnostics down --remove-orphans || true; \
	exit $$rc

compose-sensor-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
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
	$(COMPOSE) -f "$(COMPOSE_FILE)" down --remove-orphans || true; \
	exit $$rc

compose-artifact-tooling-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" run --rm --no-deps simulation \
		bash -lc 'aws --version | grep -E "^aws-cli/2\.35\.17 " && source /etc/profile.d/robotics_ros_setup.sh && ros2 pkg prefix ros_gz_sim >/dev/null' \
		2>&1 | tee "$(REPORT_DIR)/compose-artifact-tooling-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" down --remove-orphans || true; \
	exit $$rc

integration-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" run --rm --no-deps simulation \
		bash /workspace/infra/smoke/simulation_integration_smoke.sh \
		2>&1 | tee "$(REPORT_DIR)/integration-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" down --remove-orphans || true; \
	exit $$rc

joint-motion-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" run --rm --no-deps simulation \
		bash /workspace/infra/smoke/joint_motion_smoke.sh \
		2>&1 | tee "$(REPORT_DIR)/joint-motion-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" down --remove-orphans || true; \
	exit $$rc

compose-gpu-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile nvidia run --rm --no-deps nvidia-gpu \
		2>&1 | tee "$(REPORT_DIR)/compose-gpu-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile nvidia down --remove-orphans || true; \
	exit $$rc

compose-accelerated-inference-smoke:
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
	INFERENCE_IMAGE_TAG="$(INFERENCE_IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile inference run --rm --no-deps accelerated-inference \
		2>&1 | tee "$(REPORT_DIR)/compose-accelerated-inference-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile inference down --remove-orphans || true; \
	exit $$rc

compose-render-smoke:
	mkdir -p "$(REPORT_DIR)"
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile render run --rm --no-deps local-render \
		2>&1 | tee "$(REPORT_DIR)/compose-render-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile render down --remove-orphans || true; \
	exit $$rc

compose-edge-config:
	mkdir -p "$(REPORT_DIR)"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile edge config > "$(REPORT_DIR)/compose.edge.yaml"

optional-smoke: compose-render-smoke compose-px4-smoke compose-dds-smoke compose-comms-smoke compose-media-smoke compose-diagnostics-smoke compose-edge-config

docker-metadata:
	mkdir -p "$(REPORT_DIR)"
	docker image inspect "$(IMAGE_TAG)" > "$(REPORT_DIR)/docker-image-inspect.json"

evidence-manifest:
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
		--arg run_id "$${RUN_ID:-local-review}" \
		--arg image "$(IMAGE_TAG)" \
		--arg image_digest "$${image_digest}" \
		--arg source_ref "$${source_ref}" \
		--arg sarif_result "$${sarif_result}" \
		-f "$(EVIDENCE_MANIFEST_FILTER)" > "$(EVIDENCE_MANIFEST)"
	check-jsonschema --schemafile "$(EVIDENCE_MANIFEST_SCHEMA)" "$(EVIDENCE_MANIFEST)"

docker-update-check:
	mkdir -p "$(REPORT_DIR)"
	jq -r '.packages | to_entries[] | select((.value.package_manager // "apt") == "apt") | [.key, .value.package, .value.version] | @tsv' \
		"$(STACK_MANIFEST)" > "$(REPORT_DIR)/package-refs.tsv"
	docker run --rm \
		--network "$(DOCKER_RUN_NETWORK)" \
		-v "$(CURDIR)/$(REPORT_DIR)/package-refs.tsv:/tmp/package-refs.tsv:ro" \
		osrf/ros:jazzy-simulation \
		bash -lc 'set -euo pipefail; apt-get update >/dev/null; status=0; while IFS=$$'\''\t'\'' read -r key package expected; do candidate="$$(apt-cache policy "$${package}" | awk "/Candidate:/ {print \$$2}")"; if [[ -z "$${candidate}" || "$${candidate}" == "(none)" ]]; then echo "missing $${package}"; status=1; elif [[ "$${candidate}" != "$${expected}" ]]; then echo "changed $${key}: $${package} expected $${expected}, current $${candidate}"; status=1; else echo "$${key}: $${package} $${candidate}"; fi; done < /tmp/package-refs.tsv; exit "$${status}"' \
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

ci: validate lint docker-manifests compose-build compose-smoke compose-sensor-smoke compose-artifact-tooling-smoke compose-autopilot-smoke docker-metadata \
	integration-smoke joint-motion-smoke docker-update-check security-scan security-gate sbom evidence-manifest

pre-commit:
	pre-commit run --all-files

clean:
	rm -rf artifacts
