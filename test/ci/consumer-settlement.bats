#!/usr/bin/env bats

setup() {
  REPOSITORY_ROOT="$(cd "${BATS_TEST_DIRNAME}/../.." && pwd -P)"
  # shellcheck source=scripts/ci/foundation/lib.sh
  source "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh"
  BIN="${BATS_TEST_TMPDIR}/bin"
  mkdir -p "${BIN}"
  export CALLS="${BATS_TEST_TMPDIR}/calls.jsonl" STATE="${BATS_TEST_TMPDIR}/stopped"
  export PATH="${BIN}:${PATH}"
  export ROBOTICS_RUN_ID=run-fixture ROBOTICS_DOMAIN_ID=primary
  unset DOCKER_HOST DOCKER_CONTEXT DOCKER_TLS_VERIFY DOCKER_CERT_PATH
  # The library resolves this array by its fixed nameref name.
  # shellcheck disable=SC2034
  compose=(docker compose)
  OUTPUT="${BATS_TEST_TMPDIR}/facts"
  MODEL="${BATS_TEST_TMPDIR}/model.json"
  printf '{"services":{"simulation":{"environment":{"ROS_DOMAIN_ID":"91","RMW_IMPLEMENTATION":"rmw_fastrtps_cpp"}},"probe-a":{"image":"fixture/image"},"probe-b":{"image":"fixture/image"}}}\n' >"${MODEL}"
  cat >"${BIN}/docker" <<'PY'
#!/usr/bin/env python3
import base64,json,os,sys,time
from pathlib import Path
args=sys.argv[1:]
with open(os.environ["CALLS"],"a") as stream: stream.write(json.dumps(args)+"\n")
mode=os.environ.get("MODE","")
a,b,image="a"*64,"b"*64,"sha256:"+"c"*64
stopped=Path(os.environ["STATE"]).exists()
if args[:2]==["context","show"]: print(os.environ.get("DOCKER_CONTEXT","owned-rootless"))
elif args[:2]==["context","inspect"]: print(json.dumps({"Host":os.environ.get("DOCKER_HOST","unix:///run/user/1000/owned-podman.sock"),"SkipTLSVerify":False}))
elif args[:2]==["image","inspect"]: print(image)
elif args[0]=="compose" and "ps" in args: print(a if args[-1]=="probe-a" else b)
elif args[0]=="inspect":
    cid=args[1]
    if stopped and mode=="late-inspect-refusal": sys.exit(44)
    project="foreign" if mode=="foreign-second" and cid==b else "owned"
    actual_image="sha256:"+"d"*64 if mode=="wrong-image" else image
    exit_code=7 if mode=="native-seven" else 0
    env=["ROS_DOMAIN_ID=91","RMW_IMPLEMENTATION=rmw_fastrtps_cpp","ROBOTICS_RUN_ID=run-fixture","ROBOTICS_DOMAIN_ID=primary","AWS_SECRET_ACCESS_KEY=PRIVATE_SENTINEL"]
    if mode=="non-ros": env=[v for v in env if not v.startswith(("ROS_DOMAIN_ID=","RMW_IMPLEMENTATION="))]
    if cid==b:
        if mode=="foreign-run": env=[v if not v.startswith("ROBOTICS_RUN_ID=") else "ROBOTICS_RUN_ID=foreign" for v in env]
        if mode=="foreign-domain": env=[v if not v.startswith("ROBOTICS_DOMAIN_ID=") else "ROBOTICS_DOMAIN_ID=foreign" for v in env]
        if mode=="wrong-route": env=[v if not v.startswith("ROS_DOMAIN_ID=") else "ROS_DOMAIN_ID=92" for v in env]
        if mode=="wrong-rmw": env=[v if not v.startswith("RMW_IMPLEMENTATION=") else "RMW_IMPLEMENTATION=foreign" for v in env]
        if mode=="duplicate-run": env.append("ROBOTICS_RUN_ID=run-fixture")
        if mode=="duplicate-route": env.append("ROS_DOMAIN_ID=91")
        if mode=="missing-run": env=[v for v in env if not v.startswith("ROBOTICS_RUN_ID=")]
        if mode=="missing-domain": env=[v for v in env if not v.startswith("ROBOTICS_DOMAIN_ID=")]
    print(json.dumps([{"Id":cid,"Image":actual_image,
      "Config":{"Labels":{"com.docker.compose.project":project,"com.docker.compose.service":"probe-a" if cid==a else "probe-b"},
       "Env":env,
       "Cmd":["PRIVATE_ARGV_MARKER"]},
      "State":{"Status":"exited" if stopped else "running","Running":not stopped,"Pid":0 if stopped else 1234,
       "ExitCode":exit_code,"OOMKilled":mode=="oom","StartedAt":"2026-10-08T00:00:00Z","FinishedAt":"2026-10-08T00:00:01Z" if stopped else ""},
      "RestartCount":1 if mode=="restart" else 0}]))
elif args[0]=="stop":
    Path(os.environ["STATE"]).touch()
    if mode=="stop-refusal": sys.exit(71)
    if mode=="late-inspect-refusal": sys.exit(71)
elif args[0]=="wait":
    if mode=="wait-timeout": time.sleep(30)
    if "WAIT_STDOUT_B64" in os.environ:
        sys.stdout.buffer.write(base64.b64decode(os.environ["WAIT_STDOUT_B64"],validate=True))
    else: print(7 if mode=="native-seven" else 0)
elif args[0]=="logs": print("observed ROS_DOMAIN_ID=91 opaque-sha="+"e"*64)
else: sys.exit(66)
PY
  chmod +x "${BIN}/docker"
}

