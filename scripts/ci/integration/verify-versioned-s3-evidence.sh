#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "$root"
: "${OBSERVER_IMAGE:?OBSERVER_IMAGE is required for the installed harness check}"
evidence_dir="${PWD}/artifacts/evidence-s3"
project="evidence-s3-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -p "${evidence_dir}"
printf 'opaque controller evidence\n' >"${evidence_dir}/controller.log"
export EVIDENCE_ARTIFACT_MEDIA_TYPES='application/json,application/x-ndjson,application/junit+xml,text/plain,application/vnd.in-toto+json,application/vnd.example.controller-log'
export ROBOTICS_BAG_DIR="${PWD}/test/fixtures/playback/golden"
export ROBOTICS_EVIDENCE_DIR="${evidence_dir}"
export ROBOTICS_RUN_ID=run-00000000-0000-4000-8000-000000000001
compose=(
  docker compose -p "${project}"
  -f compose.yaml
  -f compose.evidence.yaml
  -f compose.evidence.test.yaml
)
cleanup() {
  local status=$?
  "${compose[@]}" --profile test --profile evidence \
    down --volumes --remove-orphans || true
  # CI retains private-mode state files too. Restore ownership only after the
  # containers stop, so the runner can archive both successful and failed runs.
  if ! sudo chown -R "$(id -u):$(id -g)" "${evidence_dir}"; then
    if ((status == 0)); then
      status=1
    fi
  fi
  return "${status}"
}
trap cleanup EXIT
sudo chown -R 10001:10001 "${evidence_dir}"
"${compose[@]}" --profile test --profile evidence \
  run --rm evidence-finalize artifact \
  /evidence/controller.log application/vnd.example.controller-log 900001
"${compose[@]}" --profile test --profile evidence \
  run --rm -T --entrypoint /bin/bash evidence-finalize -s <<'SHELL'
set -Eeuo pipefail

source=/evidence/recordings/golden_0.mcap
evidence-sink segment "$source"
digest="$(sha256sum "$source" | cut -d' ' -f1)"
registration="/evidence/state/registrations/0-${digest}.json"
work="$(mktemp -d)"
# Fixture private keys exist only in this container's tmpfs. Public verification
# evidence is retained; no private key enters the mounted artifact directory.
trap 'rm -f -- "$work"/*; rmdir -- "$work"' EXIT
export COSIGN_PASSWORD=retention-fixture-only
cosign generate-key-pair --output-key-prefix "$work/signer"
cosign generate-key-pair --output-key-prefix "$work/foreign"
cosign signing-config create --out "$work/signing.json"
cosign trusted-root create --out "$work/root.json"
retained-artifact predicate --registration "$registration" --source "$source" \
  >"$work/predicate.json"
cosign attest-blob --yes --key "$work/signer.key" \
  --signing-config "$work/signing.json" --trusted-root "$work/root.json" \
  --predicate "$work/predicate.json" \
  --type https://robotics-runtime.dev/attestations/artifact-retention/v1 \
  --bundle "$work/retention.sigstore.json" "$source"

if retained-artifact verify --registration "$registration" \
  --bundle "$work/retention.sigstore.json" --key "$work/foreign.pub" \
  --output /evidence/provenance/rejected-key >"$work/rejection.log" 2>&1; then
  printf 'retention verifier accepted a foreign public key\n' >&2
  exit 1
fi
grep -F 'cosign failed (' "$work/rejection.log"
test ! -e /evidence/provenance/rejected-key

# Publish different bytes at the same object key, preserving their size. The
# original signed version must stay readable even though it is no longer latest.
python3 - "$source" "$work/changed.mcap" <<'PY'
import sys
from pathlib import Path

data = bytearray(Path(sys.argv[1]).read_bytes())
data[-1] ^= 1
Path(sys.argv[2]).write_bytes(data)
PY
key="$(python3 - "$registration" <<'PY'
import json
import sys
from pathlib import Path
from urllib.parse import unquote, urlsplit

uri = json.loads(Path(sys.argv[1]).read_bytes())["uri"]
print(unquote(urlsplit(uri).path.removeprefix("/")))
PY
)"
aws s3api put-object --bucket "$EVIDENCE_BUCKET" --key "$key" \
  --body "$work/changed.mcap" --content-type application/mcap \
  --output json --no-cli-pager >"$work/changed-object.json"
changed_version="$(jq -er '.VersionId | select(type == "string" and length > 0 and . != "null")' \
  "$work/changed-object.json")"
test "$changed_version" != "$(jq -er '.version_id' "$registration")"
jq --arg revision "$changed_version" '.version_id = $revision' \
  "$registration" >"$work/changed-registration.json"
if retained-artifact verify --registration "$work/changed-registration.json" \
  --bundle "$work/retention.sigstore.json" --key "$work/signer.pub" \
  --output /evidence/provenance/rejected-bytes >"$work/rejection.log" 2>&1; then
  printf 'retention verifier accepted changed remote bytes\n' >&2
  exit 1
fi
grep -F 'downloaded object bytes do not match the registration SHA-256 and size' \
  "$work/rejection.log"
test ! -e /evidence/provenance/rejected-bytes

retained-artifact verify --registration "$registration" \
  --bundle "$work/retention.sigstore.json" --key "$work/signer.pub" \
  --output /evidence/provenance/recording-0
evidence-sink receipt "$source" 0 \
  --verification /evidence/provenance/recording-0/artifact-verification.json \
  --dependency /evidence/provenance/recording-0/statement.json \
  --dependency /evidence/provenance/recording-0/trust-policy.pem \
  --dependency /evidence/provenance/recording-0/verification-evidence.sigstore.json
evidence-sink finalize
SHELL
jq -e '
  .schema_version == "evidence-index.v1" and
  .finalized == true and
  .policy_observation.upload_mode == "closed_segments_during_run" and
  .policy_observation.remote_sink_used == true and
  (.artifacts | length) == 2 and
  ([.artifacts[] | select(
    .media_type == "application/mcap" and
    .storage_state == "retained" and
    (.immutable_revision | length) > 0 and
    (.recording_summary.sha256 | length) == 64 and
    (.receipt_sha256 | length) == 64
  )] | length) == 1 and
  ([.artifacts[] | select(
    .media_type == "application/vnd.example.controller-log" and
    .storage_state == "local"
  )] | length) == 1
' "${evidence_dir}/evidence-index.json"

docker run --rm -i --network none --read-only --cap-drop ALL \
  --security-opt no-new-privileges:true --env PYTHONDONTWRITEBYTECODE=1 \
  --mount "type=bind,src=${evidence_dir},dst=/evidence,readonly" \
  --mount "type=bind,src=${ROBOTICS_BAG_DIR},dst=/evidence/recordings,readonly" \
  --entrypoint /opt/venv/bin/python "$OBSERVER_IMAGE" - <<'PY'
from robotics_acceptance_harness.evidence import load_evidence_index
from robotics_acceptance_harness.receipts import ReceiptInventory

evidence = load_evidence_index(
    "/evidence/evidence-index.json",
    receipt_paths=ReceiptInventory("/evidence/receipt-inventory.json"),
)
assert len(evidence.receipts) == 1
assert len(evidence.recording_summaries) == 1
assert len(evidence.links) == 2
print("installed harness accepted the verified immutable S3 recording and local log")
PY
