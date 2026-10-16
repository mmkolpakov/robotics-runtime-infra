"""Verify the Nav2 wheel with an explicit external Cosign key-only policy."""

from __future__ import annotations

import argparse
import base64
import json
from datetime import UTC, datetime
from hashlib import sha256
from importlib.metadata import distribution
from pathlib import Path

from robotics_acceptance_harness.evaluator_trust import (
    CosignKeyVerifierProfile,
    CosignKeyWheelPolicy,
    authenticate_wheel_with_cosign_key,
    read_once,
    validate_evaluator_wheel,
    verify_installed_wheel,
)
from robotics_runtime_contracts import dumps_canonical, loads_mapping
from robotics_runtime_contracts.writers import (
    create_artifact_receipt,
    write_bytes_atomically,
    write_document,
)

NAMESPACE = "org.example.nav2-turtlebot3"
DISTRIBUTION = "nav2-turtlebot3-evaluator"
VERSION = "0.3.0"


def write(path: Path, value: object) -> Path:
    return write_bytes_atomically(dumps_canonical(value), path)


def digest(path: Path) -> str:
    return sha256(read_once(path, 16 * 1024 * 1024)).hexdigest()


def qualify(profile_path: Path, output: Path, *, installed: bool = True) -> dict:
    """The external operator input, never the bundle, chooses the approved key/tool."""
    if profile_path.stat().st_mode & 0o022:
        raise ValueError("operator trust profile must not be group/other writable")
    values = loads_mapping(
        read_once(profile_path, 1024 * 1024), source_name=str(profile_path)
    )
    if (
        set(values) != {"profile_version", "verifier", "evaluators"}
        or values["profile_version"] != 1
    ):
        raise ValueError("an explicit public operator trust profile is required")
    verifier = dict(values["verifier"])
    if verifier.pop("kind", None) != "cosign_key_no_tlog":
        raise ValueError(
            "this local publisher recipe requires explicit Cosign key-only mode"
        )
    for key in ("executable", "public_key", "trusted_root"):
        verifier[key] = Path(verifier[key])
    profile = CosignKeyVerifierProfile(**verifier)
    if len(values["evaluators"]) != 1:
        raise ValueError("one exact Nav2 evaluator policy is required")
    selected = values["evaluators"][0]
    if (
        set(selected) != {"namespace", "wheel", "bundle", "publisher"}
        or selected["namespace"] != NAMESPACE
    ):
        raise ValueError("one exact Nav2 namespace policy is required")
    policy = CosignKeyWheelPolicy(**selected["publisher"])
    bundle_path = Path(selected["bundle"])
    bundle_raw = read_once(bundle_path, 16 * 1024 * 1024)
    authenticated = authenticate_wheel_with_cosign_key(
        selected["wheel"], bundle_path, profile=profile, policy=policy
    )
    if sha256(bundle_raw).hexdigest() != authenticated.bundle_sha256:
        raise ValueError("signature bundle changed during verification")
    validate_evaluator_wheel(authenticated)
    if authenticated.filename != "nav2_turtlebot3_evaluator-0.3.0-py3-none-any.whl":
        raise ValueError(
            "authenticated wheel filename is not the selected Nav2 release"
        )
    if installed:
        binding = verify_installed_wheel(authenticated, distribution(DISTRIBUTION))
        if binding.version != VERSION or binding.entry_points != (
            (
                "robotics_acceptance.evaluators",
                NAMESPACE,
                "nav2_turtlebot3_evaluator:evaluate",
            ),
        ):
            raise ValueError("authenticated wheel is not the selected Nav2 evaluator")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    wheel = output / authenticated.filename
    write_bytes_atomically(authenticated.wheel_bytes, wheel)
    statement = output / "statement.json"
    write_bytes_atomically(
        base64.b64decode(
            json.loads(bundle_raw)["dsseEnvelope"]["payload"], validate=True
        ),
        statement,
    )
    report = output / "verified-report.txt"
    write_bytes_atomically(authenticated.verification_report, report)
    expectations = write(output / "publisher.json", selected["publisher"])
    verified_at = datetime.now(UTC).isoformat()
    artifact = {
        "uri": wheel.resolve().as_uri(),
        "sha256": authenticated.sha256,
        "size_bytes": len(authenticated.wheel_bytes),
        "media_type": "application/vnd.python.wheel",
        "immutable_revision": "sha256:" + authenticated.sha256,
    }
    identity = "key-sha256:" + policy.public_key_sha256
    verification = output / "verification.json"
    write_document(
        {
            "schema_version": "artifact-verification.v1",
            "verification_id": "nav2-key-only-wheel",
            "artifact": artifact,
            "statement_sha256": digest(statement),
            "producer_identity": identity,
            "producer_implementation": "cosign-key-blob-attestation",
            "trust_policy_sha256": digest(expectations),
            "verification_evidence_sha256": digest(report),
            "verifier": {
                "identity": identity,
                "implementation": "cosign",
                "version": profile.version,
            },
            "verified_at": verified_at,
            "status": "passed",
        },
        verification,
    )
    receipt = output / "receipt.json"
    write_document(
        create_artifact_receipt(
            {"receipt_id": "nav2-key-only-wheel", "created_at": verified_at},
            wheel,
            verification,
            [statement, expectations, report],
        ),
        receipt,
    )
    binding = {
        "namespace": NAMESPACE,
        "entry_point": "nav2_turtlebot3_evaluator:evaluate",
        "distribution": DISTRIBUTION,
        "version": VERSION,
        "artifact_sha256": authenticated.sha256,
        "receipt_sha256": digest(receipt),
    }
    write(output / "binding.json", binding)
    return binding


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--trust-profile", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument(
        "--preinstall",
        action="store_true",
        help="validate and capture the authenticated wheel before pip installation",
    )
    args = parser.parse_args()
    print(
        json.dumps(
            qualify(args.trust_profile, args.output, installed=not args.preinstall),
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
