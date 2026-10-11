"""Temporary stock-Cosign publisher for installed source controls, not native admission."""

from __future__ import annotations

import argparse
import base64
import json
import subprocess
from dataclasses import asdict
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path
from tempfile import TemporaryDirectory

from robotics_acceptance_harness.evaluator_trust import (
    CosignKeyVerifierProfile,
    CosignKeyWheelPolicy,
    authenticate_wheel_with_cosign_key,
    read_once,
    validate_evaluator_wheel,
)
from robotics_runtime_contracts.writers import create_artifact_receipt, write_document

NAMESPACE = "org.example.px4-x500"
PREDICATE = "urn:px4-x500:source-evaluator-control:v1"


def write(path, value):
    path.write_text(json.dumps(value, sort_keys=True))
    return path


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def prepare(wheel: Path, tool_profile: Path, output: Path):
    output = output.resolve()
    wheel = wheel.resolve()
    approved = json.loads(tool_profile.read_bytes())
    tool = Path(approved["executable"])
    if digest(tool) != approved["executable_sha256"]:
        raise ValueError("tool differs from approved executable SHA-256")
    output.mkdir(mode=0o700, parents=True, exist_ok=False)
    with TemporaryDirectory(prefix="px4-local-publisher-") as temporary:
        root = Path(temporary)
        environment = {
            "HOME": str(root),
            "XDG_CONFIG_HOME": str(root / "config"),
            "COSIGN_PASSWORD": "",
            "LC_ALL": "C.UTF-8",
        }

        def command(*arguments):
            result = subprocess.run(
                [str(tool), *arguments],
                cwd=root,
                env=environment,
                stdin=subprocess.DEVNULL,
                capture_output=True,
                timeout=30,
                check=False,
            )
            if result.returncode:
                raise ValueError("stock temporary publisher operation refused")
            return result.stdout

        if (
            json.loads(command("version", "--json"))["gitVersion"]
            != approved["version"]
        ):
            raise ValueError("tool build version differs from approved profile")
        command("signing-config", "create", "--out", "signing.json")
        command("trusted-root", "create", "--out", "roots.json")
        command("generate-key-pair", "--output-key-prefix", "publisher")
        command("generate-key-pair", "--output-key-prefix", "other")
        predicate = write(
            root / "predicate.json",
            {"scope": "synthetic decoded SDK inputs, no native performance claim"},
        )
        command(
            "attest-blob",
            "--yes",
            "--key",
            "publisher.key",
            "--signing-config",
            "signing.json",
            "--trusted-root",
            "roots.json",
            "--type",
            PREDICATE,
            "--predicate",
            str(predicate),
            "--bundle",
            "wheel.sigstore.json",
            str(wheel.resolve()),
        )
        for source, target in (
            ("publisher.pub", "publisher.pub"),
            ("other.pub", "other.pub"),
            ("roots.json", "roots.json"),
            ("wheel.sigstore.json", "bundle.json"),
        ):
            (output / target).write_bytes((root / source).read_bytes())
    key, roots, bundle = (
        output / "publisher.pub",
        output / "roots.json",
        output / "bundle.json",
    )
    profile = CosignKeyVerifierProfile(
        tool,
        approved["executable_sha256"],
        approved["version"],
        key,
        digest(key),
        roots,
        digest(roots),
    )
    policy = CosignKeyWheelPolicy(
        digest(wheel), PREDICATE, digest(key), "key_only_no_tlog"
    )
    bundle_raw = read_once(bundle, 16 * 1024**2)
    authenticated = authenticate_wheel_with_cosign_key(
        wheel, bundle, profile=profile, policy=policy
    )
    validate_evaluator_wheel(authenticated)
    if digest(bundle) != authenticated.bundle_sha256:
        raise ValueError("bundle differs from authenticated source bytes")
    captured = output / authenticated.filename
    captured.write_bytes(authenticated.wheel_bytes)
    statement = output / "statement.json"
    statement.write_bytes(
        base64.b64decode(
            json.loads(bundle_raw)["dsseEnvelope"]["payload"], validate=True
        )
    )
    audit = output / "verified-report.txt"
    audit.write_bytes(authenticated.verification_report)
    expectations = write(output / "publisher.json", asdict(policy))
    at = datetime.now(UTC).isoformat()
    artifact = {
        "uri": captured.as_uri(),
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
            "verification_id": "px4-source-wheel",
            "artifact": artifact,
            "statement_sha256": digest(statement),
            "producer_identity": identity,
            "producer_implementation": "cosign-key-blob-attestation",
            "trust_policy_sha256": digest(expectations),
            "verification_evidence_sha256": digest(audit),
            "verifier": {
                "identity": identity,
                "implementation": "cosign",
                "version": profile.version,
            },
            "verified_at": at,
            "status": "passed",
        },
        verification,
    )
    receipt = output / "receipt.json"
    write_document(
        create_artifact_receipt(
            {"receipt_id": "px4-source-wheel", "created_at": at},
            captured,
            verification,
            [statement, expectations, audit],
        ),
        receipt,
    )
    binding = write(
        output / "binding.json",
        {
            "namespace": NAMESPACE,
            "entry_point": "px4_x500_evaluator:evaluate",
            "distribution": "px4-x500-evaluator",
            "version": "0.1.0",
            "artifact_sha256": authenticated.sha256,
            "receipt_sha256": digest(receipt),
        },
    )
    operator = write(
        output / "operator-profile.json",
        {
            "profile_version": 1,
            "verifier": {
                "kind": "cosign_key_no_tlog",
                **approved,
                "public_key": str(key),
                "public_key_sha256": digest(key),
                "trusted_root": str(roots),
                "trusted_root_sha256": digest(roots),
            },
            "evaluators": [
                {
                    "namespace": NAMESPACE,
                    "wheel": str(captured),
                    "bundle": str(bundle),
                    "publisher": asdict(policy),
                }
            ],
        },
    )
    operator.chmod(0o400)
    return {
        "captured_wheel": str(captured),
        "binding": str(binding),
        "profile": str(operator),
    }


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--wheel", type=Path, required=True)
    parser.add_argument("--tool-profile", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    arguments = parser.parse_args()
    print(
        json.dumps(
            prepare(arguments.wheel, arguments.tool_profile, arguments.output),
            sort_keys=True,
        )
    )


if __name__ == "__main__":
    main()
