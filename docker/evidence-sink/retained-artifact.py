#!/usr/bin/env python3
"""Verify a retained S3 recording against an independently supplied public key."""

from __future__ import annotations

import argparse
import base64
import hashlib
import os
import re
import subprocess
import sys
import tempfile
from datetime import UTC, datetime
from pathlib import Path
from typing import Any
from urllib.parse import quote, unquote, urlsplit
from uuid import UUID

from robotics_runtime_contracts import dumps_canonical, loads_mapping, validate_document
from robotics_runtime_contracts.serialization import read_document_bytes
from robotics_runtime_contracts.writers import write_document

PREDICATE_TYPE = "https://robotics-runtime.dev/attestations/artifact-retention/v1"
MAX_ARTIFACT_BYTES = 1_073_741_824


def sha256(raw: bytes) -> str:
    return hashlib.sha256(raw).hexdigest()


def file_facts(path: Path) -> tuple[str, int]:
    with path.expanduser().open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
        size = os.fstat(stream.fileno()).st_size
    return digest, size


def mapping(raw: bytes, name: str) -> dict[str, Any]:
    return dict(loads_mapping(raw, source_name=name))


def registration_descriptor(
    document: dict[str, Any], *, maximum_size: int
) -> tuple[dict[str, Any], str, str, str]:
    if document.get("upload_status") != "confirmed":
        raise ValueError("retention verification requires a confirmed upload")
    run_id = document.get("run_id")
    if not isinstance(run_id, str) or not run_id.startswith("run-"):
        raise ValueError("registration must identify its run")
    parsed_run = UUID(run_id[4:])
    if parsed_run.version != 4 or run_id != f"run-{parsed_run}":
        raise ValueError("registration run ID must have canonical UUID4 form")
    size = document.get("size_bytes")
    if type(size) is not int or not 0 < size <= maximum_size:
        raise ValueError(
            "recording size must be positive and within the download limit"
        )
    digest = document.get("sha256")
    if not isinstance(digest, str) or re.fullmatch("[0-9a-f]{64}", digest) is None:
        raise ValueError("registration SHA-256 is invalid")
    if document.get("media_type") != "application/mcap":
        raise ValueError("the S3 recording verifier requires application/mcap")
    revision = document.get("version_id")
    if not isinstance(revision, str) or not revision or revision == "null":
        raise ValueError("S3 requires a non-null immutable object version")
    uri = document.get("uri")
    if not isinstance(uri, str):
        raise ValueError("registration URI is missing")
    location = urlsplit(uri)
    if (
        location.scheme != "s3"
        or re.fullmatch(r"[a-z0-9][a-z0-9.-]{1,61}[a-z0-9]", location.netloc) is None
        or location.query
        or location.fragment
    ):
        raise ValueError("expected an S3 bucket URI without query or fragment")
    key = unquote(location.path.removeprefix("/"), errors="strict")
    if not key or uri != f"s3://{location.netloc}/{quote(key, safe='/')}":
        raise ValueError("S3 object URI must use canonical percent encoding")
    descriptor = {
        "uri": uri,
        "sha256": digest,
        "size_bytes": size,
        "media_type": "application/mcap",
        "immutable_revision": revision,
    }
    return descriptor, run_id, location.netloc, key


def retention_predicate(registration: Path, source: Path) -> dict[str, Any]:
    document = mapping(read_document_bytes(registration), str(registration))
    descriptor, run_id, _, _ = registration_descriptor(
        document, maximum_size=MAX_ARTIFACT_BYTES
    )
    digest, size = file_facts(source)
    if (digest, size) != (descriptor["sha256"], descriptor["size_bytes"]):
        raise ValueError("signing source does not match the upload registration")
    return {
        "artifact": descriptor,
        "run_id": run_id,
        "producer_implementation": "robotics-runtime-infra/evidence-sink",
    }