settle() {
  foundation_bind_settlement_endpoint
  foundation_settle_caller_services compose owned "${MODEL}" "${OUTPUT}" simulation
}

@test "empty settlement preserves baseline without native commands or output" {
  foundation_load_settle_services '' probe-a
  run settle
  [ "${status}" -eq 0 ]
  [ ! -e "${CALLS}" ]
  [ ! -e "${OUTPUT}" ]
}

@test "settlement rejects duplicate or foreign service selection before effects" {
  run foundation_load_settle_services $'probe-a\nprobe-a' probe-a
  [ "${status}" -eq 64 ]
  run foundation_load_settle_services simulation probe-a
  [ "${status}" -eq 64 ]
  [ ! -e "${CALLS}" ]
}

@test "every selected CID is preflighted before the first stop and secret fields are excluded" {
  foundation_load_settle_services $'probe-a\nprobe-b' probe-a probe-b
  run settle
  [ "${status}" -eq 0 ]
  python3 - "${CALLS}" "${OUTPUT}" <<'PY'
import json,sys
from pathlib import Path
calls=[json.loads(line) for line in Path(sys.argv[1]).read_text().splitlines()]
stop=next(i for i,c in enumerate(calls) if c[0]=="stop")
preflight=[c for c in calls[:stop] if c[0]=="inspect"]
assert [c[1] for c in preflight]==["a"*64,"b"*64]
assert calls[stop]==["stop","--time","60","a"*64,"b"*64]
for service,cid in [("probe-a","a"*64),("probe-b","b"*64)]:
 root=Path(sys.argv[2])/service/cid
 before=json.loads((root/"before.json").read_text());after=json.loads((root/"after.json").read_text())
 assert before["state"]["pid"]==1234 and before["state"]["running"]
 assert after["state"]["pid"]==0 and not after["state"]["running"] and after["state"]["exit_code"]==0
 assert before["image_id"]==after["image_id"]=="sha256:"+"c"*64
 assert len(after["environment"])==4
 assert "PRIVATE_SENTINEL" not in (root/"after.json").read_text()
 assert "PRIVATE_ARGV_MARKER" not in (root/"before.json").read_text()
 assert (root/"native-wait.stdout").read_text()=="0\n"
PY
}

@test "a foreign second CID refuses the whole list before any stop wait or logs" {
  foundation_load_settle_services $'probe-a\nprobe-b' probe-a probe-b
  # Positional arguments are expanded by the child Bash, not this test shell.
  # shellcheck disable=SC2016
  run env MODE=foreign-second bash -c 'source "$1"; compose=(docker compose); foundation_load_settle_services $'\''probe-a\nprobe-b'\'' probe-a probe-b; foundation_bind_settlement_endpoint; foundation_settle_caller_services compose owned "$2" "$3" simulation' _ \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh" "${MODEL}" "${OUTPUT}"
  [ "${status}" -ne 0 ]
  run grep -E '"stop"|"wait"|"logs"' "${CALLS}"
  [ "${status}" -eq 1 ]
}

