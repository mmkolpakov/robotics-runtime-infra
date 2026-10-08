"""Check this caller's retained native observations after public bundle verification."""

import argparse
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile

from robotics_runtime_contracts import load_mapping

PUBLIC_ROUTING_FIELDS = {
    "ROS_DOMAIN_ID",
    "RMW_IMPLEMENTATION",
    "ROBOTICS_RUN_ID",
    "ROBOTICS_DOMAIN_ID",
}


def verify(package, caller, ros_domain):
    lines = (package / "qualification-arguments.txt").read_text().splitlines()
    assert len(lines) % 2 == 0
    subjects = {}
    schemas = {}
    for flag, value in zip(lines[::2], lines[1::2], strict=True):
        key, relative = value.split("=", 1)
        path = (package / relative).resolve(strict=True)
        assert path.is_relative_to(package)
        target = subjects if flag == "--artifact" else schemas
        assert flag in {"--artifact", "--extension-schema"} and key not in target
        target[key] = path
    scenario = subjects["scenario:scenario.json"]
    run = json.loads(subjects["acceptance_run:acceptance-run.json"].read_text())
    result = json.loads(subjects["domain_result:results/primary.json"].read_text())
    aggregate = json.loads(
        subjects["acceptance_aggregate:acceptance-aggregate.json"].read_text()
    )
    assert result["status"] == "passed" and result["evaluation_mode"] == "live"
    assert aggregate["per_domain_aggregate"] == "passed"
    original = caller / "inputs/opaque.bin"
    payload = subjects["other_evidence:consumer/opaque.bin"].read_bytes()
    assert payload == original.read_bytes()
    uri = "https://example.org/robotics/generic-consumer.schema.json"
    assert (
        schemas[uri].read_bytes()
        == (caller / "inputs/extension.schema.json").read_bytes()
    )
    admission = []
    with tempfile.TemporaryDirectory(prefix="generic-caller-admission-") as temporary:
        target = Path(temporary)
        cli = [sys.executable, "-I", "-m", "robotics_acceptance_harness.cli"]
        common_aggregate = [
            "--run-context",
            str(subjects["acceptance_run:acceptance-run.json"]),
            "--result",
            str(subjects["domain_result:results/primary.json"]),
        ]
        positive = subprocess.run(
            cli
            + ["aggregate", "--scenario", str(scenario)]
            + common_aggregate
            + [
                "--extension-schema",
                uri + "=" + str(schemas[uri]),
                "--output",
                str(target / "aggregate.json"),
            ],
            capture_output=True,
            text=True,
            timeout=20,
            check=True,
        )
        replay = json.loads((target / "aggregate.json").read_text())
        assert replay["per_domain_aggregate"] == "passed"
        admission.append(
            {
                "operation": "aggregate",
                "case": "original-registry",
                "exit": positive.returncode,
            }
        )
        for case, message in (
            ("missing-registry", "schema document was not supplied"),
            ("wrong-digest", "schema digest does not match"),
            ("wrong-payload", "generic-caller-v1"),
        ):
            selected = scenario
            registry = []
            if case != "missing-registry":
                document = dict(load_mapping(scenario))
                if case == "wrong-digest":
                    document["extension_schemas"][0]["sha256"] = "0" * 64
                else:
                    document["extensions"]["org.example.generic-consumer.probe"][
                        "marker"
                    ] = "wrong"
                selected = target / (case + ".json")
                selected.write_text(json.dumps(document))
                registry = ["--extension-schema", uri + "=" + str(schemas[uri])]
            for operation in ("aggregate", "verify"):
                output = target / (case + "-" + operation)
                marker = target / (case + "-measurement-complete")
                if operation == "aggregate":
                    arguments = common_aggregate + ["--output", str(output)]
                else:
                    arguments = [
                        "--runtime",
                        str(
                            subjects["runtime_manifest:runtime-manifests/primary.json"]
                        ),
                        "--run-context",
                        str(subjects["acceptance_run:acceptance-run.json"]),
                        "--run-id",
                        run["run_id"],
                        "--domain-id",
                        "primary",
                        "--evidence-index",
                        str(subjects["evidence_index:evidence-indexes/primary.json"]),
                        "--otel-metrics",
                        str(subjects["metrics:evidence/metrics.otlp.jsonl"]),
                        "--measurement-complete",
                        str(marker),
                        "--output",
                        str(output),
                    ]
                refused = subprocess.run(
                    cli
                    + [operation, "--scenario", str(selected)]
                    + registry
                    + arguments,
                    capture_output=True,
                    text=True,
                    timeout=20,
                )
                diagnostic = refused.stdout + refused.stderr
                assert refused.returncode != 0 and message in diagnostic
                assert not output.exists() and not marker.exists()
                admission.append(
                    {
                        "operation": operation,
                        "case": case,
                        "exit": refused.returncode,
                        "diagnostic": diagnostic[:8192],
                    }
                )
    roots = [
        key.removeprefix("other_evidence:").removesuffix("/before.json")
        for key in subjects
        if key.startswith("other_evidence:consumer/settlement/caller-probe/")
        and key.endswith("/before.json")
    ]
    assert len(roots) == 1
    root = roots[0]
    cid = root.rsplit("/", 1)[1]
    assert re.fullmatch("[0-9a-f]{64}", cid)

    def read(name):
        return subjects["other_evidence:" + root + "/" + name].read_text()

    before, after = json.loads(read("before.json")), json.loads(read("after.json"))
    assert before["container_id"] == after["container_id"] == cid
    assert (
        before["project"] == after["project"]
        and before["service"] == after["service"] == "caller-probe"
    )
    assert re.fullmatch("sha256:[0-9a-f]{64}", before["image_id"])
    assert before["image_id"] == after["image_id"]
    assert before["state"]["running"] and before["state"]["pid"] > 0
    assert not after["state"]["running"] and after["state"]["pid"] == 0
    assert after["state"]["exit_code"] == 0 and not after["state"]["oom_killed"]
    assert before["restart_count"] == after["restart_count"] == 0
    routing = dict(value.split("=", 1) for value in before["environment"])
    assert (
        set(routing) == PUBLIC_ROUTING_FIELDS
        and after["environment"] == before["environment"]
    )
    assert routing["ROS_DOMAIN_ID"] == str(ros_domain)
    assert (
        routing["ROBOTICS_RUN_ID"] == run["run_id"]
        and routing["ROBOTICS_DOMAIN_ID"] == "primary"
    )
    assert routing["RMW_IMPLEMENTATION"] == "rmw_fastrtps_cpp"
    for name in (
        "native-wait.stdout",
        "native-wait.status",
        "native-inspect.status",
        "logs-before.status",
        "logs-after.status",
    ):
        assert read(name).strip() == "0"
    assert (
        subjects["other_evidence:consumer/settlement/native-stop.status"]
        .read_text()
        .strip()
        == "0"
    )
    assert re.fullmatch(
        "[0-9a-f]{64}\\n",
        subjects["other_evidence:consumer/settlement/endpoint.sha256"].read_text(),
    )
    events = []
    for line in read("logs-after.txt").splitlines():
        events.append(json.loads(line.split(" ", 1)[1]))
    ready = [event for event in events if event["phase"] == "ready"]
    terminal = [event for event in events if event["phase"] == "terminated"]
    assert len(ready) == len(terminal) == 1
    assert ready[0]["routing"] == routing
    assert ready[0]["input_sha256"] == hashlib.sha256(payload).hexdigest()
    assert ready[0]["input_size"] == len(payload)
    assert terminal[0]["signal"] == "SIGTERM"
    return {
        "container_id": cid,
        "image_id": before["image_id"],
        "project": before["project"],
        "run_id": run["run_id"],
        "ros_domain_id": ros_domain,
        "input_sha256": hashlib.sha256(payload).hexdigest(),
        "input_size": len(payload),
        "extension_admission": admission,
        "native_exit": 0,
        "signal": "SIGTERM",
        "scenario_path": str(scenario),
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("package", type=Path)
    parser.add_argument("--caller", type=Path, default=Path(__file__).parent)
    parser.add_argument("--ros-domain", type=int, required=True)
    args = parser.parse_args()
    print(
        json.dumps(
            verify(
                args.package.resolve(strict=True),
                args.caller.resolve(strict=True),
                args.ros_domain,
            ),
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
