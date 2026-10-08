"""Qualify a locally built consumer wheel with explicit, local-key provenance."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import subprocess
import zipfile
from datetime import datetime, timezone
from pathlib import Path


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


def document(path: Path, value: dict) -> None:
    path.write_text(json.dumps(value, indent=2) + "\n")


def command(argv: list[str], output: Path) -> None:
    result = subprocess.run(argv, capture_output=True, timeout=30, check=False)
    output.write_bytes(result.stdout + result.stderr)
    if result.returncode:
        raise RuntimeError(f"{Path(argv[0]).name} verification command refused")


def qualify(
    wheel: Path,
    tests: Path,
    native_cases: Path,
    python: str,
    output: Path,
    contracts: str,
    openssl: str,
) -> None:
    if output.exists():
        raise FileExistsError("qualification output must be new")
    output.mkdir(mode=0o700, parents=True)
    inputs = []
    for case in ("success", "cancel", "timeout", "server-failure"):
        for name in ("workload.json", "get-result-response.cdr"):
            path = native_cases / case / name
            if (
                path.is_symlink()
                or not path.is_file()
                or path.stat().st_size > 1024 * 1024
            ):
                raise ValueError("bounded regular predicate fixture required")
            inputs.append((path, "fixtures/" + case + "/" + name))
    input_hashes = {path: digest(path) for path, _name in inputs}
    inputs_manifest = output / "qualification-inputs.json"
    document(
        inputs_manifest,
        {
            "scope": "predicate test inputs, not fresh runtime qualification",
            "inputs": [
                {
                    "path": name,
                    "sha256": digest(path),
                    "size_bytes": path.stat().st_size,
                }
                for path, name in inputs
            ],
        },
    )
    installed = output / "installed-wheel-check.log"
    byte_check = (
        "import importlib.metadata as m,zipfile,pathlib,sys,hashlib,json;"
        "d=m.distribution('nav2-turtlebot3-evaluator');"
        "z=zipfile.ZipFile(sys.argv[1]);"
        "names=[n for n in z.namelist() if not n.endswith('/') and not n.endswith('/RECORD')];"
        "assert all(not pathlib.Path(d.locate_file(n)).is_symlink() and pathlib.Path(d.locate_file(n)).read_bytes()==z.read(n) for n in names);"
        "print(json.dumps({'distribution':d.metadata['Name'],'version':d.version,'byte_equal_files':len(names),'wheel_sha256':hashlib.sha256(pathlib.Path(sys.argv[1]).read_bytes()).hexdigest()}))"
    )
    command([python, "-I", "-B", "-c", byte_check, str(wheel.resolve())], installed)
    selected_wheel_sha = digest(wheel)
    controls = output / "qualification-controls.log"
    env = {
        **os.environ,
        "PYTHONDONTWRITEBYTECODE": "1",
        "NAV2_NATIVE_CASES": str(native_cases.resolve()),
    }
    env.pop("PYTHONPATH", None)
    tested = subprocess.run(
        [python, "-I", "-B", str(tests.resolve())],
        env=env,
        capture_output=True,
        timeout=30,
        check=False,
    )
    controls.write_bytes(tested.stdout + tested.stderr)
    if tested.returncode:
        raise RuntimeError("installed evaluator qualification controls refused")
    secrets = output / "private"
    secrets.mkdir(mode=0o700)
    key, public = secrets / "signer.pem", output / "trust-policy.pem"
    try:
        command(
            [openssl, "genpkey", "-algorithm", "ED25519", "-out", str(key)],
            output / "key-generation.log",
        )
        key.chmod(0o600)
        command(
            [openssl, "pkey", "-in", str(key), "-pubout", "-out", str(public)],
            output / "public-key.log",
        )
        descriptor = {
            "uri": wheel.resolve().as_uri(),
            "sha256": digest(wheel),
            "size_bytes": wheel.stat().st_size,
            "media_type": "application/zip",
            "immutable_revision": "sha256:" + digest(wheel),
        }
        producer = "key-sha256:" + digest(public)
        statement = output / "statement.json"
        document(
            statement,
            {
                "_type": "https://in-toto.io/Statement/v1",
                "subject": [{"name": wheel.name, "digest": {"sha256": digest(wheel)}}],
                "predicateType": "urn:nav2-turtlebot3:consumer-evaluator-qualification:v1",
                "predicate": {
                    "artifact": descriptor,
                    "producer": producer,
                    "qualification_controls": {
                        "sha256": digest(controls),
                        "size_bytes": controls.stat().st_size,
                    },
                    "controls_source_sha256": digest(tests),
                    "controls_inputs_sha256": digest(inputs_manifest),
                    "installed_wheel_check_sha256": digest(installed),
                    "scope": "Consumer predicates on original four-case observations and explicit negative controls; no core ROS policy verdict",
                },
            },
        )
        if any(digest(path) != value for path, value in input_hashes.items()):
            raise ValueError("predicate inputs changed during qualification")
        if digest(wheel) != selected_wheel_sha:
            raise ValueError("selected evaluator wheel changed during qualification")
        signature = output / "statement.signature"
        command(
            [
                openssl,
                "pkeyutl",
                "-sign",
                "-rawin",
                "-inkey",
                str(key),
                "-in",
                str(statement),
                "-out",
                str(signature),
            ],
            output / "sign.log",
        )
        proof_log = output / "signature-verification.log"
        command(
            [
                openssl,
                "pkeyutl",
                "-verify",
                "-rawin",
                "-pubin",
                "-inkey",
                str(public),
                "-in",
                str(statement),
                "-sigfile",
                str(signature),
            ],
            proof_log,
        )
        proof = output / "verification-evidence.zip"
        with zipfile.ZipFile(proof, "x", compression=zipfile.ZIP_DEFLATED) as archive:
            for member in (
                signature,
                proof_log,
                controls,
                installed,
                tests,
                inputs_manifest,
            ):
                archive.write(member, member.name)
            for path, name in inputs:
                archive.write(path, name)
        version = (
            subprocess.run(
                [openssl, "version"], capture_output=True, timeout=5, check=True
            )
            .stdout.decode()
            .strip()
        )
        verified_at = datetime.now(timezone.utc).isoformat()
        verification = output / "verification.json"
        document(
            verification,
            {
                "schema_version": "artifact-verification.v1",
                "verification_id": "nav2-evaluator-local-key",
                "statement_sha256": digest(statement),
                "artifact": descriptor,
                "producer_identity": producer,
                "producer_implementation": "nav2-turtlebot3-consumer",
                "trust_policy_sha256": digest(public),
                "verification_evidence_sha256": digest(proof),
                "verifier": {
                    "identity": "urn:nav2-turtlebot3:openssl-local-key-verifier",
                    "implementation": "openssl-ed25519",
                    "version": version,
                },
                "verified_at": verified_at,
                "status": "passed",
            },
        )
        template = output / "receipt-template.json"
        document(
            template,
            {
                "schema_version": "artifact-receipt.v1",
                "receipt_id": "nav2-evaluator-local-key",
                "created_at": datetime.now(timezone.utc).isoformat(),
            },
        )
        command(
            [
                contracts,
                "artifact-receipt",
                "create",
                "--template",
                str(template),
                "--source",
                str(wheel),
                "--verification",
                str(verification),
                "--dependency",
                str(statement),
                "--dependency",
                str(public),
                "--dependency",
                str(proof),
                "--output",
                str(output / "receipt.json"),
            ],
            output / "receipt-create.log",
        )
    finally:
        key.unlink(missing_ok=True)
        secrets.rmdir()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--wheel", type=Path, required=True)
    parser.add_argument("--tests", type=Path, required=True)
    parser.add_argument("--native-cases", type=Path, required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--contracts", required=True)
    parser.add_argument("--openssl", default="openssl")
    args = parser.parse_args()
    qualify(
        args.wheel,
        args.tests,
        args.native_cases,
        args.python,
        args.output,
        args.contracts,
        args.openssl,
    )


if __name__ == "__main__":
    main()
