unexport BASH_ENV

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

IMAGE_TAG ?= robotics/ros-jazzy-simulation:2026-07-05
DDS_AGENT_IMAGE_TAG ?= robotics/dds-agent:2026-07-05
MEDIA_IMAGE_TAG ?= robotics/media-runtime:2026-07-05
DIAGNOSTICS_IMAGE_TAG ?= robotics/diagnostics-runtime:2026-07-05
IMAGE_SOURCE ?= local
IMAGE_VERSION ?= 2026-07-05
VCS_REF ?= local
IMAGE_CREATED ?= unknown
DOCKER_BUILD_NETWORK ?= host
DOCKER_RUN_NETWORK ?= host
COMPOSE ?= docker compose
COMPOSE_FILE := compose.yaml
REPORT_DIR ?= artifacts/reports
SECURITY_DIR ?= artifacts/security
TRIVY_IMAGE ?= aquasec/trivy:0.72.0
HADOLINT_IMAGE ?= hadolint/hadolint:v2.14.0
ACTIONLINT_IMAGE ?= rhysd/actionlint:1.7.12
STACK_MANIFEST := infra/stack/simulation-stack.json
STACK_SCHEMA := contracts/infra/stack.schema.json
RUNTIME_PROFILES := infra/stack/runtime-profiles.json
RUNTIME_PROFILES_SCHEMA := contracts/infra/runtime-profiles.schema.json
EVIDENCE_MANIFEST_EXAMPLE := infra/stack/evidence-manifest.example.json
EVIDENCE_MANIFEST_SCHEMA := contracts/infra/evidence-manifest.schema.json
DOCKERFILE := infra/docker/ros-jazzy-mavros-gazebo.Dockerfile
DOCKERFILES := $(DOCKERFILE) infra/docker/dds-agent.Dockerfile infra/docker/media-runtime.Dockerfile infra/docker/diagnostics-runtime.Dockerfile

.PHONY: validate validate-json validate-yaml compose-config lint lint-dockerfile lint-actions profiles review \
	docker-manifests docker-pull compose-build compose-smoke compose-autopilot-smoke compose-ardupilot-smoke \
	compose-px4-smoke compose-dds-smoke compose-comms-smoke compose-media-smoke compose-diagnostics-smoke \
	compose-sensor-smoke compose-gpu-smoke compose-render-smoke compose-edge-config optional-smoke \
	docker-metadata docker-update-check sbom security-scan ci clean

validate: validate-json validate-yaml compose-config

validate-json:
	mkdir -p "$(REPORT_DIR)"
	check-jsonschema --schemafile "$(STACK_SCHEMA)" "$(STACK_MANIFEST)"
	check-jsonschema --schemafile "$(RUNTIME_PROFILES_SCHEMA)" "$(RUNTIME_PROFILES)"
	check-jsonschema --schemafile "$(EVIDENCE_MANIFEST_SCHEMA)" "$(EVIDENCE_MANIFEST_EXAMPLE)"
	python3 -m json.tool .devcontainer/devcontainer.json > "$(REPORT_DIR)/devcontainer.json"
	python3 -m json.tool "$(STACK_MANIFEST)" > "$(REPORT_DIR)/simulation-stack.json"
	python3 -m json.tool "$(STACK_SCHEMA)" > "$(REPORT_DIR)/stack.schema.json"
	python3 -m json.tool "$(RUNTIME_PROFILES)" > "$(REPORT_DIR)/runtime-profiles.json"
	python3 -m json.tool "$(RUNTIME_PROFILES_SCHEMA)" > "$(REPORT_DIR)/runtime-profiles.schema.json"
	python3 -m json.tool "$(EVIDENCE_MANIFEST_EXAMPLE)" > "$(REPORT_DIR)/evidence-manifest.example.json"
	python3 -m json.tool "$(EVIDENCE_MANIFEST_SCHEMA)" > "$(REPORT_DIR)/evidence-manifest.schema.json"

validate-yaml:
	yamllint .github .yamllint.yml "$(COMPOSE_FILE)"

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
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile render config > "$(REPORT_DIR)/compose.render.yaml"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile nvidia config > "$(REPORT_DIR)/compose.nvidia.yaml"
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

review: validate lint profiles compose-build compose-smoke compose-sensor-smoke compose-autopilot-smoke docker-metadata sbom

docker-manifests:
	mkdir -p "$(REPORT_DIR)"
	docker buildx imagetools inspect osrf/ros:jazzy-simulation > "$(REPORT_DIR)/ros-base-image.txt"
	docker buildx imagetools inspect ardupilot/ardupilot-dev-base:v0.2.0 > "$(REPORT_DIR)/ardupilot-base-image.txt"

