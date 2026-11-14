#!/usr/bin/env bats

@test "an untrusted core download never reaches the adapter builder or cache" {
  root="${BATS_TEST_TMPDIR}/fixture"
  bin="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${root}/scripts/ci/host" "${root}/host" "${bin}"
  cp "${BATS_TEST_DIRNAME}/../../scripts/ci/host/build-assets.sh" "${root}/scripts/ci/host/"
  python3 - "${root}" "${bin}" <<'PY'
import json
import sys
from pathlib import Path

root, binary = map(Path, sys.argv[1:])
(root / "host/source-lock.json").write_text(json.dumps({
    "repository": "https://github.com/example/core.git",
    "revision": "a" * 40, "version": "0.1.0-rc.1",
    "core_asset_sha256": "0" * 64,
}))
(root / "host/package.json").write_text(json.dumps({
    "version": "0.1.0-rc.1",
    "peerDependencies": {"@robotics-runtime/host": "0.1.0-rc.1"},
}))
for name, body in {
    "git": "exit 0",
    "docker": "touch \"$BUILDER_CALLED\"; exit 99",
    "curl": "while [ \"$1\" != --output ]; do shift; done; printf untrusted > \"$2\"",
}.items():
    path = binary / name
    path.write_text("#!/bin/sh\n" + body + "\n")
    path.chmod(0o755)
PY
  export BUILDER_CALLED="${BATS_TEST_TMPDIR}/builder-called"
  run env PATH="${bin}:${PATH}" bash "${root}/scripts/ci/host/build-assets.sh"
  [ "${status}" -ne 0 ]
  [[ "${output}" == *"computed checksum did NOT match"* ]]
  [ ! -e "${BUILDER_CALLED}" ]
  [ ! -e "${root}/host/.tools/host-asset/robotics-runtime-host-0.1.0-rc.1.tgz" ]
  run find "${root}/host/.tools/host-asset" -name '.core-download.*' -print
  [ -z "${output}" ]
}