@test "wrong frozen image refuses before effects" {
  # Positional arguments are expanded by the child Bash, not this test shell.
  # shellcheck disable=SC2016
  run env MODE=wrong-image bash -c 'source "$1"; compose=(docker compose); foundation_load_settle_services probe-a probe-a; foundation_bind_settlement_endpoint; foundation_settle_caller_services compose owned "$2" "$3" simulation' _ \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh" "${MODEL}" "${OUTPUT}"
  [ "${status}" -ne 0 ]
  run grep -E '"stop"|"wait"|"logs"' "${CALLS}"
  [ "${status}" -eq 1 ]
}

@test "admitted nondefault rootless endpoint is accepted and changed endpoint refuses before effects" {
  # Positional arguments are expanded by the child Bash, not this test shell.
  # shellcheck disable=SC2016
  run env DOCKER_HOST=unix:///run/user/1000/owned-podman.sock DOCKER_CONTEXT=owned-rootless bash -c 'source "$1"; compose=(docker compose); foundation_load_settle_services probe-a probe-a; foundation_bind_settlement_endpoint; foundation_settle_caller_services compose owned "$2" "$3" simulation' _ \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh" "${MODEL}" "${OUTPUT}/valid"
  [ "${status}" -eq 0 ]
  rm -f "${CALLS}" "${STATE}"
  # Positional arguments are expanded by the child Bash, not this test shell.
  # shellcheck disable=SC2016
  run bash -c 'source "$1"; compose=(docker compose); foundation_load_settle_services probe-a probe-a; foundation_bind_settlement_endpoint; export DOCKER_HOST=tcp://foreign.invalid:2375; foundation_settle_caller_services compose owned "$2" "$3" simulation' _ \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh" "${MODEL}" "${OUTPUT}/changed"
  [ "${status}" -eq 65 ]
  run grep -E '"stop"|"wait"|"logs"' "${CALLS}"
  [ "${status}" -eq 1 ]
}

@test "native exit remains original and OOM or restart cannot become successful settlement" {
  for mode in native-seven oom restart; do
    # Positional arguments are expanded by the child Bash, not this test shell.
    # shellcheck disable=SC2016
    run env MODE="${mode}" bash -c 'source "$1"; compose=(docker compose); foundation_load_settle_services probe-a probe-a; foundation_bind_settlement_endpoint; foundation_settle_caller_services compose owned "$2" "$3" simulation' _ \
      "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh" "${MODEL}" "${OUTPUT}/${mode}"
    if [[ "${mode}" == native-seven ]]; then [ "${status}" -eq 7 ]; else [ "${status}" -eq 65 ]; fi
  done
}

@test "first stop failure survives later inspect refusal with original native receipts" {
  # Positional arguments are expanded by the child Bash, not this test shell.
  # shellcheck disable=SC2016
  run env MODE=late-inspect-refusal bash -c 'source "$1"; compose=(docker compose); foundation_load_settle_services probe-a probe-a; foundation_bind_settlement_endpoint; foundation_settle_caller_services compose owned "$2" "$3" simulation' _ \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh" "${MODEL}" "${OUTPUT}"
  [ "${status}" -eq 71 ]
  [ "$(cat "${OUTPUT}/native-stop.status")" = 71 ]
  [ "$(cat "${OUTPUT}/probe-a/$(printf a%.0s {1..64})/native-inspect.status")" = 44 ]
}

@test "native wait timeout remains refusal and retains its original status" {
  # Positional arguments are expanded by the child Bash, not this test shell.
  # shellcheck disable=SC2016
  run env MODE=wait-timeout bash -c 'source "$1"; compose=(docker compose); foundation_load_settle_services probe-a probe-a; foundation_bind_settlement_endpoint; foundation_settle_caller_services compose owned "$2" "$3" simulation' _ \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh" "${MODEL}" "${OUTPUT}"
  [ "${status}" -eq 124 ]
  [ "$(cat "${OUTPUT}/probe-a/$(printf a%.0s {1..64})/native-wait.status")" = 124 ]
}