def execute(command: list[str], *, timeout: float = 300) -> bytes:
    result = subprocess.run(
        command,
        capture_output=True,
        timeout=timeout,
        check=False,
        env={**os.environ, "AWS_PAGER": "", "AWS_CLI_AUTO_PROMPT": "off"},
    )
    if result.returncode:
        detail = result.stderr.decode("utf-8", errors="replace").strip()
        raise ValueError(
            f"{Path(command[0]).name} failed ({result.returncode}): {detail}"
        )
    return result.stdout


def cosign_version(executable: str) -> str:
    observed = mapping(
        execute([executable, "version", "--json"]), "cosign-version.json"
    )
    version = observed.get("gitVersion")
    match = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:\+[^\s]+)?", str(version))
    if match is None or tuple(map(int, match.groups())) < (3, 1, 3):
        raise ValueError(
            "retention verification requires a stable Cosign 3.1.3 or newer"
        )
    return str(version)


def download_version(
    executable: str, descriptor: dict[str, Any], bucket: str, key: str, output: Path
) -> bytes:
    # One extra byte detects a larger object without downloading an unbounded body.
    response = execute(
        [
            executable,
            "s3api",
            "get-object",
            f"--bucket={bucket}",
            f"--key={key}",
            f"--version-id={descriptor['immutable_revision']}",
            f"--range=bytes=0-{descriptor['size_bytes']}",
            "--output=json",
            "--no-cli-pager",
            str(output),
        ]
    )
    metadata = mapping(response, "s3-get-object.json")
    size = descriptor["size_bytes"]
    if (
        metadata.get("VersionId") != descriptor["immutable_revision"]
        or metadata.get("ContentType") != descriptor["media_type"]
        or type(metadata.get("ContentLength")) is not int
        or metadata["ContentLength"] != size
        or metadata.get("ContentRange") != f"bytes 0-{size - 1}/{size}"
        or metadata.get("DeleteMarker", False) is not False
    ):
        raise ValueError(
            "S3 response does not describe the complete requested object version"
        )
    if file_facts(output) != (descriptor["sha256"], size):
        raise ValueError(
            "downloaded object bytes do not match the registration SHA-256 and size"
        )
    return response


def authenticated_statement(
    bundle_raw: bytes, descriptor: dict[str, Any], run_id: str
) -> tuple[bytes, str]:
    bundle = mapping(bundle_raw, "verification-evidence.sigstore.json")
    envelope = bundle.get("dsseEnvelope")
    if (
        not isinstance(envelope, dict)
        or envelope.get("payloadType") != "application/vnd.in-toto+json"
    ):
        raise ValueError("verified bundle must contain an in-toto DSSE envelope")
    encoded = envelope.get("payload")
    if not isinstance(encoded, str):
        raise ValueError("verified bundle payload is missing")
    raw = base64.b64decode(encoded, validate=True)
    statement = mapping(raw, "statement.json")
    if (
        statement.get("_type")
        not in {
            "https://in-toto.io/Statement/v0.1",
            "https://in-toto.io/Statement/v1",
        }
        or statement.get("predicateType") != PREDICATE_TYPE
    ):
        raise ValueError("verified statement has another predicate type")
    subjects = statement.get("subject")
    if (
        not isinstance(subjects, list)
        or len(subjects) != 1
        or not isinstance(subjects[0], dict)
        or subjects[0].get("digest") != {"sha256": descriptor["sha256"]}
    ):
        raise ValueError(
            "verified statement must identify exactly the retained artifact"
        )
    predicate = statement.get("predicate")
    if not isinstance(predicate, dict) or set(predicate) != {
        "artifact",
        "run_id",
        "producer_implementation",
    }:
        raise ValueError("verified statement has an unsupported retention predicate")
    if (
        not isinstance(predicate["artifact"], dict)
        or dumps_canonical(predicate["artifact"]) != dumps_canonical(descriptor)
        or predicate["run_id"] != run_id
        or not isinstance(predicate["producer_implementation"], str)
    ):
        raise ValueError(
            "signed retention predicate does not match the registered artifact and run"
        )
    return raw, predicate["producer_implementation"]


