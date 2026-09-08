#!/usr/bin/env python3
"""Bind internal receipt inputs and render a verified harness input inventory."""

from __future__ import annotations

import argparse
import hashlib
import sys
from pathlib import Path
from typing import Any

from robotics_runtime_contracts import (
    dumps_canonical,
    file_sha256,
    loads_mapping,
    validate_artifact_receipt,
    validate_role,
)
from robotics_runtime_contracts.serialization import (
    MAX_DOCUMENT_BYTES,
    read_document_bytes,
)

GROUPS = ("receipts", "verifications", "dependencies")


def relative_file(path: Path, root: Path, *, exists: bool = True) -> str:
    resolved = path.expanduser().resolve(strict=exists)
    relative = resolved.relative_to(root).as_posix()
    if relative == "." or ":" in relative or "\\" in relative:
        raise ValueError("receipt inputs require portable paths beneath the evidence directory")
    if exists and not resolved.is_file():
        raise ValueError("receipt inputs must be regular files")
    return relative


def read_document(path: Path, role: str | None = None) -> tuple[dict[str, Any], str]:
    raw = read_document_bytes(path)
    document = dict(loads_mapping(raw, source_name=str(path)))
    if role:
        validate_role(document, role)
    return document, hashlib.sha256(raw).hexdigest()


def chain_files(
    receipt_path: Path,
    verification_path: Path,
    dependencies: list[Path],
    root: Path,
) -> tuple[dict[str, Any], dict[str, dict[str, str]]]:
    receipt_name = relative_file(receipt_path, root)
    verification_name = relative_file(verification_path, root)
    dependency_names = [relative_file(path, root) for path in dependencies]
    if "receipt-inventory.json" in [receipt_name, verification_name, *dependency_names]:
        raise ValueError("inventory output must not replace a receipt input")
    receipt, receipt_digest = read_document(root / receipt_name, "artifact_receipt")
    verification, verification_digest = read_document(
        root / verification_name, "artifact_verification"
    )
    if receipt["verification_sha256"] != verification_digest:
        raise ValueError("receipt verification bytes changed")
    dependency_files = {file_sha256(root / name): name for name in dependency_names}
    if len(dependency_files) != len(dependency_names):
        raise ValueError("duplicate provenance dependency bytes")
    required = validate_artifact_receipt(receipt, verification, dependency_files)
    if required != set(dependency_files):
        raise ValueError("unreferenced provenance dependency")
    return receipt, {
        "receipts": {receipt_digest: receipt_name},
        "verifications": {verification_digest: verification_name},
        "dependencies": dependency_files,
    }


def bind(arguments: argparse.Namespace) -> dict[str, Any]:
    root = arguments.root.expanduser().resolve(strict=True)
    registration_path = root / relative_file(arguments.registration, root)
    destination = relative_file(arguments.destination, root, exists=False)
    if destination == "receipt-inventory.json":
        raise ValueError("receipt output must not replace the receipt inventory")
    registration, _ = read_document(registration_path)
    receipt, files = chain_files(
        arguments.receipt, arguments.verification, arguments.dependency, root
    )
    if registration.get("upload_status") != "confirmed" or receipt.get(
        "run_id"
    ) != registration.get("run_id"):
        raise ValueError("receipt inputs require a confirmed registration for the same run")
    digest = next(iter(files["receipts"]))
    files["receipts"][digest] = destination
    registration["receipt_sha256"] = digest
    registration["receipt_inputs"] = {group: list(files[group].values()) for group in GROUPS}
    return registration


def registered_paths(registration: dict[str, Any], root: Path) -> dict[str, list[Path]]:
    inputs = registration.get("receipt_inputs")
    if not isinstance(inputs, dict) or set(inputs) != set(GROUPS):
        raise ValueError("confirmed upload is missing its receipt input registry")
    result = {}
    for group in GROUPS:
        names = inputs[group]
        if not isinstance(names, list) or len(names) > 4096:
            raise ValueError("receipt input registry requires bounded file lists")
        paths = []
        for name in names:
            if not isinstance(name, str) or not name or Path(name).is_absolute():
                raise ValueError("receipt input registry requires relative paths")
            path = root / name
            if relative_file(path, root) != name:
                raise ValueError("receipt input registry requires canonical relative paths")
            paths.append(path)
        result[group] = paths
    if len(result["receipts"]) != 1 or len(result["verifications"]) != 1:
        raise ValueError("registration requires exactly one receipt and verification")
    return result


def inventory(arguments: argparse.Namespace) -> dict[str, list[str]]:
    root = arguments.root.expanduser().resolve(strict=True)
    index, _ = read_document(arguments.index, "evidence_index")
    expected = {
        artifact["receipt_sha256"]
        for artifact in index["artifacts"]
        if artifact["storage_state"] == "retained"
    }
    collected: dict[str, dict[str, str]] = {group: {} for group in GROUPS}
    for raw in read_document_bytes(arguments.registrations).splitlines():
        registration = dict(loads_mapping(raw, source_name="registration.json"))
        if registration.get("upload_status") != "confirmed":
            continue
        paths = registered_paths(registration, root)
        receipt, files = chain_files(
            paths["receipts"][0], paths["verifications"][0], paths["dependencies"], root
        )
        digest = next(iter(files["receipts"]))
        if digest != registration.get("receipt_sha256") or digest not in expected:
            raise ValueError("registered receipt bytes differ from the finalized index")
        if (
            receipt.get("run_id") != index["run_id"]
            or registration.get("run_id") != index["run_id"]
        ):
            raise ValueError("receipt inputs belong to another run")
        for group in GROUPS:
            for sha256, path in files[group].items():
                collected[group].setdefault(sha256, path)
    if set(collected["receipts"]) != expected:
        raise ValueError("finalized index has receipts without registered inputs")
    if sum(len(paths) for paths in collected.values()) > 4096:
        raise ValueError("receipt inventory exceeds 4096 files")
    return {group: sorted(collected[group].values()) for group in GROUPS}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    remember = commands.add_parser("bind")
    for name in ("root", "registration", "receipt", "destination", "verification"):
        remember.add_argument(f"--{name}", type=Path, required=True)
    remember.add_argument("--dependency", type=Path, action="append", required=True)
    collect = commands.add_parser("inventory")
    for name in ("root", "registrations", "index"):
        collect.add_argument(f"--{name}", type=Path, required=True)
    arguments = parser.parse_args()
    try:
        document = bind(arguments) if arguments.command == "bind" else inventory(arguments)
        encoded = dumps_canonical(document)
        if len(encoded) > MAX_DOCUMENT_BYTES:
            raise ValueError("receipt input metadata exceeds the document size limit")
        sys.stdout.buffer.write(encoded)
    except (OSError, ValueError, KeyError) as error:
        print(f"receipt-inputs: {error}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
