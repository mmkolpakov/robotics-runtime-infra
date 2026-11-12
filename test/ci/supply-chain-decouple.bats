#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
}

@test "image-input manifest matches the bake-derived watch list" {
  run scripts/ci/supply-chain/image-inputs.sh check
  [ "${status}" -eq 0 ]
}

@test "watch list covers the fixed supply-chain inputs" {
  run scripts/ci/supply-chain/image-inputs.sh list
  [ "${status}" -eq 0 ]
  local pattern
  for pattern in .dockerignore .trivyignore Dockerfile docker-bake.hcl 'docker/*' \
    'security/*' trivy.yaml config/foundation-lock.json \
    config/ros-cohort-source.lock.json foundation.repos host/source-lock.json; do
    if ! grep -Fxq "${pattern}" <<<"${output}"; then
      printf 'missing fixed input: %s\n' "${pattern}"
    fi
    grep -Fxq "${pattern}" <<<"${output}"
  done
}

@test "watch list derives COPY sources and local bake contexts" {
  run scripts/ci/supply-chain/image-inputs.sh list
  [ "${status}" -eq 0 ]
  local pattern
  for pattern in config/time/chrony-fixture.conf policy/execution.rego \
    trust/qualification.trusted-root.json test/provider-conformance/test_provider.py \
    scripts/ci/foundation/build-workspace-wheels.py 'ros_ws/src/*' \
    'host/.tools/host-asset/*' probes/robotics_inference_conformance.py \
    'probes/sensor_inference/robotics_sensor_inference/*' \
    probes/rknn_simulator_conformance.py; do
    if ! grep -Fxq "${pattern}" <<<"${output}"; then
      printf 'missing derived input: %s\n' "${pattern}"
    fi
    grep -Fxq "${pattern}" <<<"${output}"
  done
}

@test "classify marks every image input affected" {
  local path
  while IFS= read -r path; do
    run scripts/ci/supply-chain/image-inputs.sh classify <<<"${path}"
    [ "${status}" -eq 0 ]
    if [ "${output}" != true ]; then
      printf 'unexpected classification for %s: %s\n' "${path}" "${output}"
    fi
    [ "${output}" = true ]
  done <<'PATHS'
Dockerfile
docker/apt/use-package-snapshots
docker-bake.hcl
.trivyignore
trivy.yaml
security/vex/linux-libc-dev.openvex.json
config/foundation-lock.json
config/ros-cohort-source.lock.json
foundation.repos
host/source-lock.json
ros_ws/src/robotics_observability_msgs/msg/X.msg
probes/robotics_inference_conformance.py
policy/execution.rego
host/.tools/host-asset/core.tgz
.dockerignore
scripts/ci/foundation/build-workspace-wheels.py
test/provider-conformance/test_provider.py
PATHS
}

@test "classify leaves domain-only changes not affected" {
  local path
  while IFS= read -r path; do
    run scripts/ci/supply-chain/image-inputs.sh classify <<<"${path}"
    [ "${status}" -eq 0 ]
    if [ "${output}" != false ]; then
      printf 'unexpected classification for %s: %s\n' "${path}" "${output}"
    fi
    [ "${output}" = false ]
  done <<'PATHS'
README.md
docs/ci-decouple.md
.github/workflows/ci-domain.yml
compose.yaml
ansible/roles/chrony/tasks/main.yml
terraform/foundation/main.tf
helm/robotics-run/Chart.yaml
examples/nav2-turtlebot3/test_evaluator.py
test/ci/supply-chain-decouple.bats
scripts/ci/check-product-helm.sh
renovate.json
SECURITY.md
PATHS
}

@test "classify is deterministic and an empty diff is not affected" {
  run scripts/ci/supply-chain/image-inputs.sh classify <<<""
  [ "${status}" -eq 0 ]
  [ "${output}" = false ]

  local input first
  input=$'README.md\nDockerfile\ndocs/x.md\n'
  run scripts/ci/supply-chain/image-inputs.sh classify <<<"${input}"
  [ "${status}" -eq 0 ]
  first="${output}"
  run scripts/ci/supply-chain/image-inputs.sh classify <<<"${input}"
  [ "${status}" -eq 0 ]
  [ "${output}" = "${first}" ]
  [ "${first}" = true ]
}

@test "classify writes the GitHub output flag" {
  local output_file="${BATS_TEST_TMPDIR}/github-output"
  : >"${output_file}"
  run env GITHUB_OUTPUT="${output_file}" \
    scripts/ci/supply-chain/image-inputs.sh classify --github-output <<<"Dockerfile"
  [ "${status}" -eq 0 ]
  grep -Fx 'affected=true' "${output_file}"
}

@test "guarded run classifies snapshot mirror 5xx as EX_TEMPFAIL" {
  local fake="${BATS_TEST_TMPDIR}/fake-build"
  cat >"${fake}" <<'EOF'
#!/usr/bin/env bash
printf 'Err:1 https://snapshot.ubuntu.com/ubuntu/20260930T000000Z noble InRelease\n'
printf '  503  Service Unavailable [IP: 185.125.189.20 443]\n'
printf 'E: Failed to fetch https://snapshot.ubuntu.com/ubuntu/20260930T000000Z/dists/noble/InRelease\n'
exit 1
EOF
  chmod +x "${fake}"
  run scripts/ci/supply-chain/run-guarded.sh "${fake}"
  [ "${status}" -eq 75 ]
  [[ "${output}" == *"upstream unavailable"* ]]

  cat >"${fake}" <<'EOF'
#!/usr/bin/env bash
printf 'E: Failed to fetch https://snapshot.ubuntu.com/ubuntu/20260930T000000Z/dists/noble/InRelease  503  Service Unavailable\n'
exit 1
EOF
  chmod +x "${fake}"
  run scripts/ci/supply-chain/run-guarded.sh "${fake}"
  [ "${status}" -eq 75 ]
}

