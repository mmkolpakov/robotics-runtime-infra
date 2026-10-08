#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"
engine="${ROBOTICS_IMAGE_ENGINE:-docker}"
case "${engine}" in docker|podman) ;; *) exit 64 ;; esac
revision="$(python3 -c 'import json; print(json.load(open("host/source-lock.json"))["revision"])')"
url="$(python3 -c 'import json; print(json.load(open("host/source-lock.json"))["repository"])')"
core_sha="$(python3 -c 'import json; print(json.load(open("host/source-lock.json"))["core_asset_sha256"])')"
core="${root}/dependencies/host-runtime"
asset="${root}/host/.tools/host-asset"
[[ "${revision}" =~ ^[a-f0-9]{40}$ && "${core_sha}" =~ ^[a-f0-9]{64}$ ]] || exit 65
if [[ ! -d "${core}/.git" ]]; then
  git clone --no-checkout --filter=blob:none "${url}" "${core}"
  git -C "${core}" checkout --detach "${revision}"
fi
[[ -z "$(git -C "${core}" status --porcelain)" ]] || exit 65
[[ "$(git -C "${core}" remote get-url origin)" == "${url}" ]] || exit 65
if [[ "$(git -C "${core}" rev-parse HEAD 2>/dev/null || true)" != "${revision}" ]]; then
  git -C "${core}" fetch --depth=1 origin "${revision}"
  git -C "${core}" checkout --detach "${revision}"
fi
[[ "$(git -C "${core}" rev-parse HEAD)" == "${revision}" ]] || exit 65
git diff --exit-code -- host/src host/package.json host/package-lock.json
mkdir -p "${asset}"
node_image="node:24.21.0-trixie-slim@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697"
engine_options=(--rm --user "$(id -u):$(id -g)" --env NPM_CONFIG_CACHE=/tmp/npm-cache)
if [[ "${engine}" == podman ]]; then engine_options+=(--userns=keep-id); fi
"${engine}" run "${engine_options[@]}" --mount "type=bind,source=${root},target=/workspace" \
  --workdir /workspace/dependencies/host-runtime/host "${node_image}" \
  bash -Eeuo pipefail -c '
    node --version | grep --fixed-strings --line-regexp v24.21.0
    npm --version | grep --fixed-strings --line-regexp 11.19.0
    npm ci --ignore-scripts --no-fund
    npm test
    npm run check:boundary
    npm audit --audit-level=high
    npm pack --ignore-scripts --pack-destination /workspace/host/.tools/host-asset --json
  '
core_file="${asset}/robotics-runtime-host-0.1.0-rc.0.tgz"
printf '%s  %s\n' "${core_sha}" "${core_file}" | sha256sum --check
core_dependency="$(python3 -c 'import json; print(json.load(open("host/package.json"))["devDependencies"]["@robotics-runtime/host"])')"
[[ "${core_dependency}" == "file:.tools/core-${revision}.tgz" ]] || exit 65
cp "${core_file}" "host/${core_dependency#file:}"
"${engine}" run "${engine_options[@]}" --mount "type=bind,source=${root},target=/workspace" \
  --workdir /workspace/host "${node_image}" \
  bash -Eeuo pipefail -c '
    npm ci --ignore-scripts --no-fund
    npm test
    node --test \
      tools/qualify-legacy-live.test.mjs \
      test/fixtures/installed-webots/timeout-diagnostics.test.mjs
    npm audit --audit-level=high
    npm pack --ignore-scripts --pack-destination .tools/host-asset --json
  '
infra_file="${asset}/robotics-runtime-infra-host-0.1.0-rc.0.tgz"
cp "${core_file}" "${asset}/core.tgz"
cp "${infra_file}" "${asset}/infra.tgz"
python3 - "${asset}/package.json" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({
    "name": "robotics-host-installation", "private": True, "type": "module",
    "dependencies": {
        "@robotics-runtime/host": "file:core.tgz",
        "@robotics-runtime/infra-host": "file:infra.tgz",
    },
}, indent=2) + "\n")
PY
"${engine}" run "${engine_options[@]}" --mount "type=bind,source=${asset},target=/asset" \
  --workdir /asset "${node_image}" npm install --package-lock-only --ignore-scripts --no-fund
infra_sha="$(sha256sum "${infra_file}" | cut -d ' ' -f 1)"
python3 - "${asset}/source-identity.json" "${revision}" "$(git rev-parse HEAD)" "${core_sha}" "${infra_sha}" <<'PY'
import json
import sys
from pathlib import Path

path, core_revision, infra_revision, core_sha, infra_sha = sys.argv[1:]
Path(path).write_text(json.dumps({
    "core": {"revision": core_revision, "sha256": core_sha},
    "infra": {"revision": infra_revision, "sha256": infra_sha},
}, indent=2) + "\n")
PY
if [[ -n "${GITHUB_ENV:-}" ]]; then
  printf 'HOST_ASSET_CONTEXT=%s\nHOST_ASSET_SHA256=%s\nHOST_INFRA_ASSET_SHA256=%s\n' \
    "${asset}" "${core_sha}" "${infra_sha}" >>"${GITHUB_ENV}"
fi
