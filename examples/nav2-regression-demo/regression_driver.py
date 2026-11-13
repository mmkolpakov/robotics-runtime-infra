#!/usr/bin/env python3
"""Honest Nav2 qualification demo over one recorded capture.

Five custody cases are assessed through the published acceptance SDK public
``robotics-acceptance evaluate`` path with real Cosign key-only evaluator
admission. Every case reuses the original recorded bytes; none synthesizes a
physical fact. The cases separate the verdict taxonomy:

  baseline             accepted criterion, full custody        -> passed
  criterion-sensitivity tightened acceptance tolerance          -> failed
  insufficient-observation postcondition not retained          -> incomplete
  evidence-refusal     tampered evidence copy, custody refused  -> error
  missing-coverage     required original result omitted         -> incomplete

The headline live A/B pair (a real Nav2 goal-checker configuration change with
two fresh recordings under one frozen contract) is a separate live command; it
is not claimed here. The criterion-sensitivity case changes only the declared
acceptance tolerance, so it is labelled criterion sensitivity, not a regression.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import os
import re
import shutil
import subprocess
import sys
import xml.etree.ElementTree as ET
from datetime import UTC, datetime
from pathlib import Path

from nav2_turtlebot3_evaluator import NAMESPACE
from robotics_acceptance_harness.evaluator_trust import CosignKeyWheelPolicy

DEMO = Path(__file__).resolve().parent
EXAMPLE = DEMO.parent / "nav2-turtlebot3"
FIXTURES = EXAMPLE / "evaluator" / "tests" / "fixtures"
READINESS_CONTROL = EXAMPLE / "evaluator" / "tests" / "readiness-control.json"
SCHEMA_URI = "urn:nav2-turtlebot3:scenario:v1"
PREDICATE_TYPE = "urn:nav2-turtlebot3:consumer-evaluator-qualification:v1"
RUN_IDS = {
    "baseline": "run-11111111-2222-4333-8444-555555555555",
    "criterion-sensitivity": "run-22222222-3333-4444-8555-666666666666",
    "insufficient-observation": "run-33333333-4444-4555-8666-777777777777",
    "evidence-refusal": "run-44444444-5555-4666-8777-888888888888",
    "missing-coverage": "run-55555555-6666-4777-8888-999999999999",
}
OUTSIDE_SCOPE = ["cancel", "timeout", "server-failure"]


def _module(name):
    spec = importlib.util.spec_from_file_location(
        name.replace("-", "_"), EXAMPLE / (name + ".py")
    )
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


PREPARE = _module("make-scenario")
FINALIZE = _module("finalize")
QUALIFY = _module("qualify-evaluator")


def _dump(path, value):
    path.write_text(json.dumps(value))
    return path


def _sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def _reference(path):
    raw = Path(path).read_bytes()
    return {
        "uri": Path(path).resolve().as_uri(),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "media_type": "application/json",
    }


def _readiness():
    return json.loads(READINESS_CONTROL.read_bytes())


def sdk_versions():
    """Read the exact cohort from the committed lock, never hardcode it."""
    lock = (EXAMPLE / "requirements.lock").read_text()
    versions = {}
    for name in ("robotics-acceptance-harness", "robotics-runtime-contracts"):
        match = re.search(
            rf"^{re.escape(name)}==([0-9.]+) --hash=sha256:([0-9a-f]{{64}})",
            lock,
            re.MULTILINE,
        )
        if not match:
            raise ValueError(f"{name} is absent from requirements.lock")
        versions[name] = {"version": match.group(1), "wheel_sha256": match.group(2)}
    pyproject = (EXAMPLE / "evaluator" / "pyproject.toml").read_text()
    evaluator = re.search(r'^version = "([^"]+)"', pyproject, re.MULTILINE)
    versions["nav2-turtlebot3-evaluator"] = {"version": evaluator.group(1)}
    return versions


def _profile():
    return {
        "profile_id": NAMESPACE,
        "executor": {"implementation": NAMESPACE, "version": "recorded-nav2-capture"},
        "channels": [
            {
                "name": "/odom",
                "original_type": {
                    "name": "nav_msgs/msg/Odometry",
                    "type_support": {"implementation": "rosidl", "version": "Jazzy"},
                },
                "backend": "ROS-DDS",
                "wire_envelope": "native-ROS-message",
                "native_encoding": "CDR",
                "recorder": {
                    "implementation": "rosbag2",
                    "version": "0.26.11",
                    "transformation": "none",
                },
            }
        ],
        "clock": {"kind": "sim_clock", "source_id": "gazebo-harmonic-clock"},
        "observations": {
            "command": {"kind": "command_acceptance", "requirement": "required"},
            "terminal": {"kind": "native_final_state", "requirement": "required"},
            "condition": {"kind": "postcondition", "requirement": "required"},
            "cleanup": {"kind": "shutdown", "requirement": "required"},
        },
    }


def _unix_ns_to_iso(ns):
    return datetime.fromtimestamp(ns / 1e9, UTC).isoformat()


def _recording_times(report):
    """started/finished come from the recorded observation clocks, not now()."""
    started = report["initial_odometry"]["observed_unix_ns"]
    finished = report["final_amcl_pose"]["observed_unix_ns"]
    return _unix_ns_to_iso(started), _unix_ns_to_iso(finished)


def decode_cdr(raw):
    """Decode the native GetResult CDR fields, not only its digest."""
    if len(raw) < 5:
        raise ValueError("GetResult CDR is shorter than its encapsulation and status")
    representation = int.from_bytes(raw[:2], "big")
    encoding = {0: "CDR_BE", 1: "CDR_LE", 2: "PL_CDR_BE", 3: "PL_CDR_LE"}.get(
        representation, f"unknown(0x{representation:04x})"
    )
    status = raw[4]
    status_name = {
        0: "UNKNOWN",
        1: "ACCEPTED",
        2: "EXECUTING",
        3: "CANCELING",
        4: "SUCCEEDED",
        5: "CANCELED",
        6: "ABORTED",
    }.get(status, f"UNKNOWN({status})")
    return {
        "encapsulation": encoding,
        "representation_identifier": f"0x{representation:04x}",
        "status_int8": status,
        "status_name": status_name,
        "result_payload_hex": raw[5:].hex(),
        "result_payload_bytes": len(raw) - 5,
        "size_bytes": len(raw),
        "sha256": hashlib.sha256(raw).hexdigest(),
    }


def _cosign_tool(profile_arg):
    """Resolve the operator-approved Cosign executable pin."""
    if profile_arg:
        tool = json.loads(Path(profile_arg).read_bytes())
    elif os.environ.get("ROBOTICS_COSIGN_PROFILE"):
        tool = json.loads(Path(os.environ["ROBOTICS_COSIGN_PROFILE"]).read_bytes())
    else:
        executable = shutil.which("cosign")
        if not executable:
            raise SystemExit(
                "real evaluator admission requires Cosign; provide --cosign-profile "
                "or ROBOTICS_COSIGN_PROFILE, or put cosign on PATH"
            )
        version = subprocess.run(
            [executable, "version", "--json"],
            capture_output=True,
            text=True,
            timeout=30,
            check=True,
        )
        tool = {
            "executable": executable,
            "executable_sha256": _sha256(executable),
            "version": json.loads(version.stdout)["gitVersion"],
        }
    executable = Path(tool["executable"])
    if _sha256(executable) != tool["executable_sha256"]:
        raise SystemExit("Cosign executable differs from its approved SHA-256 pin")
    return tool


def admit_evaluator(wheel, admission_dir, tool):
    """Cosign key-only admission: real wheel/receipt digests, ephemeral key."""
    if admission_dir.exists():
        shutil.rmtree(admission_dir)
    admission_dir.mkdir(parents=True, exist_ok=True)
    env = {
        "HOME": str(admission_dir),
        "XDG_CONFIG_HOME": str(admission_dir / "config"),
        "COSIGN_PASSWORD": "",
        "LC_ALL": "C.UTF-8",
        "PATH": os.environ.get("PATH", ""),
    }
    executable = tool["executable"]

    def cosign(*arguments):
        result = subprocess.run(
            [executable, *arguments],
            cwd=admission_dir,
            env=env,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            timeout=60,
            check=False,
        )
        if result.returncode:
            raise SystemExit(
                f"cosign {' '.join(arguments)} refused: {result.stderr.decode()}"
            )
        return result.stdout

    cosign("signing-config", "create", "--out", "signing.json")
    cosign("trusted-root", "create", "--out", "roots.json")
    cosign("generate-key-pair", "--output-key-prefix", "publisher")
    predicate = _dump(
        admission_dir / "predicate.json",
        {
            "scope": "recorded Nav2 document controls; no native performance claim",
        },
    )
    bundle = admission_dir / "wheel.sigstore.json"
    cosign(
        "attest-blob",
        "--yes",
        "--key",
        "publisher.key",
        "--signing-config",
        "signing.json",
        "--trusted-root",
        "roots.json",
        "--type",
        PREDICATE_TYPE,
        "--predicate",
        str(predicate),
        "--bundle",
        str(bundle),
        str(wheel),
    )
    (admission_dir / "publisher.key").unlink()
    key = admission_dir / "publisher.pub"
    policy = CosignKeyWheelPolicy(
        _sha256(wheel), PREDICATE_TYPE, _sha256(key), "key_only_no_tlog"
    )
    profile_values = {
        "profile_version": 1,
        "verifier": {
            "kind": "cosign_key_no_tlog",
            "executable": str(executable),
            "executable_sha256": tool["executable_sha256"],
            "version": tool["version"],
            "public_key": str(key),
            "public_key_sha256": _sha256(key),
            "trusted_root": str(admission_dir / "roots.json"),
            "trusted_root_sha256": _sha256(admission_dir / "roots.json"),
        },
        "evaluators": [
            {
                "namespace": NAMESPACE,
                "wheel": str(wheel),
                "bundle": str(bundle),
                "publisher": {
                    "wheel_sha256": policy.wheel_sha256,
                    "predicate_type": policy.predicate_type,
                    "public_key_sha256": policy.public_key_sha256,
                    "trust_mode": policy.trust_mode,
                },
            }
        ],
    }
    profile = _dump(admission_dir / "operator-profile.json", profile_values)
    profile.chmod(0o400)
    qualification = admission_dir / "qualification"
    binding = QUALIFY.qualify(profile, qualification, installed=True)
    return binding, qualification, profile


def _capture(
    prepared, manifest, case, overrides, *, unobserve_condition=False, omit_cdr=False
):
    """Bind the original recorded bytes; only custody state varies per case."""
    capture = prepared.parent / "capture"
    capture.mkdir()
    report = json.loads((FIXTURES / case / "workload.json").read_bytes())
    original_run_id = report["run_id"]
    report["parameters"]["readiness"] = _readiness()
    report["parameters"].update(overrides)
    report["run_id"] = manifest["run_id"]
    workload = _dump(capture / "workload.json", report)
    cdr_name = "get-result-response.cdr"
    cdr_raw = (FIXTURES / case / cdr_name).read_bytes()
    artifacts = [
        {
            "source": "workload.json",
            "artifact_id": "workload",
            "kind": "other_evidence",
            "media_type": "application/json",
        },
        {
            "source": "cleanup.json",
            "artifact_id": "cleanup",
            "kind": "other_evidence",
            "media_type": "application/json",
        },
    ]
    if not omit_cdr:
        (capture / cdr_name).write_bytes(cdr_raw)
        artifacts.insert(
            1,
            {
                "source": cdr_name,
                "artifact_id": "get-result-response",
                "kind": "other_evidence",
                "media_type": "application/octet-stream",
            },
        )
    cleanup = _dump(
        capture / "cleanup.json", {"remaining": [], "scope": "recorded Nav2 capture"}
    )
    started_at, finished_at = _recording_times(report)
    condition = {
        "state": "measured",
        "value": report["final_amcl_pose"],
        "evidence": _reference(workload),
    }
    if unobserve_condition:
        condition = {
            "state": "unobserved",
            "reason": "the postcondition observation was not retained in this custody copy",
        }
    facts = {
        "started_at": started_at,
        "finished_at": finished_at,
        "observations": {
            "command": {
                "state": "measured",
                "value": report["goal_accepted"],
                "evidence": _reference(workload),
            },
            "terminal": {
                "state": "measured",
                "value": report["action_status"],
                "evidence": _reference(workload),
            },
            "condition": condition,
            "cleanup": {
                "state": "measured",
                "value": [],
                "evidence": _reference(cleanup),
            },
        },
        "artifacts": artifacts,
        "policy_observation": {
            "recording_mode": "native-files",
            "compression": "none",
            "retention_class": "test-evidence",
            "upload_mode": "local_only",
            "remote_sink_used": False,
            "spool_peak_size_bytes": 1024 * 1024,
            "upload_lag_max_sec": 0,
        },
    }
    _dump(capture / "completed-facts.json", facts)
    return capture, report, workload, original_run_id, cdr_raw


def _validate_cli(prepared):
    contracts = Path(sys.executable).parent / "robotics-contracts"
    subprocess.run(
        [
            str(contracts),
            "validate",
            "--extension-schema",
            f"{SCHEMA_URI}={prepared / 'nav2.schema.json'}",
            str(prepared / "scenario.json"),
        ],
        check=True,
        capture_output=True,
        text=True,
        timeout=60,
    )


def _evaluate_cli(inputs, prepared, output, qualification, profile):
    cli = Path(sys.executable).parent / "robotics-acceptance"
    arguments = [str(cli), "evaluate"]
    for key, value in inputs.items():
        arguments += ["--" + key.replace("_", "-"), str(value)]
    arguments += [
        "--window-start-ns",
        "0",
        "--window-end-ns",
        "1",
        "--extension-schema",
        f"{SCHEMA_URI}={prepared / 'nav2.schema.json'}",
        "--output",
        str(output),
        "--evaluator-receipt",
        str(qualification / "receipt.json"),
        "--evaluator-verification",
        str(qualification / "verification.json"),
    ]
    for name in ("statement.json", "publisher.json", "verified-report.txt"):
        arguments += ["--evaluator-receipt-dependency", str(qualification / name)]
    arguments += ["--evaluator-trust-profile", str(profile)]
    environment = os.environ.copy()
    environment.pop("PYTHONPATH", None)
    environment.pop("PYTHONHOME", None)
    return subprocess.run(
        arguments,
        env=environment,
        stdin=subprocess.DEVNULL,
        capture_output=True,
        text=True,
        timeout=120,
        check=False,
    )


def assess_case(
    label,
    case,
    overrides,
    root,
    *,
    binding,
    qualification,
    profile,
    unobserve_condition=False,
    omit_cdr=False,
    tamper=None,
):
    root = Path(root)
    if root.exists():
        shutil.rmtree(root)
    root.mkdir(parents=True, exist_ok=True)
    report = json.loads((FIXTURES / case / "workload.json").read_bytes())
    report["parameters"]["readiness"] = _readiness()
    report["parameters"].update(overrides)
    profile_path = _dump(root / "profile.json", _profile())
    requirements = _dump(
        root / "requirements.json",
        {
            "case": case,
            "configuration": {**report["parameters"], "case": case},
            "evaluator_requirement": binding,
        },
    )
    prepared = root / "archive" / "inputs"
    manifest = PREPARE.prepare(
        profile_path, requirements, prepared, run_id=RUN_IDS[label]
    )
    _validate_cli(prepared)
    capture, cap_report, workload, original_run_id, cdr_raw = _capture(
        prepared,
        manifest,
        case,
        overrides,
        unobserve_condition=unobserve_condition,
        omit_cdr=omit_cdr,
    )
    inputs = FINALIZE.complete(prepared, capture)
    if tamper:
        target = capture / tamper["artifact"]
        raw = bytearray(target.read_bytes())
        if tamper["mode"] == "truncate":
            del raw[tamper.get("keep", 5) :]
        else:
            raw[tamper.get("offset", 0)] ^= 0xFF
        target.write_bytes(bytes(raw))
    output = root / "assessment"
    completed = _evaluate_cli(inputs, prepared, output, qualification, profile)
    result_path = output / "acceptance-result.json"
    entry = {
        "label": label,
        "case": case,
        "run_id": manifest["run_id"],
        "original_recording_run_id": original_run_id,
        "overrides": overrides,
        "cli_returncode": completed.returncode,
        "scenario_sha256": manifest["scenario"]["sha256"],
        "workload_sha256": _sha256(workload),
        "capture_sha256": _sha256(capture / "completed-facts.json"),
        "cdr": decode_cdr(cdr_raw) if not omit_cdr else None,
        "recording_started_at": _recording_times(cap_report)[0],
        "recording_finished_at": _recording_times(cap_report)[1],
        "final_amcl_pose": cap_report["final_amcl_pose"],
        "final_odometry": cap_report["final_odometry"],
        "goal": cap_report["parameters"]["goal"],
        "max_final_pose_error_m": cap_report["parameters"]["max_final_pose_error_m"],
        "action_status": cap_report["action_status"],
        "observation_status": cap_report["observation_status"],
    }
    goal = cap_report["parameters"]["goal"]
    final = cap_report["final_amcl_pose"]
    entry["pose_error_m"] = (
        (final["x"] - goal["x"]) ** 2 + (final["y"] - goal["y"]) ** 2
    ) ** 0.5
    if result_path.exists():
        result = json.loads(result_path.read_bytes())
        entry["verdict"] = result["status"]
        entry["unevaluated"] = result.get("unevaluated", [])
        entry["coverage"] = result.get("evaluation", {}).get("coverage", {})
        entry["assertions"] = result.get("assertion_results", [])
        entry["observations"] = result.get("observations", {})
        entry["result_json"] = str(result_path)
        entry["junit_xml"] = str(output / "junit.xml")
        entry["evidence_valid"] = True
    else:
        entry["verdict"] = "error"
        entry["evidence_valid"] = False
        refusal = (completed.stderr or completed.stdout).strip().splitlines()
        entry["refusal"] = refusal[-1] if refusal else ""
        entry["assertions"] = []
        entry["unevaluated"] = []
        entry["coverage"] = {}
    return entry


def _decisive(entry):
    for item in entry.get("assertions", []):
        if item["assertion_id"].endswith(".action-" + entry["case"]):
            return item
    return None


def _scope(entry):
    coverage = entry.get("coverage", {})
    covered = [c["assertion_id"] for c in coverage.get("covered_assertions", [])]
    uncovered = [c["assertion_id"] for c in coverage.get("uncovered_assertions", [])]
    return covered, uncovered


def build_report(cases, versions):
    base = cases["baseline"]
    lines = []
    add = lines.append
    add("=" * 72)
    add("Nav2 qualification demo - verdict report")
    add("=" * 72)
    add("")
    add("One recorded NavigateToPose success, assessed through the published")
    add(
        f"acceptance SDK (harness {versions['robotics-acceptance-harness']['version']} / "
        f"contracts {versions['robotics-runtime-contracts']['version']}) and the native"
    )
    add(
        f"Nav2 evaluator {versions['nav2-turtlebot3-evaluator']['version']} via the public"
    )
    add("robotics-acceptance evaluate path with Cosign key-only admission.")
    add("")
    add(f"Recorded final-pose error : {base['pose_error_m']:.4f} m")
    add(f"NavigateToPose action     : status={base['action_status']} (SUCCEEDED)")
    add(
        f"GetResult CDR             : {base['cdr']['encapsulation']}, "
        f"status int8={base['cdr']['status_int8']} ({base['cdr']['status_name']}), "
        f"result payload {base['cdr']['result_payload_bytes']} bytes"
    )
    add(
        f"Recording window (UTC)    : {base['recording_started_at']} .. {base['recording_finished_at']}"
    )
    add(
        f"Final AMCL frame          : {base['final_amcl_pose']['frame_id']} "
        f"(x={base['final_amcl_pose']['x']:.4f}, y={base['final_amcl_pose']['y']:.4f})"
    )
    add("")
    add("-" * 72)
    add("CASE VERDICTS (all actions SUCCEEDED; only baseline passes)")
    add("-" * 72)
    order = [
        "baseline",
        "criterion-sensitivity",
        "insufficient-observation",
        "evidence-refusal",
        "missing-coverage",
    ]
    for label in order:
        entry = cases[label]
        add(f"  {label:26s} {entry['verdict'].upper()}")
    add("")
    for label in order:
        entry = cases[label]
        add("-" * 72)
        add(label.upper())
        add("-" * 72)
        decisive = _decisive(entry)
        if label == "baseline":
            add(
                f"  criterion max_final_pose_error_m : {entry['max_final_pose_error_m']} m"
            )
            add(f"  measured pose error              : {entry['pose_error_m']:.4f} m")
            add(
                f"  decisive assertion               : {decisive['assertion_id'] if decisive else 'n/a'}"
                f" -> {decisive['status'] if decisive else 'n/a'}"
            )
        elif label == "criterion-sensitivity":
            add(
                f"  criterion max_final_pose_error_m : {base['max_final_pose_error_m']} m -> {entry['max_final_pose_error_m']} m"
            )
            add(
                f"  measured pose error              : {entry['pose_error_m']:.4f} m (unchanged capture)"
            )
            add(
                f"  decisive assertion               : {decisive['assertion_id'] if decisive else 'n/a'}"
                f" -> {decisive['status'] if decisive else 'n/a'}"
            )
            if decisive and decisive.get("message"):
                add(f"  reason                           : {decisive['message']}")
            add(
                "  label                            : criterion sensitivity (acceptance tolerance"
            )
            add(
                "                                     changed; robot config and capture unchanged)"
            )
        elif label == "insufficient-observation":
            add(
                "  custody                          : postcondition observation not retained"
            )
            add(
                f"  unevaluated                      : {', '.join(entry['unevaluated']) or 'none'}"
            )
            add(
                "  outcome                          : required observation unevaluated -> not pass"
            )
        elif label == "evidence-refusal":
            add(
                "  custody                          : tampered evidence copy (truncated GetResult CDR)"
            )
            add(f"  evidence valid                   : {entry['evidence_valid']}")
            add(f"  refusal                          : {entry.get('refusal', '')}")
            add(
                "  outcome                          : verification refused -> ERROR (not robot FAILED)"
            )
        elif label == "missing-coverage":
            covered, uncovered = _scope(entry)
            add(
                "  custody                          : required original GetResult coverage omitted"
            )
            add(
                f"  uncovered assertions             : {', '.join(uncovered) or 'none'}"
            )
            add(
                f"  unevaluated                      : {', '.join(entry['unevaluated']) or 'none'}"
            )
            add(
                "  outcome                          : required coverage missing -> INCOMPLETE"
            )
        add(f"  verdict                          : {entry['verdict'].upper()}")
        add("")
    add("-" * 72)
    add("SCOPE")
    add("-" * 72)
    covered, uncovered = _scope(base)
    add("  required observations : command, terminal, condition, cleanup")
    add(f"  baseline covered      : {', '.join(covered) or 'none'}")
    add(f"  outside scope         : {', '.join(OUTSIDE_SCOPE)} (not selected)")
    add("  headline live A/B     : separate live command; not claimed by this demo")
    add("")
    add("-" * 72)
    add("VERDICT TAXONOMY (kept separate)")
    add("-" * 72)
    add("  passed     - every required assertion matched the captured facts.")
    add("  failed     - observations complete, a physical postcondition violated.")
    add("  error      - evidence custody refused or required native data malformed.")
    add("  incomplete - required observation/coverage unevaluated; cannot pass.")
    add("")
    add("Boundaries: recorded capture, not live physics; Cosign key-only admission")
    add("(no OIDC identity/transparency/build provenance); verdict covers the")
    add("configured action outcome and fresh odom/TF/AMCL pose facts only.")
    add(
        "Provenance (digests, pins, dates): work/results.json and work/provenance.json."
    )
    add("=" * 72)
    return "\n".join(lines)


def write_qualification_junit(cases, path):
    """Synthetic qualification-verdict gate: fails for any non-passed verdict."""
    suite = ET.Element("testsuite", name="nav2-qualification", tests=str(len(cases)))
    failures = 0
    for label, entry in cases.items():
        verdict = entry["verdict"]
        case = ET.SubElement(
            suite,
            "testcase",
            name="qualification-verdict",
            classname=f"nav2.qualification.{label}",
        )
        if verdict != "passed":
            failures += 1
            ET.SubElement(
                case, "failure", message=f"robot qualification {verdict} for {label}"
            ).text = f"verdict={verdict}; action SUCCEEDED cannot override the qualification verdict"
    suite.set("failures", str(failures))
    ET.ElementTree(suite).write(path, encoding="utf-8", xml_declaration=True)


def _git_commit():
    try:
        return subprocess.run(
            ["git", "rev-parse", "HEAD"],
            cwd=DEMO,
            capture_output=True,
            text=True,
            timeout=15,
            check=True,
        ).stdout.strip()
    except Exception:
        return "unknown"


def _release_image():
    env = DEMO / "work" / "release.env"
    if not env.exists():
        return None
    for line in env.read_text().splitlines():
        if line.startswith("SIMULATION_IMAGE="):
            return line.split("=", 1)[1].strip()
    return None


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=DEMO / "work")
    parser.add_argument("--output", type=Path, default=DEMO / "work" / "results.json")
    parser.add_argument("--report", type=Path, default=DEMO / "work" / "report.txt")
    parser.add_argument("--cosign-profile", type=Path, default=None)
    parser.add_argument("--wheel", type=Path, default=None)
    parser.add_argument("--sensitivity-tolerance", type=float, default=0.10)
    args = parser.parse_args(argv)
    args.work_dir.mkdir(parents=True, exist_ok=True)
    versions = sdk_versions()
    wheel = args.wheel or next(
        (DEMO / "dist").glob("nav2_turtlebot3_evaluator-*-py3-none-any.whl")
    )
    tool = _cosign_tool(args.cosign_profile)
    binding, qualification, profile = admit_evaluator(
        wheel, args.work_dir / "admission", tool
    )

    cases = {}
    cases["baseline"] = assess_case(
        "baseline",
        "success",
        {},
        args.work_dir / "run" / "baseline",
        binding=binding,
        qualification=qualification,
        profile=profile,
    )
    cases["criterion-sensitivity"] = assess_case(
        "criterion-sensitivity",
        "success",
        {"max_final_pose_error_m": args.sensitivity_tolerance},
        args.work_dir / "run" / "criterion-sensitivity",
        binding=binding,
        qualification=qualification,
        profile=profile,
    )
    cases["insufficient-observation"] = assess_case(
        "insufficient-observation",
        "success",
        {},
        args.work_dir / "run" / "insufficient-observation",
        binding=binding,
        qualification=qualification,
        profile=profile,
        unobserve_condition=True,
    )
    cases["evidence-refusal"] = assess_case(
        "evidence-refusal",
        "success",
        {},
        args.work_dir / "run" / "evidence-refusal",
        binding=binding,
        qualification=qualification,
        profile=profile,
        tamper={"artifact": "get-result-response.cdr", "mode": "truncate", "keep": 5},
    )
    cases["missing-coverage"] = assess_case(
        "missing-coverage",
        "success",
        {},
        args.work_dir / "run" / "missing-coverage",
        binding=binding,
        qualification=qualification,
        profile=profile,
        omit_cdr=True,
    )

    provenance = {
        "release_tag": os.environ.get("NAV2_DEMO_RELEASE_TAG", "v0.11.0-rc2"),
        "commit": _git_commit(),
        "python_version": sys.version.split()[0],
        "simulation_image": _release_image(),
        "sdk": versions,
        "evaluator_wheel_sha256": binding["artifact_sha256"],
        "evaluator_receipt_sha256": binding["receipt_sha256"],
        "evaluator_binding": binding,
        "cosign": {
            "version": tool["version"],
            "executable_sha256": tool["executable_sha256"],
        },
        "capture_sha256": {
            label: entry["capture_sha256"] for label, entry in cases.items()
        },
        "workload_sha256": {
            label: entry["workload_sha256"] for label, entry in cases.items()
        },
        "scenario_sha256": {
            label: entry["scenario_sha256"] for label, entry in cases.items()
        },
        "original_recording_run_id": cases["baseline"]["original_recording_run_id"],
        "recording_started_at": cases["baseline"]["recording_started_at"],
        "recording_finished_at": cases["baseline"]["recording_finished_at"],
        "outside_scope": OUTSIDE_SCOPE,
    }
    results = {"cases": cases, "provenance": provenance}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    (args.work_dir / "provenance.json").write_text(
        json.dumps(provenance, indent=2, sort_keys=True) + "\n"
    )
    write_qualification_junit(cases, args.work_dir / "qualification-junit.xml")
    report = build_report(cases, versions)
    args.report.write_text(report + "\n")
    print(report)

    expected = {
        "baseline": "passed",
        "criterion-sensitivity": "failed",
        "insufficient-observation": "incomplete",
        "evidence-refusal": "error",
        "missing-coverage": "incomplete",
    }
    mismatch = {
        k: (cases[k]["verdict"], v)
        for k, v in expected.items()
        if cases[k]["verdict"] != v
    }
    if mismatch:
        print(f"\nDEMO ERROR: verdict mismatch {mismatch}", file=sys.stderr)
        return 1
    print(
        "\nQualification demonstrated: baseline=passed; criterion-sensitivity=failed;"
    )
    print(
        "insufficient-observation=incomplete; evidence-refusal=error; missing-coverage=incomplete."
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