@test "guarded run never succeeds on failure and keeps other exit codes" {
  local fake="${BATS_TEST_TMPDIR}/fake-build"
  cat >"${fake}" <<'EOF'
#!/usr/bin/env bash
printf 'ERROR: failed to pull the vulnerability database: 503 Service Unavailable\n'
exit 1
EOF
  chmod +x "${fake}"
  run scripts/ci/supply-chain/run-guarded.sh "${fake}"
  [ "${status}" -eq 1 ]

  cat >"${fake}" <<'EOF'
#!/usr/bin/env bash
printf 'Get:1 https://snapshot.ubuntu.com/ubuntu/20260930T000000Z noble InRelease [123 kB]\n'
printf 'unrelated line one\n'
printf 'unrelated line two\n'
printf 'unrelated line three\n'
printf 'ERROR: registry returned 503 Service Unavailable\n'
exit 1
EOF
  chmod +x "${fake}"
  run scripts/ci/supply-chain/run-guarded.sh "${fake}"
  [ "${status}" -eq 1 ]

  cat >"${fake}" <<'EOF'
#!/usr/bin/env bash
printf 'policy violation\n'
exit 3
EOF
  chmod +x "${fake}"
  run scripts/ci/supply-chain/run-guarded.sh "${fake}"
  [ "${status}" -eq 3 ]

  cat >"${fake}" <<'EOF'
#!/usr/bin/env bash
printf 'build complete\n'
exit 0
EOF
  chmod +x "${fake}"
  run scripts/ci/supply-chain/run-guarded.sh "${fake}"
  [ "${status}" -eq 0 ]
}

@test "guarded run records the upstream classification in the step summary" {
  local fake="${BATS_TEST_TMPDIR}/fake-build" summary="${BATS_TEST_TMPDIR}/summary"
  cat >"${fake}" <<'EOF'
#!/usr/bin/env bash
printf 'Err:1 https://snapshots.ros.org/jazzy/2026-09-11/ubuntu noble InRelease\n'
printf '  502  Bad Gateway\n'
exit 1
EOF
  chmod +x "${fake}"
  run env GITHUB_STEP_SUMMARY="${summary}" scripts/ci/supply-chain/run-guarded.sh "${fake}"
  [ "${status}" -eq 75 ]
  grep -F 'upstream unavailable' "${summary}"
}

@test "domain workflow and product tooling images never run apt" {
  run grep -En 'apt-get|apt ' .github/workflows/ci-domain.yml
  [ "${status}" -eq 1 ]
  run grep -n 'apt-get' docker/product-ansible.Dockerfile docker/product-kubernetes-tools.Dockerfile
  [ "${status}" -eq 1 ]
  run grep -F 'ros:jazzy-ros-base@sha256:' docker/product-ansible.Dockerfile
  [ "${status}" -eq 0 ]
  run grep -F 'ros:jazzy-ros-base@sha256:' docker/product-kubernetes-tools.Dockerfile
  [ "${status}" -eq 0 ]
}

@test "supply-chain aggregate only accepts skips when not affected" {
  run grep -F '.changes.result == "success"' .github/workflows/ci-supply-chain.yml
  [ "${status}" -eq 0 ]
  run grep -F '(.result == "skipped" and $affected == "false")' .github/workflows/ci-supply-chain.yml
  [ "${status}" -eq 0 ]
  run grep -F 'affected: ${{ steps.classify.outputs.affected }}' .github/workflows/ci-supply-chain.yml
  [ "${status}" -eq 0 ]
}

@test "every image job runs only when image inputs are affected" {
  run grep -c "if: needs.changes.outputs.affected == 'true'" .github/workflows/ci-supply-chain.yml
  [ "${status}" -eq 0 ]
  [ "${output}" -eq 9 ]
}

@test "release requires a forced fresh supply-chain gate" {
  run grep -F 'uses: ./.github/workflows/ci-domain.yml' .github/workflows/release-image.yml
  [ "${status}" -eq 0 ]
  run grep -F 'uses: ./.github/workflows/ci-supply-chain.yml' .github/workflows/release-image.yml
  [ "${status}" -eq 0 ]
  run grep -F 'force: true' .github/workflows/release-image.yml
  [ "${status}" -eq 0 ]
}

@test "security gate scans published digests outside pull requests" {
  run grep -F 'cron:' .github/workflows/security-gate.yml
  [ "${status}" -eq 0 ]
  run grep -F 'branches: [main]' .github/workflows/security-gate.yml
  [ "${status}" -eq 0 ]
  run grep -F 'scan-published-release.sh' .github/workflows/security-gate.yml
  [ "${status}" -eq 0 ]
  run grep -F 'gh issue create' .github/workflows/security-gate.yml
  [ "${status}" -eq 0 ]
  run grep -F "if: always() && needs.scan.result == 'failure'" .github/workflows/security-gate.yml
  [ "${status}" -eq 0 ]
  run grep -F 'pull_request:' .github/workflows/security-gate.yml
  [ "${status}" -eq 1 ]
}

@test "merge queue entries produce both required gates" {
  run grep -F 'merge_group:' .github/workflows/ci-domain.yml
  [ "${status}" -eq 0 ]
  run grep -F 'merge_group:' .github/workflows/ci-supply-chain.yml
  [ "${status}" -eq 0 ]
}