def verify(arguments: argparse.Namespace) -> Path:
    output = arguments.output.expanduser().absolute()
    if output.exists():
        raise ValueError("verification output directory must not already exist")
    if arguments.max_artifact_bytes < 1:
        raise ValueError("download limit must be positive")
    registration = mapping(
        read_document_bytes(arguments.registration), str(arguments.registration)
    )
    descriptor, run_id, bucket, key = registration_descriptor(
        registration, maximum_size=arguments.max_artifact_bytes
    )
    bundle_raw = read_document_bytes(arguments.bundle)
    policy_raw = read_document_bytes(arguments.key)
    version = cosign_version(arguments.cosign)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(
        prefix=".retention-", dir=output.parent
    ) as directory:
        work = Path(directory)
        bundle = work / "verification-evidence.sigstore.json"
        policy = work / "trust-policy.pem"
        source = work / "downloaded.mcap"
        bundle.write_bytes(bundle_raw)
        policy.write_bytes(policy_raw)
        response = download_version(arguments.aws, descriptor, bucket, key, source)
        # This mode trusts the independently supplied public key. It makes no
        # claims about Fulcio identities or transparency-log inclusion.
        execute(
            [
                arguments.cosign,
                "verify-blob-attestation",
                "--check-claims=true",
                "--type",
                PREDICATE_TYPE,
                "--bundle",
                str(bundle),
                "--key",
                str(policy),
                "--insecure-ignore-tlog",
                str(source),
            ]
        )
        statement_raw, producer = authenticated_statement(
            bundle_raw, descriptor, run_id
        )
        statement = work / "statement.json"
        statement.write_bytes(statement_raw)
        (work / "s3-get-object.json").write_bytes(response)
        result = {
            "schema_version": "artifact-verification.v1",
            "verification_id": f"retention-{descriptor['sha256']}",
            "statement_sha256": sha256(statement_raw),
            "artifact": descriptor,
            "producer_identity": f"key-sha256:{sha256(policy_raw)}",
            "producer_implementation": producer,
            "trust_policy_sha256": sha256(policy_raw),
            "verification_evidence_sha256": sha256(bundle_raw),
            "verifier": {
                "identity": "urn:robotics-runtime-infra:retained-artifact-verifier",
                "implementation": "cosign-key-signature",
                "version": version,
            },
            "verified_at": datetime.now(UTC).isoformat(),
            "status": "passed",
        }
        validate_document(result)
        write_document(result, work / "artifact-verification.json")
        source.unlink()
        for path in work.iterdir():
            path.chmod(0o444)
        work.chmod(0o755)
        work.rename(output)
    return output


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    predicate = commands.add_parser(
        "predicate", help="Prepare the predicate for Cosign attest-blob."
    )
    predicate.add_argument("--registration", type=Path, required=True)
    predicate.add_argument("--source", type=Path, required=True)
    verifier = commands.add_parser(
        "verify",
        help="Verify a signature and exact S3 version with a pinned public key.",
    )
    for name in ("registration", "bundle", "key", "output"):
        verifier.add_argument(f"--{name}", type=Path, required=True)
    verifier.add_argument("--cosign", default="cosign")
    verifier.add_argument("--aws", default="aws")
    verifier.add_argument("--max-artifact-bytes", type=int, default=MAX_ARTIFACT_BYTES)
    arguments = parser.parse_args()
    try:
        if arguments.command == "predicate":
            sys.stdout.buffer.write(
                dumps_canonical(
                    retention_predicate(arguments.registration, arguments.source)
                )
            )
        else:
            print(verify(arguments))
    except (OSError, ValueError, subprocess.TimeoutExpired) as error:
        print(f"retained-artifact: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
