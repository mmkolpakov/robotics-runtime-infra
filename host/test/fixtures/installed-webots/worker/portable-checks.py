"""Verify native-only retained bytes with installed P/H APIs after source teardown."""

import argparse
import copy
import hashlib
import json
import shutil
from pathlib import Path
from urllib.parse import urlsplit
from urllib.request import url2pathname

from provider_qualification import SCHEMA_URI
from robotics_acceptance_harness.evidence import (
    EvidenceValidationError,
    load_evidence_index,
)
from robotics_runtime_contracts import load_mapping, validate_document
from robotics_runtime_contracts.writers import (
    add_evidence_artifact,
    create_evidence_index,
    finalize_evidence_index,
    write_document,
)


def facts(path):
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return digest, path.stat().st_size


def local_path(reference, root):
    uri = urlsplit(reference["uri"])
    if uri.scheme != "file" or uri.netloc not in ("", "localhost"):
        raise ValueError("native byte audit requires a local reference")
    path = Path(url2pathname(uri.path)).resolve(strict=True)
    path.relative_to(root)
    if not path.is_file():
        raise ValueError("native byte audit requires a regular file")
    return path


def byte_audit(references, root):
    observed = {}
    for reference in references:
        path = local_path(reference, root)
        digest, size = facts(path)
        if (digest, size) != (reference["sha256"], reference["size_bytes"]):
            raise ValueError(
                "retained bytes differ from the native lifecycle reference"
            )
        observed[path.relative_to(root).as_posix()] = {
            "sha256": digest,
            "size_bytes": size,
        }
    if not observed:
        raise ValueError("native byte audit is empty")
    return observed


def retained_audit(retained, excluded):
    completion = load_mapping(retained / "completion.json")
    if completion["status"] != "passed":
        raise ValueError("native lifecycle did not pass")
    outcomes = completion["resourceOutcomes"]
    if not outcomes or any(
        not row["attempted"]
        or not row["released"]
        or row.get("cleanupError")
        or not row["evidenceRefs"]
        for row in outcomes
    ):
        raise ValueError("native cleanup lacks independent evidence")
    linked = byte_audit(completion["evidenceRefs"], retained)
    all_files = {}
    for path in sorted(retained.rglob("*")):
        relative = path.relative_to(retained).as_posix()
        if any(path == value or value in path.parents for value in excluded):
            continue
        if path.is_file():
            path.resolve(strict=True).relative_to(retained)
            digest, size = facts(path)
            all_files[relative] = {"sha256": digest, "size_bytes": size}
    if not all_files:
        raise ValueError("retained byte inventory is empty")
    return {"lifecycle_references": linked, "all_retained_files": all_files}


