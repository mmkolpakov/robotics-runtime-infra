#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  FIXTURE="${BATS_TEST_TMPDIR}/fixture"
  MOCK_BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${FIXTURE}/scripts/ci/host" "${MOCK_BIN}" "${BATS_TEST_TMPDIR}/work"
  cp "${REPOSITORY_ROOT}/scripts/ci/host/run-installed-legacy.sh" "${FIXTURE}/scripts/ci/host/"
  export MOCK_FIXTURE="${FIXTURE}" MOCK_CALLS="${BATS_TEST_TMPDIR}/calls.jsonl"
  REAL_PYTHON="$(command -v python3)"
  export REAL_PYTHON
  "${REAL_PYTHON}" - "${MOCK_BIN}" "${BATS_TEST_TMPDIR}/engine.sock" <<'PY'
import os, socket, sys
from pathlib import Path

folder = Path(sys.argv[1])
sock = socket.socket(socket.AF_UNIX)
sock.bind(sys.argv[2])
header = "#!" + sys.executable + "\n"
docker = r'''
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
with open(os.environ["MOCK_CALLS"], "a") as f:
    f.write(json.dumps(a) + "\n")
run = "run-12345678-1234-1234-1234-123456789abc"
owner = "installed-ros-host-12345678"
scope = "installed-ros-101-1"
if a[:1] == ["version"]:
    print("linux/amd64" if "--format" in a else "mock Docker")
elif a[:2] == ["buildx", "inspect"]:
    print("Driver: docker")
elif a[:2] == ["image", "inspect"]:
    if "--format" in a:
        print("sha256:" + "a" * 64)
    else:
        repo = a[-1].rsplit(":", 1)[0]
        print(json.dumps([{"RepoDigests": [repo + "@sha256:" + "b" * 64]}]))
elif a[:1] == ["inspect"]:
    print("5000" if "HostPort" in " ".join(a) else scope)
elif a[:2] == ["volume", "inspect"]:
    labels = {"org.robotics.runtime.run-id": owner, "org.robotics.runtime.storage-owner": owner,
              "com.docker.compose.project": "rr-installed-ros-host-12345678"}
    if os.environ.get("MOCK_FOREIGN_VOLUME"):
        labels["org.robotics.runtime.run-id"] = "foreign"
    print(json.dumps([{"Name": a[-1], "Labels": labels}]))
elif a[:1] == ["run"]:
    if "--detach" in a:
        print("c" * 64)
    elif any(v.endswith("/launch.mjs") for v in a):
        target = Path(a[-1])
        target.mkdir()
        (target / "failure.json").write_text(json.dumps({
            "status": "failed", "runId": run, "project": "rr-installed-ros-host-12345678",
            "diagnostic": "original launcher failure"}))
        sys.exit(57)
elif a[:1] == ["create"]:
    print("d" * 64)
elif a[:1] == ["cp"]:
    if os.environ.get("MOCK_COPY_FAILURE"):
        sys.exit(23)
    target = Path(a[-1])
    target.mkdir(exist_ok=True)
    (target / "available.bin").write_bytes(b"owned diagnostic bytes")
'''
python = r'''
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
if a[:2] == ["-m", "unittest"]:
    sys.exit(0)
if a and a[0].endswith("/prepare.py"):
    consumer = Path(a[a.index("--consumer") + 1])
    consumer.mkdir()
    (consumer / "input.bin").write_bytes(b"generated deployment input")
    print("{}")
    sys.exit(0)
os.execv(os.environ["REAL_PYTHON"], [os.environ["REAL_PYTHON"], *a])
'''
bash = r'''
import json, os, sys
from pathlib import Path
a = sys.argv[1:]
if a and a[0].endswith("/build-assets.sh"):
    asset = Path(os.environ["MOCK_FIXTURE"]) / "host/.tools/host-asset"
    asset.mkdir(parents=True)
    (asset / "source-identity.json").write_text(json.dumps({"scope": "mock archive builder"}))
    for name in ("core.tgz", "infra.tgz"):
        (asset / name).write_bytes(b"mock archive")
    sys.exit(0)
os.execv("/usr/bin/bash", ["/usr/bin/bash", *a])
'''
for name, raw in {"docker": docker, "python3": python, "bash": bash,
                  "git": "print('a' * 40)\n", "curl": "print('{}')\n"}.items():
    path = folder / name
    path.write_text(header + raw)
    path.chmod(0o755)
PY
  OUTPUT_DIRECTORY="${FIXTURE}/artifacts/installed-ros/installed-ros-101-1"
}

run_failed_fixture() {
  run env PATH="${MOCK_BIN}:${PATH}" \
    ROBOTICS_COMPOSE="${ROBOTICS_COMPOSE:?pinned Compose required}" \
    ROBOTICS_DOCKER_SOCKET="${BATS_TEST_TMPDIR}/engine.sock" \
    GITHUB_RUN_ID=101 GITHUB_RUN_ATTEMPT=1 GITHUB_ENV="${BATS_TEST_TMPDIR}/github-env" RUNNER_TEMP="${BATS_TEST_TMPDIR}/work" \
    SIMULATION_IMAGE=local/simulation:fixture \
    /usr/bin/bash "${FIXTURE}/scripts/ci/host/run-installed-legacy.sh"
}

assert_incomplete_and_inputs_preserved() {
  [ "${status}" -eq 57 ]
  "${REAL_PYTHON}" - "${OUTPUT_DIRECTORY}" <<'PY'
import json, sys
from pathlib import Path
root = Path(sys.argv[1])
marker = json.loads((root / "failure-snapshot.json").read_bytes())
assert marker["status"] == "incomplete"
assert marker["diagnostic_only"] is True
assert marker["qualification_pass"] is False
assert marker["settlement"] == "not-established"
assert marker["original_exit_code"] == 57
work = Path(marker["preserved_work"])
assert work.is_dir()
assert (work / "consumer/input.bin").read_bytes() == b"generated deployment input"
assert (root / "generated-inputs/input.bin").read_bytes() == b"generated deployment input"
PY
}

@test "failed installed wrapper preserves generated inputs and owned incomplete bytes" {
  run_failed_fixture
  assert_incomplete_and_inputs_preserved
  [ "$(cat "${OUTPUT_DIRECTORY}/failed-retained-snapshot/available.bin")" = "owned diagnostic bytes" ]
  [ "$(cat "${OUTPUT_DIRECTORY}/failed-source-snapshot/available.bin")" = "owned diagnostic bytes" ]
}

@test "failed installed wrapper refuses a foreign-label volume before snapshot copying" {
  export MOCK_FOREIGN_VOLUME=1
  run_failed_fixture
  assert_incomplete_and_inputs_preserved
  "${REAL_PYTHON}" - "${MOCK_CALLS}" <<'PY'
import json, sys
calls = [json.loads(v) for v in open(sys.argv[1])]
assert not any(v[0] == "cp" for v in calls)
assert not any(v[0] in ("stop", "kill") for v in calls)
PY
  [ ! -e "${OUTPUT_DIRECTORY}/failed-retained-snapshot" ]
}

@test "secondary diagnostic copy failure keeps the original installed exit and inputs" {
  export MOCK_COPY_FAILURE=1
  run_failed_fixture
  assert_incomplete_and_inputs_preserved
  grep -q 'owned snapshot copy failed' "${OUTPUT_DIRECTORY}/diagnostic-errors.log"
}
