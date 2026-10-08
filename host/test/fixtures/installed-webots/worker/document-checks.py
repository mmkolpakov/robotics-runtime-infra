"""Use installed public P/H APIs against the newly completed native Webots bytes."""

import argparse
import hashlib
import json
import shutil
import tempfile
from datetime import datetime, timezone
from importlib import metadata
from pathlib import Path

from provider_qualification import CAPABILITIES, NAMESPACE, SCHEMA_URI, produce
from robotics_acceptance_harness.evidence import (
    EvidenceValidationError,
    load_evidence_index,
)
from robotics_runtime_contracts import ContractError, validate_document
from robotics_runtime_contracts.providers import (
    ProviderRequirementError,
    validate_provider_requirements,
)
from robotics_runtime_contracts.writers import write_document


def reject(work, expected):
    try:
        work()
    except expected as error:
        return {"refused": True, "diagnostic": str(error)}
    raise AssertionError("operation unexpectedly accepted")


def create_native_documents(
    native_root,
    worker,
    output,
    schema,
    execution_subject_digest,
    run_id,
    declared_upstream,
):
    identity_path = native_root / "worker-identity.json"
    if not identity_path.is_file():
        raise ValueError("native worker identity is absent")
    raw_identity = identity_path.read_bytes()
    identity_facts = {
        "sha256": hashlib.sha256(raw_identity).hexdigest(),
        "size_bytes": len(raw_identity),
    }
    reference = worker.get("worker_identity_ref")
    if not isinstance(reference, dict) or (
        reference.get("sha256"),
        reference.get("size_bytes"),
    ) != (identity_facts["sha256"], identity_facts["size_bytes"]):
        raise ValueError("native worker identity bytes do not match worker result")
    identity = json.loads(raw_identity)
    declared_release = declared_upstream.get("release")
    if not isinstance(declared_release, str) or not declared_release:
        raise ValueError("declared Webots compatibility release is absent")
    release = identity.get("release")
    if not isinstance(release, str) or not release:
        raise ValueError("observed native Webots release is absent")
    if (
        release != declared_release
        or identity.get("upstream", {}).get("release") != declared_release
    ):
        raise ValueError("observed native Webots release differs from declared pin")
    if identity.get("owner_id") != worker.get("owner_id"):
        raise ValueError("native worker identity belongs to another owner")
    names = [
        "controller-result.json",
        "worker-result.json",
        "last-native-state.json",
        "ready.json",
        "pre-reset.json",
        "measurement.json",
        "worker-identity.json",
    ]
    manifest = {
        "backend": "webots",
        "version": release,
        "executionSubjectDigest": execution_subject_digest,
        "files": {
            name: identity_facts
            if name == "worker-identity.json"
            else {
                "sha256": hashlib.sha256((native_root / name).read_bytes()).hexdigest(),
                "size_bytes": (native_root / name).stat().st_size,
            }
            for name in names
        },
    }
    generated_at = datetime.now(timezone.utc).isoformat()
    output.mkdir(parents=True, exist_ok=False)
    manifest_path = output / "native-inputs.json"
    manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
    paths = produce(
        "webots",
        native_root,
        manifest_path,
        schema,
        output / "documents",
        generated_at=generated_at,
        run_id=run_id,
    )
    return paths, manifest_path, generated_at


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--native", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--execution-subject-digest", required=True)
    parser.add_argument("--verify-only", action="store_true")
    args = parser.parse_args()
    versions = {
        name: metadata.version(name)
        for name in ("robotics-runtime-contracts", "robotics-acceptance-harness")
    }
    foundation = json.loads(
        Path("/usr/share/robotics-runtime/foundation-lock.json").read_bytes()
    )
    expected = {
        package["distribution"]: package["version"]
        for package in foundation["packages"].values()
    }
    assert versions == expected
    assert not Path("/opt/ros").exists()
    schema = Path("/opt/c18/native-provider-source.v1.schema.json")
    if args.verify_only:
        verified = load_evidence_index(
            args.output / "documents/evidence-index.json", expected_run_id=args.run_id
        )
        print(
            json.dumps(
                {
                    "verified": True,
                    "versions": versions,
                    "links": len(verified.links),
                    "source_present": args.native.exists(),
                }
            )
        )
        return
    native = json.loads((args.native / "controller-result.json").read_bytes())
    worker = json.loads((args.native / "worker-result.json").read_bytes())
    assert native["status"] == worker["status"] == "completed"
    assert worker["processes_reaped"] and worker["evidence_exported_before_stop"]
    assert native["reset"]["observed"] and native["camera"]["sampling_period_ms"] == 0
    assert all(
        s["result"] == 0 and s["after_seconds"] > s["before_seconds"]
        for s in native["samples"]
    )
    assert (
        native["last_native_state"]["body_position_m"][2]
        < native["initial_state"]["body_position_m"][2]
    )
    declared_upstream = json.loads(
        Path("/opt/robotics/webots/upstream.json").read_bytes()
    )
    paths, manifest_path, generated_at = create_native_documents(
        args.native,
        worker,
        args.output,
        schema,
        args.execution_subject_digest,
        args.run_id,
        declared_upstream,
    )
    result = json.loads(paths["conformance"].read_bytes())
    validate_document(result, extension_schemas={SCHEMA_URI: schema.read_bytes()})
    assert result["status"] == "passed"
    assert all(
        row["unit"] == "s" and row["hex"] == float(row["value"]).hex()
        for row in result["extensions"][NAMESPACE]["native_times"]
    )
    verified = load_evidence_index(paths["evidence"], expected_run_id=args.run_id)
    checks = {
        "installed_python_pair": versions,
        "native_lifecycle": True,
        "native_seconds_binary64": True,
        "backend_version": result["provider"]["version"],
        "document_generated_at": result["generated_at"],
        "public_writer_and_harness": len(verified.links),
        "source_scene_sha256": hashlib.sha256(
            (args.native / "inputs/native.wbt").read_bytes()
        ).hexdigest(),
    }
    checks["occupied_output"] = reject(
        lambda: produce(
            "webots",
            args.native,
            manifest_path,
            schema,
            args.output / "documents",
            generated_at=generated_at,
            run_id=args.run_id,
        ),
        FileExistsError,
    )
    checks["missing_provider"] = reject(
        lambda: validate_provider_requirements(
            {"capabilities": ["simulated_physics"]}, []
        ),
        ProviderRequirementError,
    )
    checks["missing_capability"] = reject(
        lambda: validate_provider_requirements(
            {"capabilities": ["native-rtx-execution"]}, [{"capabilities": CAPABILITIES}]
        ),
        ProviderRequirementError,
    )
    checks["wrong_selected_provider"] = reject(
        lambda: produce(
            "gazebo",
            args.native,
            manifest_path,
            schema,
            args.output / "wrong-provider",
            generated_at=generated_at,
            run_id=args.run_id,
        ),
        ValueError,
    )
    with tempfile.TemporaryDirectory() as tmp:
        changed = Path(tmp) / "native"
        shutil.copytree(args.native, changed)
        (changed / "controller-result.json").write_bytes(
            (changed / "controller-result.json").read_bytes() + b" "
        )
        before = paths["conformance"].read_bytes()
        checks["tampered_native_bytes"] = reject(
            lambda: produce(
                "webots",
                changed,
                manifest_path,
                schema,
                args.output / "tampered",
                generated_at=generated_at,
                run_id=args.run_id,
            ),
            ContractError,
        )
        assert paths["conformance"].read_bytes() == before
        copied = Path(tmp) / "copy"
        shutil.copytree(args.output / "documents", copied)
        copied_index = json.loads((copied / "evidence-index.json").read_bytes())
        for row in copied_index["artifacts"]:
            row["uri"] = (copied / "raw" / Path(row["uri"]).name).as_uri()
        write_document(copied_index, copied / "evidence-index.json")
        (copied / "raw/controller-result.json").write_bytes(
            (copied / "raw/controller-result.json").read_bytes() + b" "
        )
        checks["harness_tamper"] = reject(
            lambda: load_evidence_index(copied / "evidence-index.json"),
            EvidenceValidationError,
        )
    (args.output / "document-checks.json").write_text(
        json.dumps(checks, indent=2) + "\n"
    )
    print(json.dumps(checks))


if __name__ == "__main__":
    main()
