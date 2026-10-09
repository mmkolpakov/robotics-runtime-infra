"""Create public retained input documents and run the offline acceptance CLI."""

import argparse
import hashlib
import json
import platform
import re
import subprocess
from datetime import datetime, timezone
from pathlib import Path

from robotics_runtime_contracts import load_mapping, validate_document
from robotics_runtime_contracts.serialization import read_document_bytes
from robotics_runtime_contracts.writers import (
    add_evidence_artifact,
    create_evidence_index,
    finalize_evidence_index,
    write_document,
)

PUBLIC_REVISION = "b241633181f030b23ce0639e83277a7d37b8e7ef"
MCAP_HEADER_SHA = "5d4fa57f5b3931e50faf7832fe7dae7913715c7a42df158ef5d8acec7734cd5e"


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def reference(path):
    return {
        "uri": path.resolve().as_uri(),
        "sha256": digest(path),
        "size_bytes": path.stat().st_size,
    }


def command(argv, output):
    result = subprocess.run(argv, capture_output=True, timeout=45, check=False)
    output.with_suffix(".stdout").write_bytes(result.stdout)
    output.with_suffix(".stderr").write_bytes(result.stderr)
    output.with_suffix(".exit").write_text(str(result.returncode) + "\n")
    return result


def finalize(
    capture, output, qualification, source_revision, contracts, harness, python
):
    if not re.fullmatch(r"[a-f0-9]{40}", source_revision):
        raise ValueError("exact committed source revision required")
    context = load_mapping(capture / "run-context.json")
    scenario = load_mapping(capture / "scenario.json")
    registry = {
        "urn:nav2-turtlebot3:scenario:v1": (capture / "nav2.schema.json").read_bytes()
    }
    validate_document(context, extension_schemas=registry)
    validate_document(scenario, extension_schemas=registry)
    if context["scenario_sha256"] != digest(capture / "scenario.json"):
        raise ValueError("scenario does not match its issued context")
    if scenario["execution"]["data_plane_profile"] != "standard_isolated":
        raise ValueError("the selected published output profile is standard_isolated")
    case = scenario["extensions"]["org.example.nav2-turtlebot3"]["case"]
    worker = load_mapping(capture / case / "worker-process.json")
    facts = worker["bootstrap_before_ros_init"]
    if (
        worker["run_id"] != context["run_id"]
        or facts["scenario_sha256"] != context["scenario_sha256"]
    ):
        raise ValueError("foreign worker context")
    if facts["public_packages"] != {
        "robotics-runtime-contracts": "0.20.0",
        "robotics-acceptance-harness": "0.21.0",
    }:
        raise ValueError("foreign public package cohort")
    middleware_sha = digest(capture / "fastdds.xml")
    if not (
        facts["middleware_profile_sha256"]
        == middleware_sha
        == scenario["data_plane_policy"]["middleware_configuration_sha256"]
        == "8acf197c65312ff4fd856e3a10ac35dc8af0f8e02ca4221bed7a7c7d8c1caedb"
    ):
        raise ValueError("selected middleware bytes/configuration binding differs")
    versions = {
        name: version
        for name, version, _architecture in (
            line.split("\t") for line in facts["package_versions"].splitlines()
        )
    }
    rmw_version = versions["ros-jazzy-rmw-fastrtps-cpp"].split("-", 1)[0]
    root = Path(__file__).resolve().parent
    repository = (
        subprocess.check_output(
            ["git", "-C", str(root), "rev-parse", "--show-toplevel"], timeout=10
        )
        .decode()
        .strip()
    )
    relative = (root / "workload.py").relative_to(repository)
    committed = subprocess.check_output(
        ["git", "-C", repository, "show", source_revision + ":" + str(relative)],
        timeout=10,
    )
    if (
        hashlib.sha256(committed).hexdigest() != worker["source_sha256"]
        or digest(capture / "workload.py") != worker["source_sha256"]
    ):
        raise ValueError("committed worker bytes differ from capture")
    state = load_mapping(capture / "recorder-facts/capture-state.json")
    events = json.loads(read_document_bytes(capture / "jobs-events.json"))
    stopped = json.loads(
        read_document_bytes(capture / "native-inspect-stopped.stdout")
    )[0]
    cleanup = load_mapping(capture / "cleanup.json")
    if not (
        state["run_id"] == context["run_id"]
        and state["capture_status"] == "complete"
        and state["closure_confirmed"]
        and len(state["bag"]["members"]) == 1
        and len(state["bag"]["topics"]) == 7
        and all(row["message_count"] > 0 for row in state["bag"]["topics"])
        and stopped["Id"] == cleanup["containerId"]
        and cleanup["remaining"] == []
        and stopped["State"]["ExitCode"] == 0
        and not stopped["State"]["OOMKilled"]
        and stopped["RestartCount"] == 0
    ):
        raise ValueError("closed native capture and owned terminal facts required")
    checkpoint = load_mapping(capture / "checkpoint.json")
    before = json.loads(read_document_bytes(capture / "native-inspect-before.stdout"))[
        0
    ]
    owner_key = "org.example.nav2.owner"
    if not (
        checkpoint["runId"] == context["run_id"]
        and checkpoint["owner"] == cleanup["owner"]
        and before["Id"] == stopped["Id"]
        and before["Image"] == stopped["Image"]
        and before["Config"]["Labels"].get(owner_key) == checkpoint["owner"]
        and stopped["Config"]["Labels"].get(owner_key) == checkpoint["owner"]
        and before["State"]["Running"] is True
        and stopped["State"]["Running"] is False
    ):
        raise ValueError(
            "native identity/ownership differs between acquisition and terminal capture"
        )
    member = state["bag"]["members"][0]
    if not re.fullmatch(r"[A-Za-z0-9_-]+\.mcap", member["path"]):
        raise ValueError("one confined MCAP basename required")
    bag = capture / "bag" / member["path"]
    if bag.is_symlink() or not bag.is_file() or bag.stat().st_size > 64 * 1024**2:
        raise ValueError("bounded regular recording required")
    if (
        digest(bag) != member["sha256"]
        or bag.stat().st_size != member["size_bytes"]
        or state["bag"]["size_bytes"] != member["size_bytes"]
    ):
        raise ValueError("recording bytes differ from the closed native recorder")
    operations = [row["op"] for row in events]
    for operation in (
        "worker-prepare-absent",
        "worker-" + case + "-absent",
        "recorder-process-absent",
    ):
        index = operations.index(operation)
        observed_absence = (capture / ("native-" + operation + ".stdout")).read_bytes()
        if observed_absence not in (b"False", b"False\n"):
            raise ValueError("native producer absence was not observed")
        if not events[index]["ok"] or index >= operations.index("stop"):
            raise ValueError("producer absence must precede stop")
    if facts["mcap_writer_header_sha256"] != MCAP_HEADER_SHA:
        raise ValueError("selected checked append-only writer required")
    output.mkdir(exist_ok=False)
    now = datetime.now(timezone.utc).isoformat()
    capabilities = ["ros-topic-capture", "owned-native-cleanup"]
    profile = {
        "schema_version": "qualification-profile.v1",
        "profile_id": "nav2-retained-observations",
        "provider_kind": "simulator",
        "requirements": [
            {"capability": value, "required": True} for value in capabilities
        ],
    }
    write_document(profile, output / "qualification-profile.json")
    image_digest = stopped["ImageDigest"]
    subject = {
        "kind": "oci_image",
        "locator": "oci://local-build/nav2@" + image_digest,
        "digest": image_digest,
    }
    provider = {
        "kind": "simulator",
        "implementation_id": "org.example.nav2-turtlebot3",
        "version": "source-" + source_revision[:12],
        "configuration_sha256": context["scenario_sha256"],
    }
    conformance = {
        "schema_version": "conformance-result.v1",
        "result_id": "nav2-capture-cleanup",
        "run_id": context["run_id"],
        "generated_at": now,
        "qualification_profile_sha256": digest(output / "qualification-profile.json"),
        "execution_subject_digest": image_digest,
        "provider": provider,
        "target_id": "nav2-simulation",
        "status": "passed",
        "capabilities": capabilities,
        "checks": [
            {
                "check_id": "closed-native-topics",
                "capability": capabilities[0],
                "status": "passed",
                "observed_value": state["bag"]["message_count"],
                "unit": "messages",
                "message": "Closed seven-topic capture; no DDS-delivery or self-contained action-schema claim.",
            },
            {
                "check_id": "owned-terminal-cleanup",
                "capability": capabilities[1],
                "status": "passed",
                "observed_value": True,
                "message": "Retained producer/terminal/removal facts; not full RunOwner qualification.",
            },
        ],
        "evidence": [
            reference(capture / name)
            for name in (
                "recorder-facts/capture-state.json",
                "cleanup.json",
                "native-inspect-stopped.stdout",
                "jobs-events.json",
            )
        ],
    }
    write_document(conformance, output / "conformance-result.json")
    host = {
        "os": platform.system().lower(),
        "os_version": platform.freedesktop_os_release()["VERSION_ID"],
        "architecture": platform.machine(),
        "kernel": platform.release(),
    }
    runtime = {
        "schema_version": "runtime-manifest.v1",
        "runtime_id": "nav2-" + context["run_id"],
        "generated_at": now,
        "execution_subject": subject,
        "components": {
            "contracts_revision": PUBLIC_REVISION,
            "harness_revision": PUBLIC_REVISION,
            "infra_revision": source_revision,
        },
        "host_platform": host,
        "execution_platform": {
            "os": "linux",
            "os_version": facts["os"]["VERSION_ID"],
            "architecture": facts["architecture"],
            "kernel": facts["kernel"],
        },
        "ros": {
            "distribution": "jazzy",
            "rmw_implementation": facts["environment"]["RMW_IMPLEMENTATION"],
            "rmw_version": rmw_version,
            "domain_id": int(facts["environment"]["ROS_DOMAIN_ID"]),
        },
        "provider_bindings": [
            {
                "target_id": "nav2-simulation",
                "provider": provider,
                "qualification_profile_sha256": digest(
                    output / "qualification-profile.json"
                ),
                "conformance_result_sha256": digest(output / "conformance-result.json"),
                "capabilities": capabilities,
            }
        ],
        "render": {
            "mode": "software",
            "renderer": "configured LIBGL_ALWAYS_SOFTWARE=1",
        },
        "workload": {"kind": "none"},
        "execution": {
            key: scenario["execution"][key]
            for key in (
                "target_environment",
                "data_source",
                "plant_backend",
                "time_mode",
                "data_plane_profile",
            )
        },
        "evaluator_bindings": scenario["evaluator_requirements"],
        "authorization": {"mode": "none"},
        "data_plane": {
            "rmw_implementation": facts["environment"]["RMW_IMPLEMENTATION"],
            "ipc_namespace": facts["namespace"]["ipc"],
            "network_namespace": facts["namespace"]["net"],
            "shm_transport": False,
            "data_sharing": False,
            "private_ipc": True,
            "middleware_configuration_sha256": facts["middleware_profile_sha256"],
        },
        "security": {
            "profile": "none",
            "strategy": "none",
            "enclaves": [],
            "policy_digests": [],
        },
        "lifecycle_states": [],
        "physical_targets": [],
        "clock": {
            "basis": "ros_time",
            "sync_protocol": "sim_clock",
            "offset_ms": 0,
            "drift_ppm": 0,
        },
    }
    write_document(runtime, output / "runtime-manifest.json")
    observed = capture / case / "observations.jsonl"
    result = command(
        [
            python,
            str(root / "derive-otlp.py"),
            "--source",
            str(observed),
            "--source-sha256",
            digest(observed),
            "--output",
            str(output / "projection"),
            "--run-id",
            context["run_id"],
            "--domain-id",
            "nav2",
        ],
        output / "derive",
    )
    if result.returncode:
        raise RuntimeError("offline projection refused")
    bag = capture / "bag" / state["bag"]["members"][0]["path"]
    result = command(
        [
            contracts,
            "recording-summary",
            "from-mcap",
            str(bag),
            "--max-raw-evidence-bytes",
            "67108864",
            "--output",
            str(output / "recording-summary.json"),
        ],
        output / "summary",
    )
    if result.returncode:
        raise RuntimeError("public recording summary refused")
    basis = {
        "capture_scope": "offline-retained-evaluation",
        "clock_basis": "Configured nominal shared ROS Clock; not measured offset/drift.",
        "spool_basis": "Single selected stock append-only MCAP file: logical peak equals final size. No live sampler/disk-quota. Metadata/JSON/CDR are outside recording spool.",
        "mcap_header_sha256": MCAP_HEADER_SHA,
        "host_basis": "Post-capture host readback; execution facts captured before ROS init.",
    }
    (output / "basis.json").write_text(json.dumps(basis, indent=2) + "\n")
    files = [
        (
            "workload",
            "other_evidence",
            capture / case / "workload.json",
            "application/json",
        ),
        (
            "cdr",
            "other_evidence",
            capture / case / "get-result-response.cdr",
            "application/octet-stream",
        ),
        ("recording", "recording", bag, "application/mcap"),
        (
            "metadata",
            "other_evidence",
            capture / "bag/metadata.yaml",
            "application/yaml",
        ),
        (
            "metrics",
            "metrics",
            output / "projection/metrics.otlp.jsonl",
            "application/x-ndjson",
        ),
        (
            "derivation",
            "other_evidence",
            output / "projection/derivation.json",
            "application/json",
        ),
        ("basis", "other_evidence", output / "basis.json", "application/json"),
        (
            "profile",
            "qualification_profile",
            output / "qualification-profile.json",
            "application/json",
        ),
        (
            "conformance",
            "conformance_result",
            output / "conformance-result.json",
            "application/json",
        ),
    ]
    draft = create_evidence_index(
        {
            "run_id": context["run_id"],
            "generated_at": now,
            "policy_observation": {
                "recording_mode": "bounded",
                "compression": "zstd",
                "retention_class": "test-evidence",
                "upload_mode": "local_only",
                "remote_sink_used": False,
                "spool_peak_size_bytes": state["bag"]["size_bytes"],
                "upload_lag_max_sec": 0,
            },
        }
    )
    metrics = None
    for identifier, kind, source, media in files:
        destination = output / "evidence" / identifier / source.name
        destination.parent.mkdir(parents=True)
        destination.write_bytes(source.read_bytes())
        destination.chmod(0o444)
        draft = add_evidence_artifact(
            draft,
            destination,
            {
                "artifact_id": identifier,
                "kind": kind,
                "media_type": media,
                "retention_class": "test-evidence",
                "storage_state": "local",
            },
            recording_summary=output / "recording-summary.json"
            if kind == "recording"
            else None,
        )
        if identifier == "metrics":
            metrics = str(destination.resolve())
    write_document(finalize_evidence_index(draft), output / "evidence-index.json")
    derivation = load_mapping(output / "projection/derivation.json")
    argv = [
        harness,
        "evaluate",
        "--scenario",
        str(capture / "scenario.json"),
        "--runtime",
        str(output / "runtime-manifest.json"),
        "--run-id",
        context["run_id"],
        "--domain-id",
        "nav2",
        "--run-context",
        str(capture / "run-context.json"),
        "--evidence-index",
        str(output / "evidence-index.json"),
        "--otel-metrics",
        metrics,
        "--window-start-ns",
        derivation["window_start_ns"],
        "--window-end-ns",
        derivation["window_end_ns"],
        "--extension-schema",
        "urn:nav2-turtlebot3:scenario:v1=" + str(capture / "nav2.schema.json"),
        "--evaluator-receipt",
        str(qualification / "receipt.json"),
        "--evaluator-verification",
        str(qualification / "verification.json"),
        "--max-raw-evidence-bytes",
        "16777216",
        "--output",
        str(output / "result"),
        "--diagnostic-output",
        str(output / "diagnostic.json"),
    ]
    for name in ("statement.json", "trust-policy.pem", "verification-evidence.zip"):
        argv.extend(["--evaluator-receipt-dependency", str(qualification / name)])
    return command(argv, output / "evaluate").returncode


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ("capture", "output", "qualification"):
        parser.add_argument("--" + name, type=Path, required=True)
    parser.add_argument("--source-revision", required=True)
    parser.add_argument("--contracts", required=True)
    parser.add_argument("--harness", required=True)
    parser.add_argument("--python", required=True)
    args = parser.parse_args()
    raise SystemExit(
        finalize(
            args.capture.resolve(),
            args.output.resolve(),
            args.qualification.resolve(),
            args.source_revision,
            args.contracts,
            args.harness,
            args.python,
        )
    )


if __name__ == "__main__":
    main()
