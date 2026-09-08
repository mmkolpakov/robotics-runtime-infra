"""Prepare the synthetic PTY/vCAN test runtime from retained observations."""

from __future__ import annotations

import argparse
import hashlib
import os
import platform
import subprocess
import sys
from copy import deepcopy
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from uuid import uuid4

from robotics_runtime_contracts import dumps_canonical, loads_mapping, validate_role
from robotics_runtime_contracts.serialization import read_document_bytes
from robotics_runtime_contracts.writers import write_document


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def mapping(path: Path) -> dict[str, Any]:
    return dict(loads_mapping(read_document_bytes(path), source_name=str(path)))


def platform_facts() -> dict[str, str]:
    release = platform.freedesktop_os_release()
    return {
        "os": release["ID"],
        "os_version": release["VERSION_ID"],
        "architecture": platform.machine(),
        "kernel": platform.release(),
    }


def create_documents(
    args: argparse.Namespace, execution_platform: dict[str, str], ros: dict[str, Any]
) -> tuple[dict[str, Any], dict[str, Any], dict[str, Any], dict[str, Any]]:
    inputs = args.inputs
    template = mapping(inputs / "template.json")
    host = mapping(inputs / "host-platform.json")
    evidence = mapping(inputs / "target-evidence.json")
    identity = evidence.get("identity", {})
    serial = evidence.get("serial", {})
    can = evidence.get("can", {})
    if (
        evidence.get("schema_version") != "physical-attach-evidence.v1"
        or not all(isinstance(value, dict) for value in (identity, serial, can))
        or identity.get("scope") != "ci_synthetic_sros2_target"
        or identity.get("hardware_identity_verified") is not False
        or identity.get("kind") != "x509_spki"
        or serial.get("transport") != "pty"
        or serial.get("bidirectional_exchange") is not True
        or can.get("receive_only_gateway") is not True
    ):
        raise ValueError("expected the synthetic PTY/vCAN observation evidence")
    expected = {
        "serial-received.txt": b"target-to-host\n",
        "serial-reverse-received.txt": b"host-to-target\n",
    }
    for name, payload in expected.items():
        if read_document_bytes(inputs / name) != payload:
            raise ValueError(f"the observed PTY exchange failed: {name}")
    if b"123#DEADBEEF" not in read_document_bytes(inputs / "can-received.txt"):
        raise ValueError("the observed receive-only vCAN exchange failed")
    rmw_version = ros["rmw_version"]
    if (
        not isinstance(rmw_version, str)
        or not rmw_version.strip()
        or len(rmw_version.splitlines()) != 1
    ):
        raise ValueError("the installed RMW must report exactly one version")
    clock = mapping(inputs / "clock.json")
    if set(clock) != {"offset_ms", "drift_ppm"}:
        raise ValueError("expected the measured clock offset and drift")
    configuration = {
        "scope": "ci_synthetic_sros2_target",
        "hardware_identity_verified": False,
        "identity": identity,
        "serial": serial,
        "can": can,
    }
    profile = {
        "schema_version": "qualification-profile.v1",
        "profile_id": "ci.synthetic-pty-vcan-observation",
        "provider_kind": "hardware_target",
        "requirements": [{"capability": "live_observation", "required": True}],
    }
    result = {
        "schema_version": "conformance-result.v1",
        "result_id": "ci.synthetic-pty-vcan-observation",
        "run_id": args.run_id,
        "generated_at": datetime.now(UTC).isoformat(),
        "qualification_profile_sha256": sha256(dumps_canonical(profile)),
        "execution_subject_digest": args.subject_digest,
        "provider": {
            "kind": "hardware_target",
            "implementation_id": "ci_synthetic_pty_vcan",
            "version": args.infra_revision,
            "configuration_sha256": sha256(dumps_canonical(configuration)),
        },
        "target_id": "controller-ci",
        "status": "passed",
        "capabilities": ["live_observation"],
        "checks": [
            {
                "check_id": "synthetic-pty-vcan-observation",
                "capability": "live_observation",
                "status": "passed",
                "observed_value": True,
                "message": (
                    "PTY and virtual CAN observations only; "
                    "no physical hardware identity or qualification."
                ),
            }
        ],
        "evidence": [],
    }
    for name in (*expected, "can-received.txt", "target-evidence.json", "clock.json"):
        path = inputs / name
        raw = read_document_bytes(path)
        result["evidence"].append(
            {
                "uri": path.resolve().as_uri(),
                "sha256": sha256(raw),
                "size_bytes": len(raw),
                "media_type": "application/json" if path.suffix == ".json" else "text/plain",
            }
        )
    template.update(
        schema_version="runtime-manifest.v1",
        runtime_id="ci.physical-attach-runtime",
        generated_at=result["generated_at"],
        execution_subject={
            "kind": "oci_image",
            "locator": "oci://" + args.subject_reference,
            "digest": args.subject_digest,
        },
        components={
            "contracts_revision": args.workspace_revision,
            "harness_revision": args.workspace_revision,
            "infra_revision": args.infra_revision,
        },
        host_platform=host,
        execution_platform=execution_platform,
        ros=ros,
        clock={"basis": "system_time", "sync_protocol": "chrony_ntp", **clock},
        evaluator_bindings=[],
        physical_targets=[
            {
                "target_id": "controller-ci",
                "scope": "controller",
                "identity_kind": "x509_spki",
                "identity_sha256": identity["sha256"],
                "preflight_evidence_sha256": sha256(
                    read_document_bytes(inputs / "target-evidence.json")
                ),
            }
        ],
    )
    template["security"]["policy_digests"] = [
        sha256(read_document_bytes(inputs / "observer.policy.xml"))
    ]
    template["provider_bindings"] = [
        {
            "provider": deepcopy(result["provider"]),
            "target_id": result["target_id"],
            "capabilities": list(result["capabilities"]),
            "qualification_profile_sha256": result["qualification_profile_sha256"],
            "conformance_result_sha256": sha256(dumps_canonical(result)),
        }
    ]
    validate_role(profile, "qualification_profile")
    validate_role(result, "conformance_result")
    validate_role(template, "runtime_manifest")
    return profile, configuration, result, template