docker-pull:
	docker pull osrf/ros:jazzy-simulation
	docker pull ardupilot/ardupilot-dev-base:v0.2.0

compose-build:
	mkdir -p "$(REPORT_DIR)"
	IMAGE_TAG="$(IMAGE_TAG)" \
	IMAGE_CREATED="$(IMAGE_CREATED)" \
	IMAGE_SOURCE="$(IMAGE_SOURCE)" \
	IMAGE_VERSION="$(IMAGE_VERSION)" \
	VCS_REF="$(VCS_REF)" \
	DOCKER_BUILD_NETWORK="$(DOCKER_BUILD_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" build simulation

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
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile dds build dds-agent
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
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile media build media-runtime
	rc=0; \
	IMAGE_TAG="$(IMAGE_TAG)" COMPOSE_NETWORK_MODE="$(DOCKER_RUN_NETWORK)" \
		$(COMPOSE) -f "$(COMPOSE_FILE)" --profile media run --rm --no-deps media-runtime \
		2>&1 | tee "$(REPORT_DIR)/compose-media-smoke.txt" || rc=$$?; \
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile media down --remove-orphans || true; \
	exit $$rc

compose-diagnostics-smoke:
	mkdir -p "$(REPORT_DIR)"
	$(COMPOSE) -f "$(COMPOSE_FILE)" --profile diagnostics build diagnostics-runtime
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
			&& ros2 interface show sensor_msgs/msg/Image >/tmp/sensor-image.txt \
			&& ros2 interface show sensor_msgs/msg/CameraInfo >/tmp/sensor-camera-info.txt \
			&& ros2 interface show sensor_msgs/msg/PointCloud2 >/tmp/sensor-pointcloud2.txt \
			&& ros2 interface show tf2_msgs/msg/TFMessage >/tmp/tf-message.txt \
			&& ros2 pkg prefix image_transport >/tmp/image-transport-prefix.txt \
			&& test -s /tmp/sensor-image.txt \
			&& test -s /tmp/sensor-camera-info.txt \
			&& test -s /tmp/sensor-pointcloud2.txt \
			&& test -s /tmp/tf-message.txt \
			&& test -s /tmp/image-transport-prefix.txt' \
		2>&1 | tee "$(REPORT_DIR)/compose-sensor-smoke.txt" || rc=$$?; \
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

docker-update-check:
	mkdir -p "$(REPORT_DIR)"
	jq -r '.packages | to_entries[] | [.key, .value.package, .value.version] | @tsv' \
		"$(STACK_MANIFEST)" > "$(REPORT_DIR)/package-refs.tsv"
	docker run --rm \
		--network "$(DOCKER_RUN_NETWORK)" \
		-v "$(CURDIR)/$(REPORT_DIR)/package-refs.tsv:/tmp/package-refs.tsv:ro" \
		osrf/ros:jazzy-simulation \
		bash -lc 'set -euo pipefail; apt-get update >/dev/null; status=0; while IFS=$$'\''\t'\'' read -r key package expected; do candidate="$$(apt-cache policy "$${package}" | awk "/Candidate:/ {print \$$2}")"; if [[ -z "$${candidate}" || "$${candidate}" == "(none)" ]]; then echo "missing $${package}"; status=1; elif [[ "$${candidate}" != "$${expected}" ]]; then echo "changed $${key}: $${package} expected $${expected}, current $${candidate}"; status=1; else echo "$${key}: $${package} $${candidate}"; fi; done < /tmp/package-refs.tsv; exit "$${status}"' \
		| tee "$(REPORT_DIR)/package-update-check.txt"

security-scan:
	mkdir -p "$(SECURITY_DIR)"
	docker run --rm \
		--network "$(DOCKER_RUN_NETWORK)" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$(CURDIR)/$(SECURITY_DIR):/out" \
		"$(TRIVY_IMAGE)" image \
		--format sarif \
		--output /out/trivy-image.sarif \
		--exit-code 0 \
		"$(IMAGE_TAG)"

sbom:
	mkdir -p "$(SECURITY_DIR)"
	docker run --rm \
		--network "$(DOCKER_RUN_NETWORK)" \
		-v /var/run/docker.sock:/var/run/docker.sock \
		-v "$(CURDIR)/$(SECURITY_DIR):/out" \
		"$(TRIVY_IMAGE)" image \
		--format cyclonedx \
		--output /out/sbom.cdx.json \
		"$(IMAGE_TAG)"

ci: validate lint docker-manifests compose-build compose-smoke compose-sensor-smoke compose-autopilot-smoke docker-metadata \
	docker-update-check security-scan sbom

clean:
	rm -rf artifacts
