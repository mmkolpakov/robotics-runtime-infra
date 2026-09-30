#!/usr/bin/env bash
set -Eeuo pipefail

cd "$(dirname -- "${BASH_SOURCE[0]}")/../../.."
image="$(
  docker buildx bake --file docker-bake.hcl permit-preflight --print \
    | jq -er '.target["permit-preflight"].args.COSIGN_IMAGE'
)"
cosign verify \
  --certificate-oidc-issuer=https://token.actions.githubusercontent.com \
  --certificate-identity=https://github.com/chainguard-images/images/.github/workflows/release.yaml@refs/heads/main \
  "${image}"
