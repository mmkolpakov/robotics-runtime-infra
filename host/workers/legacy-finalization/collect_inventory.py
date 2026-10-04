"""Collect the retained legacy inventory; public contract tools own semantic validation."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

import export_retained as copy_worker


def collect(plan: dict[str, object]) -> tuple[dict[str, object], list[str]]:
    root = Path(str(plan["sourceRoot"])).resolve(strict=True)
    destination = Path(str(plan["destinationRoot"]))
    bindings = plan["bindings"]
    if not isinstance(bindings, list):
        raise TypeError("admitted qualification bindings required")
    entries = []
    arguments = []
    identities = []
    counter = 0

    def add(flag: str, subject: str, source: str, deduplicate: bool = False) -> None:
        nonlocal counter
        if flag not in (
            "--scenario",
            "--runtime-manifest",
            "--acceptance-run",
            "--result",
            "--evidence-index",
            "--recording-summary",
            "--artifact",
            "--evidence",
        ):
            raise ValueError("unsupported qualification binding")
        rel = copy_worker.relative(source)
        actual = copy_worker.inside(root / rel, root)
        if not actual.is_file() or actual.is_symlink():
            raise ValueError("qualification input is not a regular payload")
        with actual.open("rb") as reader:
            digest = hashlib.file_digest(reader, "sha256").hexdigest()
        size = actual.stat().st_size
        kind = subject.split(":", 1)[0] if ":" in subject else ""
        if deduplicate:
            for previous_kind, previous_digest, previous_size in identities:
                if (
                    previous_digest == digest
                    and previous_size == size
                    and previous_kind
                    in ("recording", "metrics", "junit", "other_evidence")
                    and (kind != "recording" or previous_kind == "recording")
                ):
                    return
        output = "payloads/" + str(rel)
        counter += 1
        entries.append(
            {
                "name": f"payload-{counter}",
                "source": str(rel),
                "relativePath": output,
                "sha256": digest,
                "size_bytes": size,
            }
        )
        target = str(destination / output)
        arguments.extend([flag, (subject + "=" + target) if subject else target])
        identities.append((kind, digest, size))

    for item in bindings:
        if not isinstance(item, dict):
            raise TypeError("binding must be an object")
        add(str(item["flag"]), str(item.get("subject", "")), str(item["source"]))
    subjects = {str(item.get("subject", "")) for item in bindings}
    mandatory = {
        "metrics:metrics.otlp.jsonl",
        "junit:junit.xml",
        "other_evidence:fastdds-profile.xml",
        "other_evidence:host-topology.json",
        "other_evidence:runtime-resources.json",
        "other_evidence:capture/qos-overrides.yaml",
        "other_evidence:capture/mcap-writer.yaml",
        "qualification_profile:providers/profile.json",
        "provider_conformance:providers/conformance.json",
        "other_evidence:providers/configuration.json",
        "other_evidence:providers/observation.json",
        "other_evidence:logs/foundation.log",
        "other_evidence:logs/observer.log",
    }
    if not mandatory.issubset(subjects):
        raise ValueError(
            "required legacy raw/configuration/provider inventory is incomplete"
        )
    if (
        plan.get("dataSource") == "simulator"
        and "other_evidence:providers/world.sdf" not in subjects
    ):
        raise ValueError(
            "simulator source world is missing from the retained inventory"
        )
    if (
        plan.get("dataSource") == "recording_playback"
        and "dataset_manifest:dataset-manifest.json" not in subjects
    ):
        raise ValueError(
            "playback dataset manifest is missing from the retained inventory"
        )
    required = {
        "--scenario",
        "--runtime-manifest",
        "--acceptance-run",
        "--result",
        "--evidence-index",
    }
    if not required.issubset(arguments[::2]):
        raise ValueError("legacy core inputs are incomplete")
    bags = root / copy_worker.relative(str(plan["bagsDirectory"]))
    summaries = root / copy_worker.relative(str(plan["summariesDirectory"]))
    recording_files = sorted(bags.rglob("*.mcap"))
    summary_files = sorted(summaries.glob("*.recording-summary.json"))
    if not summary_files or len(recording_files) != len(summary_files):
        raise ValueError("native MCAP/summary inventory differs")
    for metadata in sorted(bags.rglob("metadata.yaml")):
        rel = metadata.relative_to(root).as_posix()
        subject = metadata.relative_to(bags).as_posix()
        add("--artifact", "other_evidence:capture/bags/" + subject, rel)
    for index, (summary, recording) in enumerate(
        zip(summary_files, recording_files, strict=True)
    ):
        add(
            "--recording-summary",
            f"primary-{index}",
            summary.relative_to(root).as_posix(),
        )
        add(
            "--evidence",
            f"recording:primary-{index}.mcap",
            recording.relative_to(root).as_posix(),
        )
    if plan.get("dataSource") == "recording_playback":
        original = str(plan["playbackSourceSha256"])
        for recording in recording_files:
            with recording.open("rb") as reader:
                if hashlib.file_digest(reader, "sha256").hexdigest() == original:
                    raise ValueError("new observation reused source recording bytes")
        for payload in sorted(
            (root / copy_worker.relative(str(plan["playbackSourceDirectory"]))).rglob(
                "*"
            )
        ):
            if payload.is_file():
                rel = payload.relative_to(root).as_posix()
                add(
                    "--artifact",
                    ("recording:" if payload.suffix == ".mcap" else "other_evidence:")
                    + rel,
                    rel,
                    True,
                )
        for item in plan.get("playbackBindings", []):
            add(str(item["flag"]), str(item["subject"]), str(item["source"]), True)
    elif plan.get("dataSource") != "simulator":
        raise ValueError("unknown admitted data source")
    for item in plan.get("productAndReadinessBindings", []):
        add(str(item["flag"]), str(item["subject"]), str(item["source"]))
    # Unique source/output paths avoid exporting a shared payload twice while preserving its roles.
    unique = {}
    for entry in entries:
        unique.setdefault(entry["relativePath"], entry)
    inventory = {
        "version": 1,
        "runId": plan["runId"],
        "sourceRoot": str(root),
        "destinationRoot": str(destination),
        "maximumBytes": plan["maximumBytes"],
        "entries": list(unique.values()),
    }
    return inventory, arguments


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--arguments", type=Path, required=True)
    args = parser.parse_args()
    inventory, arguments = collect(json.loads(args.plan.read_bytes()))
    for target in (args.output, args.arguments):
        if target.exists():
            raise ValueError("inventory output already exists")
    for target, value in ((args.output, inventory), (args.arguments, arguments)):
        target.parent.mkdir(parents=True, exist_ok=True)
        target.write_text(json.dumps(value, indent=2) + "\n", encoding="utf-8")


if __name__ == "__main__":
    main()
