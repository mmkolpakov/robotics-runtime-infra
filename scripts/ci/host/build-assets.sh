#!/usr/bin/env bash
set -Eeuo pipefail
root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd -P)"
cd "${root}"
engine="${ROBOTICS_IMAGE_ENGINE:-docker}"
case "${engine}" in docker|podman) ;; *) exit 64 ;; esac
revision="$(python3 -c 'import json; print(json.load(open("host/source-lock.json"))["revision"])')"
url="$(python3 -c 'import json; print(json.load(open("host/source-lock.json"))["repository"])')"
core_sha="$(python3 -c 'import json; print(json.load(open("host/source-lock.json"))["core_asset_sha256"])')"
core_version="$(python3 -c 'import json; print(json.load(open("host/source-lock.json"))["version"])')"
infra_version="$(python3 -c 'import json; print(json.load(open("host/package.json"))["version"])')"
peer_version="$(python3 -c 'import json; print(json.load(open("host/package.json"))["peerDependencies"]["@robotics-runtime/host"])')"
asset="${root}/host/.tools/host-asset"
[[ "${revision}" =~ ^[a-f0-9]{40}$ && "${core_sha}" =~ ^[a-f0-9]{64}$ ]] || exit 65
[[ "${core_version}" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ && "${infra_version}" =~ ^[0-9A-Za-z][0-9A-Za-z.+-]*$ ]] || exit 65
[[ "${peer_version}" == "${core_version}" ]] || exit 65
git diff --exit-code -- host/src host/source-lock.json host/package.json host/package-lock.json
mkdir -p "${asset}"
core_file="${asset}/robotics-runtime-host-${core_version}.tgz"
if [[ -e "${core_file}" ]]; then
  [[ -f "${core_file}" && ! -L "${core_file}" ]] || exit 65
else
  pending="$(mktemp "${asset}/.core-download.XXXXXX")"
  trap 'rm -f -- "${pending}"' EXIT
  curl --fail --location --retry 3 --max-time 300 --proto '=https' --proto-redir '=https' \
    --output "${pending}" "${url%.git}/releases/download/host-v${core_version}/robotics-runtime-host-${core_version}.tgz"
  printf '%s  %s\n' "${core_sha}" "${pending}" | sha256sum --check
  mv "${pending}" "${core_file}"
  trap - EXIT
fi
printf '%s  %s\n' "${core_sha}" "${core_file}" | sha256sum --check
node_image="node:24.21.0-trixie-slim@sha256:b64fccfbcd1ae10d11b969a868b50e1c2530a7054813d5cdea04ac3bce551697"
engine_options=(--rm --user "$(id -u):$(id -g)" --env NPM_CONFIG_CACHE=/tmp/npm-cache)
if [[ "${engine}" == podman ]]; then engine_options+=(--userns=keep-id); fi
core_dependency="$(python3 -c 'import json; print(json.load(open("host/package.json"))["devDependencies"]["@robotics-runtime/host"])')"
[[ "${core_dependency}" == "file:.tools/core-${revision}.tgz" ]] || exit 65
cp "${core_file}" "host/${core_dependency#file:}"
"${engine}" run "${engine_options[@]}" --mount "type=bind,source=${root},target=/workspace" \
  --workdir /workspace/host "${node_image}" \
  bash -Eeuo pipefail -c '
    node --version | grep --fixed-strings --line-regexp v24.21.0
    npm --version | grep --fixed-strings --line-regexp 11.19.0
    npm ci --ignore-scripts --no-audit --no-fund
    npm test
    node --test \
      tools/qualify-legacy-live.test.mjs \
      test/fixtures/installed-webots/timeout-diagnostics.test.mjs
    npm audit --audit-level=high
    npm pack --ignore-scripts --pack-destination .tools/host-asset --json
  '
infra_file="${asset}/robotics-runtime-infra-host-${infra_version}.tgz"
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
consumer="$(mktemp -d "${root}/host/.tools/installed-pair.XXXXXX")"
trap 'rm -rf -- "${consumer}"' EXIT
cp "${asset}/core.tgz" "${asset}/infra.tgz" "${asset}/package.json" "${consumer}/"
"${engine}" run --interactive "${engine_options[@]}" --mount "type=bind,source=${root},target=/workspace" \
  --workdir "/workspace/${consumer#"${root}/"}" "${node_image}" bash -Eeuo pipefail -s <<'CHECK'
npm install --package-lock-only --ignore-scripts --no-fund
npm ci --ignore-scripts --no-audit --no-fund
npm ls @robotics-runtime/host --all --json
npm audit --omit=dev --audit-level=high
node --input-type=module <<'JS'
import assert from 'node:assert/strict';
import {realpathSync, writeFileSync} from 'node:fs';
import {findPackageJSON} from 'node:module';
import {Admission, RunOwner, Jobs, Service} from '@robotics-runtime/host';
import Px4 from '@robotics-runtime/infra-host/plugins/px4';
const provider = import.meta.resolve('@robotics-runtime/infra-host/plugins/px4');
const origin = realpathSync(findPackageJSON('@robotics-runtime/host', import.meta.url));
assert.equal(origin, realpathSync(findPackageJSON('@robotics-runtime/host', provider)));
assert.equal(typeof Admission.prototype.admit, 'function');
assert.equal(typeof RunOwner.prototype.start, 'function');
assert.equal(typeof Jobs.prototype.run, 'function');
assert.ok(Px4.prototype instanceof Service);
writeFileSync('installed-pair.json', JSON.stringify({singleCoreOrigin: origin, providerImport: true,
  scope: 'installed package identity and public API; no native execution'}) + '\n');
JS
CHECK
cp "${consumer}/package-lock.json" "${asset}/package-lock.json"
cp "${consumer}/installed-pair.json" "${asset}/installed-pair.json"
rm -rf -- "${consumer}"
trap - EXIT
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