@test "all selected run and optional routing markers are admitted before any logs or stop" {
  local mode
  for mode in foreign-run foreign-domain wrong-route wrong-rmw duplicate-run duplicate-route missing-run missing-domain; do
    rm -f "${CALLS}" "${STATE}"
    # Positional arguments are expanded by the child Bash, not this test shell.
    # shellcheck disable=SC2016
    run env MODE="${mode}" bash -c 'source "$1"; compose=(docker compose); foundation_load_settle_services $'\''probe-a\nprobe-b'\'' probe-a probe-b; foundation_bind_settlement_endpoint; foundation_settle_caller_services compose owned "$2" "$3" simulation' _ \
      "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh" "${MODEL}" "${OUTPUT}/${mode}"
    [ "${status}" -ne 0 ]
    [[ "${output}" == *run\ ownership\ or\ routing* ]]
    run grep -E '"stop"|"wait"|"logs"' "${CALLS}"
    [ "${status}" -eq 1 ]
  done
}

@test "opted-in non-ROS service needs run and domain markers without ROS fields" {
  # Positional arguments are expanded by the child Bash, not this test shell.
  # shellcheck disable=SC2016
  run env MODE=non-ros bash -c 'source "$1"; compose=(docker compose); foundation_load_settle_services probe-a probe-a; foundation_bind_settlement_endpoint; foundation_settle_caller_services compose owned "$2" "$3" simulation' _ \
    "${REPOSITORY_ROOT}/scripts/ci/foundation/lib.sh" "${MODEL}" "${OUTPUT}"
  [ "${status}" -eq 0 ]
  jq -e '.environment == ["ROBOTICS_RUN_ID=run-fixture","ROBOTICS_DOMAIN_ID=primary"]' \
    "${OUTPUT}/probe-a/$(printf a%.0s {1..64})/after.json" >/dev/null
}

@test "native wait accepts a single integer with optional terminal newline and retains exact bytes" {
  local encoded attempt=0 directory
  for encoded in MA== MAo=; do
    attempt=$((attempt + 1))
    rm -f "${CALLS}" "${STATE}"
    export WAIT_STDOUT_B64="${encoded}"
    foundation_load_settle_services probe-a probe-a
    foundation_bind_settlement_endpoint
    run foundation_settle_caller_services compose owned "${MODEL}" "${OUTPUT}/${attempt}" simulation
    [ "${status}" -eq 0 ]
    directory="${OUTPUT}/${attempt}/probe-a/$(printf a%.0s {1..64})"
    python3 - "${directory}/native-wait.stdout" "${encoded}" <<'PY'
import base64,sys
from pathlib import Path
assert Path(sys.argv[1]).read_bytes() == base64.b64decode(sys.argv[2],validate=True)
PY
  done
}

@test "malformed extra or mismatched native wait lines refuse without rewriting diagnostics" {
  local encoded attempt=0 directory
  for encoded in MAo3Cg== MAoK MA0K MCAK LTEK MjU2Cg== Z2FyYmFnZQo= Nwo=; do
    attempt=$((attempt + 1))
    rm -f "${CALLS}" "${STATE}"
    export WAIT_STDOUT_B64="${encoded}"
    foundation_load_settle_services probe-a probe-a
    foundation_bind_settlement_endpoint
    run foundation_settle_caller_services compose owned "${MODEL}" "${OUTPUT}/${attempt}" simulation
    [ "${status}" -eq 65 ]
    directory="${OUTPUT}/${attempt}/probe-a/$(printf a%.0s {1..64})"
    [ "$(cat "${directory}/native-wait.status")" = 0 ]
    [ -s "${directory}/after.json" ]
    [ -s "${directory}/logs-after.txt" ]
    python3 - "${directory}/native-wait.stdout" "${encoded}" <<'PY'
import base64,sys
from pathlib import Path
assert Path(sys.argv[1]).read_bytes() == base64.b64decode(sys.argv[2],validate=True)
PY
  done
}
