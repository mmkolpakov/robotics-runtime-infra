#!/usr/bin/env bash
set -Eeuo pipefail

work="${RUNNER_TEMP}/permit-crypto"
rm -rf "${work}"
mkdir -p "${work}"
chmod 0777 "${work}"
jq '.execution_valid.statement' \
  test/policy/execution/valid.json > "${work}/statement.json"
cosign=(
  docker run --rm
  --env COSIGN_PASSWORD
  --volume "${work}:/work"
  --workdir /work
  --entrypoint /usr/local/bin/cosign
  "${PERMIT_PREFLIGHT_IMAGE}"
)
"${cosign[@]}" signing-config create \
  --no-default-fulcio \
  --no-default-oidc \
  --no-default-rekor \
  --no-default-tsa \
  --out offline-signing-config.json
"${cosign[@]}" generate-key-pair --output-key-prefix operator
"${cosign[@]}" attest-blob --yes \
  --key operator.key \
  --signing-config offline-signing-config.json \
  --bundle operator.sigstore.json \
  --statement statement.json
docker run --rm \
  --volume "${work}:/work:ro" \
  "${PERMIT_PREFLIGHT_IMAGE}" \
  verify-offline-test-attestation \
  /work/statement.json \
  /work/operator.sigstore.json \
  /work/operator.pub
jq '.predicate.permit_id = "tampered"' \
  "${work}/statement.json" > "${work}/tampered-statement.json"
if docker run --rm \
  --volume "${work}:/work:ro" \
  "${PERMIT_PREFLIGHT_IMAGE}" \
  verify-offline-test-attestation \
  /work/tampered-statement.json \
  /work/operator.sigstore.json \
  /work/operator.pub; then
  printf 'mismatched execution statement was accepted\n' >&2
  exit 1
fi
docker run --rm \
  --volume "${work}:/work:ro" \
  --entrypoint /usr/local/bin/yq \
  "${PERMIT_PREFLIGHT_IMAGE}" \
  --output-format json \
  '.dsseEnvelope.payload = (.dsseEnvelope.payload + "A")' \
  /work/operator.sigstore.json \
  > "${work}/tampered-operator.sigstore.json"
if docker run --rm \
  --volume "${work}:/work:ro" \
  "${PERMIT_PREFLIGHT_IMAGE}" \
  verify-offline-test-attestation \
  /work/statement.json \
  /work/tampered-operator.sigstore.json \
  /work/operator.pub; then
  printf 'tampered DSSE envelope was accepted\n' >&2
  exit 1
fi
rm -rf "${work}"
