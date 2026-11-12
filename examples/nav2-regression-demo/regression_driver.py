#!/usr/bin/env python3
"""Assess one recorded Nav2 run against two acceptance parameter sets.

The physical capture is a recorded NavigateToPose success (real odom/TF/AMCL
facts and the original GetResult CDR). It is assessed twice through the
published acceptance SDK and the native Nav2 evaluator: once with the baseline
acceptance parameters and once with a broken-commit parameter change. Only the
declared acceptance criterion differs between the two runs; no physical fact is
synthesized. Preparation issues real acceptance-scenario.v2 documents through
the installed ``robotics-acceptance explain`` and ``create-run`` entry points,
and each scenario is validated with ``robotics-contracts validate``.
"""

from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import math
import shutil
import subprocess
import sys
from datetime import UTC, datetime
from pathlib import Path

from nav2_turtlebot3_evaluator import NAMESPACE, evaluate
from robotics_acceptance_harness import EvaluationContext
from robotics_acceptance_harness.documents import DocumentBundle, load_document
from robotics_acceptance_harness.evidence import load_evidence_index
from robotics_runtime_contracts import worst_status

DEMO = Path(__file__).resolve().parent
EXAMPLE = DEMO.parent / "nav2-turtlebot3"
FIXTURES = EXAMPLE / "evaluator" / "tests" / "fixtures"
READINESS_CONTROL = EXAMPLE / "evaluator" / "tests" / "readiness-control.json"
SCHEMA_URI = "urn:nav2-turtlebot3:scenario:v1"


def _module(name):
    spec = importlib.util.spec_from_file_location(
        name.replace("-", "_"), EXAMPLE / (name + ".py")
    )
    value = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(value)
    return value


PREPARE = _module("make-scenario")
FINALIZE = _module("finalize")


def _dump(path, value):
    path.write_text(json.dumps(value))
    return path


def _reference(path):
    raw = path.read_bytes()
    return {
        "uri": path.resolve().as_uri(),
        "sha256": hashlib.sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "media_type": "application/json",
    }


def _readiness():
    return json.loads(READINESS_CONTROL.read_bytes())


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


def _binding():
    return {
        "namespace": NAMESPACE,
        "entry_point": "nav2_turtlebot3_evaluator:evaluate",
        "distribution": "nav2-turtlebot3-evaluator",
        "version": "0.3.0",
        "artifact_sha256": "a" * 64,
        "receipt_sha256": "b" * 64,
    }


def _capture(prepared, manifest, case, overrides):
    capture = prepared.parent / "capture"
    capture.mkdir()
    report = json.loads((FIXTURES / case / "workload.json").read_bytes())
    report["parameters"]["readiness"] = _readiness()
    report["parameters"].update(overrides)
    report["run_id"] = manifest["run_id"]
    workload = _dump(capture / "workload.json", report)
    cdr = capture / "get-result-response.cdr"
    cdr.write_bytes((FIXTURES / case / cdr.name).read_bytes())
    cleanup = _dump(
        capture / "cleanup.json", {"remaining": [], "scope": "recorded Nav2 capture"}
    )
    now = datetime.now(UTC).isoformat()
    facts = {
        "started_at": now,
        "finished_at": now,
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
            "condition": {
                "state": "measured",
                "value": report["final_amcl_pose"],
                "evidence": _reference(workload),
            },
            "cleanup": {
                "state": "measured",
                "value": [],
                "evidence": _reference(cleanup),
            },
        },
        "artifacts": [
            {
                "source": "workload.json",
                "artifact_id": "workload",
                "kind": "other_evidence",
                "media_type": "application/json",
            },
            {
                "source": cdr.name,
                "artifact_id": "get-result-response",
                "kind": "other_evidence",
                "media_type": "application/octet-stream",
            },
            {
                "source": cleanup.name,
                "artifact_id": "cleanup",
                "kind": "other_evidence",
                "media_type": "application/json",
            },
        ],
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
    return capture, report, workload


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


def assess(label, case, overrides, root, run_id, *, validate_cli=True):
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
            "evaluator_requirement": _binding(),
        },
    )
    prepared = root / "archive" / "inputs"
    manifest = PREPARE.prepare(profile_path, requirements, prepared, run_id=run_id)
    if validate_cli:
        _validate_cli(prepared)
    capture, cap_report, workload = _capture(prepared, manifest, case, overrides)
    result = FINALIZE.complete(prepared, capture)
    scenario = load_document(
        prepared / "scenario.json",
        expected_role="acceptance_scenario",
        extension_schemas={SCHEMA_URI: (prepared / "nav2.schema.json").read_bytes()},
    )
    runtime = load_document(prepared / "runtime.json", expected_role="runtime_manifest")
    evidence = load_evidence_index(
        result["evidence_index"], expected_run_id=manifest["run_id"]
    )
    context = EvaluationContext(
        manifest["run_id"],
        "nav2",
        DocumentBundle(scenario, runtime),
        evidence,
        (),
        0,
        1,
    )
    assertions = list(evaluate(context))
    statuses = [
        "incomplete" if item.status == "skipped" else item.status for item in assertions
    ]
    verdict = worst_status(statuses)
    goal = cap_report["parameters"]["goal"]
    final = cap_report["final_amcl_pose"]
    pose_error = math.hypot(final["x"] - goal["x"], final["y"] - goal["y"])
    return {
        "label": label,
        "case": case,
        "verdict": verdict,
        "assertions": [
            {
                "id": item.assertion_id,
                "status": item.status,
                "observed_value": item.observed_value,
                "message": item.message,
                "evidence_sha256": list(item.evidence_sha256),
            }
            for item in assertions
        ],
        "parameters": cap_report["parameters"],
        "overrides": overrides,
        "pose_error_m": pose_error,
        "action_status": cap_report.get("action_status"),
        "observation_status": cap_report.get("observation_status"),
        "run_id": manifest["run_id"],
        "scenario_sha256": manifest["scenario"]["sha256"],
        "workload_sha256": _reference(workload)["sha256"],
        "prepared": str(prepared),
    }


