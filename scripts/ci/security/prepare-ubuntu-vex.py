#!/usr/bin/env python3
"""Project the pinned Canonical records onto one observed Ubuntu package PURL."""

import argparse
import copy
from datetime import datetime, timezone
import hashlib
from importlib.metadata import version
import json
from pathlib import Path
import shlex
import uuid

from packageurl import PackageURL


def digest(data):
    return hashlib.sha256(data).hexdigest()


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--vendor-dir", type=Path, required=True)
    parser.add_argument("--source-commit", required=True)
    parser.add_argument("--scan-report", type=Path, required=True)
    parser.add_argument("--os-release", type=Path, required=True)
    parser.add_argument("--package-purl", required=True)
    parser.add_argument("--output-dir", type=Path, required=True)
    args = parser.parse_args()
    pin_path = (
        Path(__file__).resolve().parents[3] / "security/vex/canonical-source.json"
    )
    pin_bytes = pin_path.read_bytes()
    pin = json.loads(pin_bytes)
    if args.source_commit != pin["source_commit"]:
        raise ValueError("supplier revision is not the reviewed source pin")
    report_bytes = args.scan_report.read_bytes()
    report = json.loads(report_bytes)
    os_bytes = args.os_release.read_bytes()
    fields = {}
    for token in shlex.split(os_bytes.decode(), comments=True):
        key, value = token.split("=", 1)
        if key in fields:
            raise ValueError("duplicate os-release key")
        fields[key] = value
    if any(
        fields.get(k) != v
        for k, v in {
            "ID": "ubuntu",
            "VERSION_ID": "24.04",
            "VERSION_CODENAME": "noble",
        }.items()
    ):
        raise ValueError("only observed Ubuntu 24.04 noble is supported")
    if report.get("SchemaVersion") != 2 or report["Metadata"]["OS"] != {
        "Family": "ubuntu",
        "Name": "24.04",
    }:
        raise ValueError("scan OS does not match os-release")
    observed = PackageURL.from_string(args.package_purl)
    if (
        observed.to_string() != args.package_purl
        or observed.type != "deb"
        or observed.namespace != "ubuntu"
        or observed.name != "linux-libc-dev"
        or not observed.version
        or observed.subpath
        or observed.qualifiers.get("arch") not in ("amd64", "arm64")
        or observed.qualifiers.get("distro") != "ubuntu-24.04"
    ):
        raise ValueError("unsupported observed package identity")
    packages = [
        p
        for result in report.get("Results", [])
        for p in result.get("Packages", [])
        if p.get("Identifier", {}).get("PURL") == args.package_purl
    ]
    if len(packages) != 1 or packages[0].get("Arch") != observed.qualifiers["arch"]:
        raise ValueError("package must occur exactly once in the observed report")
    supplier_purl = PackageURL(
        **{
            **observed.to_dict(),
            "qualifiers": {**observed.qualifiers, "distro": "noble"},
        }
    )
    statements, sources, raw_files = [], [], {}
    for entry in pin["files"]:
        raw = (args.vendor_dir / entry["name"]).read_bytes()
        if digest(raw) != entry["sha256"]:
            raise ValueError("supplier bytes do not match the reviewed pin")
        vendor = json.loads(raw)
        if (
            vendor["@context"] != "https://openvex.dev/ns/v0.2.0"
            or vendor["author"] != "Canonical Ltd."
        ):
            raise ValueError("unexpected supplier document")
        matches = []
        for statement in vendor["statements"]:
            products = []
            for product in statement["products"]:
                purl = PackageURL.from_string(product["@id"])
                if purl == supplier_purl:
                    if set(product) != {"@id"}:
                        raise ValueError("unsupported supplier product structure")
                    products.append({"@id": observed.to_string()})
            if products:
                selected = copy.deepcopy(statement)
                selected["products"] = products
                matches.append(selected)
        if len(matches) != 1:
            raise ValueError("supplier package binding is missing or ambiguous")
        statements.extend(matches)
        raw_files["raw/" + entry["name"]] = raw
        sources.append(
            {
                **entry,
                "document_id": vendor["@id"],
                "document_version": vendor["version"],
                "timestamp": vendor["timestamp"],
                "url": "https://raw.githubusercontent.com/canonical/ubuntu-security-notices/"
                + pin["source_commit"]
                + "/vex/cve/"
                + entry["name"][4:8]
                + "/"
                + entry["name"],
            }
        )
    binding = {
        "mapping": {"from": "noble", "to": "ubuntu-24.04", "version": 1},
        "source_commit": pin["source_commit"],
        "source_pin_sha256": digest(pin_bytes),
        "sources": sources,
        "supplier_purl": supplier_purl.to_string(),
        "observed_purl": observed.to_string(),
        "scan_report_sha256": digest(report_bytes),
        "os_release_sha256": digest(os_bytes),
        "artifact_name": report["ArtifactName"],
        "metadata": report["Metadata"],
    }
    identity = str(uuid.uuid5(uuid.NAMESPACE_URL, json.dumps(binding, sort_keys=True)))
    derived = {
        "@context": "https://openvex.dev/ns/v0.2.0",
        "@id": "urn:uuid:" + identity,
        "author": "mmkolpakov",
        "timestamp": datetime.now(timezone.utc).isoformat(),
        "version": 1,
        "statements": statements,
    }
    derived_bytes = (json.dumps(derived, indent=2) + "\n").encode()
    receipt = {
        **binding,
        "author": "mmkolpakov",
        "tool": {
            "source_sha256": digest(Path(__file__).read_bytes()),
            "packageurl-python": version("packageurl-python"),
        },
        "derived": {
            "file": "canonical-ubuntu.openvex.json",
            "sha256": digest(derived_bytes),
            "id": derived["@id"],
        },
    }
    files = {
        **raw_files,
        "canonical-ubuntu.openvex.json": derived_bytes,
        "provenance.json": (json.dumps(receipt, indent=2) + "\n").encode(),
    }
    args.output_dir.mkdir(parents=True, exist_ok=False)
    for name, data in files.items():
        target = args.output_dir / name
        target.parent.mkdir(exist_ok=True)
        target.write_bytes(data)
    (args.output_dir / "SHA256SUMS").write_text(
        "".join(
            digest(data) + "  " + name + "\n" for name, data in sorted(files.items())
        )
    )


if __name__ == "__main__":
    main()
