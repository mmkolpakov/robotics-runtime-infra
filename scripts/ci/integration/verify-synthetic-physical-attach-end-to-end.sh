#!/usr/bin/env bash
set -Eeuo pipefail

# shellcheck source=scripts/ci/lib.sh
source "$(dirname -- "${BASH_SOURCE[0]}")/../lib.sh"
ci_enter_repo

sudo apt-get update
sudo apt-get install -y --no-install-recommends \
  bats can-utils socat "linux-modules-extra-$(uname -r)"
ci_set_compose_fixture_env
ci_export_local_image_digest \
  ROBOTICS_COSIGN_IMAGE_DIGEST \
  "${PERMIT_PREFLIGHT_IMAGE}"

comparison_work="$(mktemp -d)"
cleanup_comparison_work() {
  rm -rf -- "${comparison_work}"
}
run_permit_json_comparison() {
  local right_document="$1"

  docker run --rm \
    --network none \
    --read-only \
    --cap-drop ALL \
    --security-opt no-new-privileges:true \
    --env LEFT_DOCUMENT=/fixtures/left.json \
    --env "RIGHT_DOCUMENT=/fixtures/${right_document}" \
    --mount "type=bind,source=${comparison_work},target=/fixtures,readonly" \
    --entrypoint yq \
    "${PERMIT_PREFLIGHT_IMAGE}" \
    --null-input \
    --exit-status \
    --from-file /usr/share/robotics-runtime/permit-preflight/json-equal.yq \
    >/dev/null
}
trap cleanup_comparison_work EXIT
cat >"${comparison_work}/left.json" <<'EOF'
{"schema_version":"fixture.v1","nested":{"alpha":1,"beta":2}}
EOF
cat >"${comparison_work}/equal.json" <<'EOF'
{"nested":{"beta":2,"alpha":1},"schema_version":"fixture.v1"}
EOF
cat >"${comparison_work}/changed.json" <<'EOF'
{"nested":{"beta":3,"alpha":1},"schema_version":"fixture.v1"}
EOF
chmod 0755 "${comparison_work}"
chmod 0444 "${comparison_work}"/*.json
run_permit_json_comparison equal.json
if run_permit_json_comparison changed.json 2>/dev/null; then
  printf 'permit comparison accepted a changed predicate\n' >&2
  exit 1
fi
cleanup_comparison_work
trap - EXIT

docker compose \
  -f compose.yaml \
  -f compose.edge-attach.yaml \
  -f compose.real-observation.yaml \
  -f compose.real-observation.test.yaml \
  --profile real-observation \
  --profile real-observation-test \
  --profile real-observation-test-negative \
  config --quiet
bats test/ci/physical-attach.bats
bash scripts/ci/physical-attach.sh
