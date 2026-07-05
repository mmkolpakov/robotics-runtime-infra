unexport BASH_ENV

SHELL := /bin/bash
.SHELLFLAGS := -euo pipefail -c

IMAGE_TAG ?= droning/ros-jazzy-mavros-gazebo:2026-07-05
IMAGE_SOURCE ?= local
IMAGE_VERSION ?= 2026-07-05
VCS_REF ?= local
IMAGE_CREATED ?= unknown
DOCKER_BUILD_NETWORK ?= host
DOCKER_RUN_NETWORK ?= host
REPORT_DIR ?= artifacts/reports
SECURITY_DIR ?= artifacts/security
TRIVY_IMAGE ?= aquasec/trivy:0.72.0
STACK_MANIFEST := infra/stack/simulation-stack.json
STACK_SCHEMA := contracts/infra/stack.schema.json
DOCKERFILE := infra/docker/ros-jazzy-mavros-gazebo.Dockerfile

.PHONY: validate validate-json validate-yaml docker-manifests docker-pull docker-build docker-smoke docker-metadata docker-update-check security-scan ci clean

validate: validate-json validate-yaml

validate-json:
	mkdir -p "$(REPORT_DIR)"
	check-jsonschema --schemafile "$(STACK_SCHEMA)" "$(STACK_MANIFEST)"
	python3 -m json.tool .devcontainer/devcontainer.json > "$(REPORT_DIR)/devcontainer.json"
	python3 -m json.tool "$(STACK_MANIFEST)" > "$(REPORT_DIR)/simulation-stack.json"
	python3 -m json.tool "$(STACK_SCHEMA)" > "$(REPORT_DIR)/stack.schema.json"

validate-yaml:
	yamllint .github .yamllint.yml

docker-manifests:
	mkdir -p "$(REPORT_DIR)"
	docker buildx imagetools inspect osrf/ros:jazzy-simulation > "$(REPORT_DIR)/ros-base-image.txt"
	docker buildx imagetools inspect ardupilot/ardupilot-dev-base:v0.2.0 > "$(REPORT_DIR)/ardupilot-base-image.txt"

docker-pull:
	docker pull osrf/ros:jazzy-simulation
	docker pull ardupilot/ardupilot-dev-base:v0.2.0

docker-build:
	mkdir -p "$(REPORT_DIR)"
	docker build \
		--network "$(DOCKER_BUILD_NETWORK)" \
		-f "$(DOCKERFILE)" \
		--build-arg IMAGE_CREATED="$(IMAGE_CREATED)" \
		--build-arg IMAGE_SOURCE="$(IMAGE_SOURCE)" \
		--build-arg IMAGE_VERSION="$(IMAGE_VERSION)" \
		--build-arg VCS_REF="$(VCS_REF)" \
		-t "$(IMAGE_TAG)" \
		.

docker-smoke:
	mkdir -p "$(REPORT_DIR)"
	docker run --rm "$(IMAGE_TAG)" | tee "$(REPORT_DIR)/docker-smoke.txt"
	docker run --rm ardupilot/ardupilot-dev-base:v0.2.0 \
		bash -lc 'python3 --version && git --version' | tee "$(REPORT_DIR)/ardupilot-smoke.txt"

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

ci: validate docker-manifests docker-build docker-smoke docker-metadata docker-update-check security-scan

clean:
	rm -rf artifacts
