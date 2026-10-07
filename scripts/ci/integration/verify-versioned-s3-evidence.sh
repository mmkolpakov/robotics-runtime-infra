#!/usr/bin/env bash
set -Eeuo pipefail

root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "$root"
: "${OBSERVER_IMAGE:?OBSERVER_IMAGE is required for the installed harness check}"
evidence_dir="${PWD}/artifacts/evidence-s3"
project="evidence-s3-${GITHUB_RUN_ID}-${GITHUB_RUN_ATTEMPT}"
mkdir -p "${evidence_dir}"
printf 'opaque controller evidence\n' >"${evidence_dir}/controller.log"
printf '{"event":"opaque attachment"}\n' >"${evidence_dir}/emissions.jsonl"
printf '\211PNG\r\n\032\nopaque fixture' >"${evidence_dir}/attachment.png"
: >"${evidence_dir}/empty.log"
export EVIDENCE_ARTIFACT_MEDIA_TYPES='application/json,application/x-ndjson,application/junit+xml,text/plain,application/vnd.in-toto+json,application/vnd.example.controller-log,image/png'
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
for binding in 'emissions.jsonl application/x-ndjson 900002' \
  'attachment.png image/png 900003' 'empty.log text/plain 900004'; do
  read -r file media index <<<"$binding"
  "${compose[@]}" --profile test --profile evidence \
    run --rm evidence-finalize artifact "/evidence/$file" "$media" "$index"
done
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

# A restored spool can have a different mtime. Equal bytes must reuse the
# existing object version, including when the local registration was lost.
retry_source="$work/$(basename "$source")"
cp "$source" "$retry_source"
touch -m -d '2030-01-01T00:00:00Z' "$retry_source"
retry_registration_dir=/evidence/state/restored-spool
EVIDENCE_REGISTRATION_DIR="$retry_registration_dir" evidence-sink segment "$retry_source"
test "$(jq -er '.version_id' "$retry_registration_dir/0-${digest}.json")" = \
  "$(jq -er '.version_id' "$registration")"

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

# A retry without the local registration must not overwrite another latest
# version. The signed original remains readable through its retained VersionId.
retry_registrations=/evidence/state/rejected-reupload
if EVIDENCE_REGISTRATION_DIR="$retry_registrations" evidence-sink segment "$source" \
  >"$work/reupload.log" 2>&1; then
  printf 'evidence sink overwrote an existing different object\n' >&2
  exit 1
fi
grep -F 'rclone upload failed' "$work/reupload.log"
test ! -e "$retry_registrations/0-${digest}.json"
latest_version="$(aws s3api head-object --bucket "$EVIDENCE_BUCKET" --key "$key" \
  --query VersionId --output text --no-cli-pager)"
test "$latest_version" = "$changed_version"

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
# Every confirmed generic upload follows the same signature, exact-version
# verifier, and receipt writer before the index can be finalized.
for registration in /evidence/state/registrations/*.json; do
  index="$(jq -er '.segment_index' "$registration")"
  [[ "$index" != 0 ]] || continue
  source="$(jq -er '.local_path' "$registration")"
  provenance="/evidence/provenance/attachment-$index"
  retained-artifact predicate --registration "$registration" --source "$source" \
    >"$work/predicate-$index.json"
  cosign attest-blob --yes --key "$work/signer.key" \
    --signing-config "$work/signing.json" --trusted-root "$work/root.json" \
    --predicate "$work/predicate-$index.json" \
    --type https://robotics-runtime.dev/attestations/artifact-retention/v1 \
    --bundle "$work/retention-$index.sigstore.json" "$source"
  retained-artifact verify --registration "$registration" \
    --bundle "$work/retention-$index.sigstore.json" --key "$work/signer.pub" \
    --output "$provenance"
  evidence-sink receipt "$source" "$index" \
    --verification "$provenance/artifact-verification.json" \
    --dependency "$provenance/statement.json" \
    --dependency "$provenance/trust-policy.pem" \
    --dependency "$provenance/verification-evidence.sigstore.json"
done
evidence-sink finalize
SHELL
jq -e '
  .schema_version == "evidence-index.v1" and
  .finalized == true and
  .policy_observation.upload_mode == "closed_segments_during_run" and
  .policy_observation.remote_sink_used == true and
  (.artifacts | length) == 5 and
  ([.artifacts[] | select(
    .media_type == "application/mcap" and
    .storage_state == "retained" and
    (.immutable_revision | length) > 0 and
    (.recording_summary.sha256 | length) == 64 and
    (.receipt_sha256 | length) == 64
  )] | length) == 1 and
  ([.artifacts[] | select(
    .media_type != "application/mcap" and .storage_state == "retained" and
    (.immutable_revision | length) > 0 and (.receipt_sha256 | length) == 64
  )] | length) == 4 and
  ([.artifacts[] | select(.media_type == "text/plain" and .size_bytes == 0)] | length) == 1 and
  ([.artifacts[] | select(.media_type == "image/png")] | length) == 1 and
  ([.artifacts[] | select(.media_type == "application/x-ndjson")] | length) == 1
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
assert len(evidence.receipts) == 5
assert len(evidence.recording_summaries) == 1
assert len(evidence.links) == 5
print("installed harness accepted exact-version S3 recording and opaque JSONL/PNG/zero-byte attachments")
PY