def portable_copy(original, destination, schemas):
    original_index = load_mapping(original / "evidence-index.json")
    load_evidence_index(original / "evidence-index.json")
    template = {
        key: value
        for key, value in original_index.items()
        if key not in ("artifacts", "finalized")
    }
    draft = create_evidence_index(template)
    destination.mkdir(parents=True, exist_ok=False)
    locations = {}
    for artifact in original_index["artifacts"]:
        source = local_path(artifact, original.resolve())
        relative = source.relative_to(original.resolve())
        target = destination / relative
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, target)
        metadata = {
            key: value
            for key, value in artifact.items()
            if key not in ("local_path", "uri")
        }
        draft = add_evidence_artifact(draft, target, metadata)
        locations[artifact["uri"]] = target.resolve().as_uri()
    write_document(finalize_evidence_index(draft), destination / "evidence-index.json")
    shutil.copyfile(
        original / "qualification-profile.json",
        destination / "qualification-profile.json",
    )
    conformance = copy.deepcopy(load_mapping(original / "conformance-result.json"))
    for reference in conformance["evidence"]:
        reference["uri"] = locations[reference["uri"]]
    write_document(
        conformance, destination / "conformance-result.json", extension_schemas=schemas
    )
    verified = load_evidence_index(
        destination / "evidence-index.json", expected_run_id=original_index["run_id"]
    )
    return verified


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--retained", type=Path, required=True)
    parser.add_argument("--source-root", type=Path, required=True)
    parser.add_argument("--audit-output", type=Path)
    parser.add_argument("--expected-audit", type=Path)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    retained = args.retained.resolve(strict=True)
    if args.audit_output is not None:
        audit_path = args.audit_output.resolve()
        audit_path.relative_to(retained)
        if audit_path.exists():
            raise FileExistsError("byte audit output must be a fresh attempt")
        if not args.source_root.is_dir():
            raise ValueError("before-teardown audit requires the actual source mount")
        audit = retained_audit(retained, [audit_path])
        audit_path.write_text(json.dumps(audit, indent=2) + "\n")
        print(json.dumps({"status": "passed", "source_present": True, "audit": audit}))
        return
    if args.output is None or args.expected_audit is None:
        raise ValueError(
            "portable verification requires output and before-teardown audit"
        )
    output = args.output.resolve()
    output.relative_to(retained)
    if output.exists():
        raise FileExistsError("portable check output must be a fresh attempt")
    if args.source_root.exists():
        raise ValueError("native source path is still accessible to the verifier")
    before_path = args.expected_audit.resolve(strict=True)
    before_path.relative_to(retained)
    expected = load_mapping(before_path)
    actual = retained_audit(retained, [before_path, output])
    if actual != expected:
        raise ValueError("retained bytes changed across actual source teardown")
    schema = Path("/opt/c18/native-provider-source.v1.schema.json")
    schemas = {SCHEMA_URI: schema.read_bytes()}
    original = retained / "documents-live" / "documents"
    profile = load_mapping(original / "qualification-profile.json")
    conformance = load_mapping(original / "conformance-result.json")
    validate_document(profile)
    validate_document(conformance, extension_schemas=schemas)
    if conformance["status"] != "passed":
        raise ValueError("native provider conformance did not pass")
    verified = load_evidence_index(
        original / "evidence-index.json", expected_run_id=conformance["run_id"]
    )
    copied = portable_copy(original, output / "positive", schemas)
    original_bytes = {row["sha256"]: row["size_bytes"] for row in verified.links}
    copied_bytes = {row["sha256"]: row["size_bytes"] for row in copied.links}
    if original_bytes != copied_bytes:
        raise ValueError("portable evidence changed original bytes")
    negative = output / "tampered"
    portable_copy(original, negative, schemas)
    negative_index = load_mapping(negative / "evidence-index.json")
    target = local_path(negative_index["artifacts"][0], negative.resolve())
    with target.open("ab") as stream:
        stream.write(b"tampered native copy")
    try:
        load_evidence_index(negative / "evidence-index.json")
    except EvidenceValidationError as error:
        tamper = {"refused": True, "diagnostic": str(error)}
    else:
        raise AssertionError("public harness accepted tampered native bytes")
    actual = retained_audit(retained, [before_path, output])
    if actual != expected:
        raise ValueError("original retained inputs changed during portable checks")
    result = {
        "status": "passed",
        "scope": "native-only Webots conformance/profile and retained-byte portability",
        "source_present": False,
        "public_evidence_links": len(verified.links),
        "portable_evidence_links": len(copied.links),
        "before_teardown_audit": before_path.as_uri(),
        "native_byte_audit": actual,
        "all_original_retained_bytes_unchanged": True,
        "tampered_copy": tamper,
        "public_aggregate": {
            "status": "unsupported",
            "reason": "native-only payload has no observed ROS/rmw, authority delivery or ROS recording model required by the public acceptance route",
        },
    }
    (output / "result.json").write_text(json.dumps(result, indent=2) + "\n")
    print(json.dumps(result))


if __name__ == "__main__":
    main()
