#!/usr/bin/env bats

setup() {
  REPO_ROOT="$(cd -- "${BATS_TEST_DIRNAME}/../.." && pwd)"
  cd "${REPO_ROOT}" || return
}

@test "Renovate batches updates and limits concurrent pull requests" {
  run jq -e '
    (.schedule | length) > 0
    and .prConcurrentLimit >= 1 and .prConcurrentLimit <= 3
    and .rebaseWhen == "conflicted"
    and any(.packageRules[]; .groupName == "digest refreshes"
      and (.matchUpdateTypes | index("digest")))
    and any(.packageRules[]; .groupName == "minor and patch releases"
      and (.matchUpdateTypes | index("minor")))
  ' renovate.json
  [ "${status}" -eq 0 ]
}

@test "Renovate tracks digest-pinned CI tool images" {
  run jq -e '
    any(.customManagers[];
      any(.managerFilePatterns[]; startswith("/^\\.github/workflows/"))
      and .datasourceTemplate == "docker"
      and any(.matchStrings[]; contains("_IMAGE:")))
  ' renovate.json
  [ "${status}" -eq 0 ]
}