def _report(baseline, broken, tolerance):
    base_tol = baseline["parameters"]["max_final_pose_error_m"]
    lines = []
    add = lines.append
    add("=" * 72)
    add("Nav2 acceptance regression demo - verdict report")
    add("=" * 72)
    add("")
    add("One recorded NavigateToPose success run, assessed twice through the")
    add("published acceptance SDK (harness 0.23.1 / contracts 0.22.0) and the")
    add("native Nav2 evaluator 0.3.0. The physical capture is identical and")
    add("unmodified; only the declared acceptance tolerance differs.")
    add("")
    add(f"Recorded final-pose error : {baseline['pose_error_m']:.4f} m")
    add(f"NavigateToPose action     : status={baseline['action_status']} (SUCCEEDED)")
    add(f"Observation status        : {baseline['observation_status']}")
    add("")
    add("-" * 72)
    add("BASELINE (accepted parameters)")
    add("-" * 72)
    add(f"  max_final_pose_error_m  : {base_tol} m")
    add(f"  verdict                 : {baseline['verdict'].upper()}")
    for item in baseline["assertions"]:
        add(f"    - {item['id'].split('.')[-1]:22s} {item['status']}")
    add("")
    add("-" * 72)
    add("BROKEN COMMIT (tightened arrival tolerance)")
    add("-" * 72)
    add(f"  max_final_pose_error_m  : {base_tol} m -> {tolerance} m")
    add(f"  verdict                 : {broken['verdict'].upper()}")
    for item in broken["assertions"]:
        add(f"    - {item['id'].split('.')[-1]:22s} {item['status']}")
    add("")
    add("-" * 72)
    add("WHAT CHANGED - THE REGRESSION A GREEN CI HIDES")
    add("-" * 72)
    add(f"  The broken commit tightens the arrival tolerance from {base_tol} m to")
    add(f"  {tolerance} m. The robot still reports NavigateToPose SUCCEEDED, so a")
    add("  CI gate that only checks the action result stays GREEN. The acceptance")
    add(
        f"  verdict flips to {broken['verdict'].upper()} because the recorded final-pose"
    )
    add(
        f"  error ({baseline['pose_error_m']:.4f} m) now exceeds the declared tolerance"
    )
    add(f"  ({tolerance} m). Action success cannot override a violated physical")
    add("  postcondition.")
    add("")
    add("  Evidence (original bytes, SHA-256):")
    add(f"    baseline scenario : {baseline['scenario_sha256']}")
    add(f"    broken   scenario : {broken['scenario_sha256']}")
    add(f"    recorded workload : {baseline['workload_sha256']}")
    for item in broken["assertions"]:
        if item["status"] == "failed":
            add(f"    failed assertion  : {item['id']}")
            add(f"      reason          : {item['message']}")
            for digest in item["evidence_sha256"]:
                add(f"      bound evidence  : {digest}")
    add("")
    add("-" * 72)
    add("VERDICT TAXONOMY (kept separate)")
    add("-" * 72)
    add("  passed     - every required assertion matched the captured facts.")
    add("  failed     - observations complete, a physical postcondition violated.")
    add("  error      - required native observations missing or malformed.")
    add("  incomplete - observation did not settle / required coverage skipped.")
    add(f"  This demo: baseline={baseline['verdict']}, broken={broken['verdict']}.")
    add("")
    add("-" * 72)
    add("BOUNDARIES (honest)")
    add("-" * 72)
    add("  * The Nav2 evidence is a recorded capture, not a fresh live Gazebo run.")
    add("  * Evaluator admission uses document-control bindings; cosign-admitted")
    add("    native launch and live physics are the gated next step (see README).")
    add("  * The verdict engine, evidence binding, document issuance and the")
    add("    explain/validate/create-run CLI calls are the real published SDK.")
    add("=" * 72)
    return "\n".join(lines)


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--work-dir", type=Path, default=DEMO / "work")
    parser.add_argument("--output", type=Path, default=DEMO / "work" / "results.json")
    parser.add_argument("--report", type=Path, default=DEMO / "work" / "report.txt")
    parser.add_argument("--broken-tolerance", type=float, default=0.10)
    parser.add_argument("--skip-validate", action="store_true")
    args = parser.parse_args(argv)
    args.work_dir.mkdir(parents=True, exist_ok=True)
    validate_cli = not args.skip_validate
    baseline = assess(
        "baseline",
        "success",
        {},
        args.work_dir / "baseline",
        "run-11111111-2222-4333-8444-555555555555",
        validate_cli=validate_cli,
    )
    broken = assess(
        "broken-commit",
        "success",
        {"max_final_pose_error_m": args.broken_tolerance},
        args.work_dir / "broken",
        "run-22222222-3333-4444-8555-666666666666",
        validate_cli=validate_cli,
    )
    results = {"baseline": baseline, "broken": broken}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(results, indent=2, sort_keys=True) + "\n")
    report = _report(baseline, broken, args.broken_tolerance)
    args.report.write_text(report + "\n")
    print(report)
    demonstrated = baseline["verdict"] == "passed" and broken["verdict"] == "failed"
    if not demonstrated:
        print(
            "\nDEMO ERROR: expected baseline=passed and broken=failed, got "
            f"baseline={baseline['verdict']} broken={broken['verdict']}",
            file=sys.stderr,
        )
        return 1
    print("\nRegression demonstrated: baseline=passed, broken=failed.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
