#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
  WORKFLOW=.github/workflows/jetson-image.yml
}

@test "Jetson images build natively outside the pull request queue" {
  grep -Fx '    runs-on: ubuntu-24.04-arm' "${WORKFLOW}"
  grep -F 'test "$(uname -m)" = aarch64' "${WORKFLOW}"
  grep -Fx '  workflow_dispatch:' "${WORKFLOW}"
  grep -Fx '  schedule:' "${WORKFLOW}"
  triggers="$(sed -n '/^on:/,/^permissions:/p' "${WORKFLOW}")"
  grep -Fx '    paths:' <<<"${triggers}"
  grep -Fx '      - scripts/ci/nvidia-jetson-supply-chain/**' <<<"${triggers}"
  run grep -E '^      - (Dockerfile|docker-bake\.hcl)$' <<<"${triggers}"
  [ "${status}" -eq 1 ]
  run grep -F 'jetson-image' .github/workflows/ci.yml
  [ "${status}" -eq 1 ]
}

@test "Jetson provider check requires the source version and TensorRT" {
  fake_bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${fake_bin}"
  cat >"${fake_bin}/docker" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$@" >"${DOCKER_ARGS}"
EOF
  chmod +x "${fake_bin}/docker"

  run env PATH="${fake_bin}:${PATH}" DOCKER_ARGS="${BATS_TEST_TMPDIR}/args" \
    scripts/ci/nvidia-jetson-image/verify-onnxruntime-providers.sh local/jetson:test
  [ "${status}" -eq 0 ]
  grep -Fx 'local/jetson:test' "${BATS_TEST_TMPDIR}/args"
  grep -F 'TensorrtExecutionProvider' "${BATS_TEST_TMPDIR}/args"
  grep -F 'onnxruntime-source.txt' "${BATS_TEST_TMPDIR}/args"

  run scripts/ci/nvidia-jetson-image/verify-onnxruntime-providers.sh
  [ "${status}" -eq 64 ]
}