def write_outputs(output: Path, documents: tuple[dict[str, Any], ...]) -> None:
    profile, configuration, result, runtime = documents
    # Validate every public document before creating any output files.
    for document, role in (
        (profile, "qualification_profile"),
        (result, "conformance_result"),
        (runtime, "runtime_manifest"),
    ):
        validate_role(document, role)
    output.mkdir()
    write_document(profile, output / "profile.json")
    (output / "configuration.json").write_bytes(dumps_canonical(configuration))
    write_document(result, output / "conformance.json")
    write_document(runtime, output / "runtime-manifest.input.json")
    for path in output.iterdir():
        path.chmod(0o444)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--inputs", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    for name in (
        "subject-digest",
        "subject-reference",
        "workspace-revision",
        "infra-revision",
    ):
        parser.add_argument(f"--{name}", required=True)
    parser.add_argument("--run-id", default=f"run-{uuid4()}")
    parser.add_argument("--domain-id", type=int, default=92)
    args = parser.parse_args()
    try:
        if args.output.exists() or args.output.is_symlink():
            raise ValueError("the synthetic runtime output directory must be new")
        rmw = os.environ.get("RMW_IMPLEMENTATION", "rmw_fastrtps_cpp")
        version = subprocess.check_output(
            ["ros2", "pkg", "xml", rmw, "--tag", "version"],
            text=True,
            timeout=20,
        ).strip()
        ros = {
            "distribution": os.environ["ROS_DISTRO"],
            "rmw_implementation": rmw,
            "rmw_version": version,
            "domain_id": args.domain_id,
        }
        documents = create_documents(args, platform_facts(), ros)
        write_outputs(args.output, documents)
    except (OSError, ValueError, KeyError, subprocess.SubprocessError) as error:
        print(f"synthetic runtime: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
