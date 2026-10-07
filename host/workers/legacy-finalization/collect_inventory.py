"""Collect the retained legacy inventory; public contract tools own semantic validation."""

from __future__ import annotations

import argparse
import hashlib
import json
import subprocess
import tempfile
from pathlib import Path

import export_retained as copy_worker


def collect(
    plan: dict[str, object],
    *,
    source_arguments: bool = False,
    retained_arguments: list[str] | None = None,
) -> tuple[dict[str, object], list[str]]:
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
        target = str(actual if source_arguments else destination / output)
        arguments.extend([flag, (subject + "=" + target) if subject else target])
        if retained_arguments is not None:
            retained = str(destination / output)
            retained_arguments.extend(
                [flag, (subject + "=" + retained) if subject else retained]
            )
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


def _result(path: Path):
    from robotics_acceptance_harness.documents import load_document_bytes
    from robotics_runtime_contracts.serialization import read_document_bytes

    raw = read_document_bytes(path)
    return load_document_bytes(
        raw, source=path, expected_role="acceptance_result"
    ), len(raw)


def _exit_verdict(exit_code: int, verdict: str) -> None:
    if type(exit_code) is not int or exit_code not in (0, 1):
        raise ValueError("completed assessment requires exit 0 or 1")
    if exit_code != (0 if verdict == "passed" else 1):
        raise ValueError("assessment exit code and canonical verdict disagree")


def _full_validation(arguments: list[str], aggregate: Path, helpers: Path) -> None:
    with tempfile.TemporaryDirectory(prefix="completed-assessment-") as directory:
        subprocess.run(
            [
                str(helpers / "scripts/qualification/create-statement"),
                *arguments,
                "--aggregate",
                str(aggregate),
                "--output",
                str(Path(directory) / "statement.json"),
            ],
            check=True,
        )


def _binding(plan: dict[str, object], flag: str) -> tuple[str, Path]:
    rows = [row for row in plan["bindings"] if row["flag"] == flag]
    if len(rows) != 1:
        raise ValueError("completed legacy assessment requires one " + flag)
    row = rows[0]
    root = Path(str(plan["sourceRoot"])).resolve(strict=True)
    path = copy_worker.inside(root / copy_worker.relative(str(row["source"])), root)
    return str(row.get("subject", "")), path


def _check_payloads(inventory: dict[str, object], root: Path, field: str) -> None:
    for row in inventory["entries"]:
        path = copy_worker.inside(root / copy_worker.relative(row[field]), root)
        with path.open("rb") as stream:
            sha256 = hashlib.file_digest(stream, "sha256").hexdigest()
        if path.stat().st_size != row["size_bytes"] or sha256 != row["sha256"]:
            raise ValueError("payload differs from sealed completed inventory")


def verify_result(
    plan: dict[str, object], exit_code: int, helpers: Path
) -> dict[str, object]:
    from robotics_acceptance_harness.aggregate import aggregate_results

    retained_arguments: list[str] = []
    inventory, arguments = collect(
        plan, source_arguments=True, retained_arguments=retained_arguments
    )
    if sum(row["size_bytes"] for row in inventory["entries"]) > plan["maximumBytes"]:
        raise ValueError("current assessment exceeds admitted export byte bound")
    domain, path = _binding(plan, "--result")
    result, size = _result(path)
    if result.data["run_id"] != plan["runId"] or result.data["domain_id"] != domain:
        raise ValueError("completed result belongs to another admitted run or domain")
    _exit_verdict(exit_code, result.data["status"])
    _, scenario = _binding(plan, "--scenario")
    _, context = _binding(plan, "--acceptance-run")
    with tempfile.TemporaryDirectory(prefix="completed-assessment-") as directory:
        aggregate = aggregate_results(
            scenario_path=scenario,
            run_context_path=context,
            result_paths=[path],
            output_path=Path(directory) / "aggregate.json",
        )
        _full_validation(arguments, aggregate, helpers)
    _check_payloads(
        inventory, Path(str(plan["sourceRoot"])).resolve(strict=True), "source"
    )
    sealed = {"sha256": result.sha256, "size_bytes": size}
    current, current_size = _result(path)
    if {"sha256": current.sha256, "size_bytes": current_size} != sealed:
        raise ValueError("completed result changed during validation")
    return {
        "runId": plan["runId"],
        "domainId": domain,
        "verdict": result.data["status"],
        "observerExitCode": exit_code,
        "result": sealed,
        "resultRelativePath": next(
            row["relativePath"]
            for row in inventory["entries"]
            if row["source"]
            == str(path.relative_to(Path(str(plan["sourceRoot"])).resolve(strict=True)))
        ),
        "inventory": inventory,
        "arguments": retained_arguments,
        "sourceArguments": arguments,
    }


def verify_aggregate(
    arguments: list[str],
    aggregate: Path,
    result_path: Path,
    completed: dict[str, object],
    exit_code: int,
    helpers: Path,
) -> dict[str, object]:
    if (
        not isinstance(arguments, list)
        or len(arguments) > 8192
        or any(not isinstance(value, str) for value in arguments)
    ):
        raise ValueError("invalid retained qualification argument inventory")
    if arguments != completed["arguments"]:
        raise ValueError(
            "qualification arguments differ from sealed completed inventory"
        )
    result, size = _result(result_path)
    if (
        {"sha256": result.sha256, "size_bytes": size} != completed["result"]
        or result.data["run_id"] != completed["runId"]
        or result.data["domain_id"] != completed["domainId"]
        or result.data["status"] != completed["verdict"]
    ):
        raise ValueError("retained result differs from sealed completed assessment")
    _exit_verdict(completed["observerExitCode"], result.data["status"])
    relative_result = copy_worker.relative(completed["resultRelativePath"])
    retained = result_path.absolute()
    for part in relative_result.parts:
        retained = retained.parent
    if retained / relative_result != result_path.absolute():
        raise ValueError("retained result path differs from admitted inventory")
    _check_payloads(completed["inventory"], retained, "relativePath")
    from robotics_acceptance_harness.documents import load_document_bytes
    from robotics_runtime_contracts.serialization import read_document_bytes

    raw = read_document_bytes(aggregate)
    document = load_document_bytes(
        raw, source=aggregate, expected_role="acceptance_aggregate"
    )
    _exit_verdict(exit_code, document.data["per_domain_aggregate"])
    _full_validation(arguments, aggregate, helpers)
    if (
        read_document_bytes(aggregate) != raw
        or _result(result_path)[0].sha256 != result.sha256
    ):
        raise ValueError("retained assessment changed during validation")
    _check_payloads(completed["inventory"], retained, "relativePath")
    return {
        "runId": completed["runId"],
        "verdict": document.data["per_domain_aggregate"],
        "aggregateExitCode": exit_code,
        "aggregate": {"sha256": document.sha256, "size_bytes": len(raw)},
        "result": completed["result"],
    }


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    parser.add_argument("--arguments", type=Path)
    modes = parser.add_mutually_exclusive_group()
    modes.add_argument("--verify-result-exit-code", type=int)
    modes.add_argument("--verify-aggregate-exit-code", type=int)
    parser.add_argument("--aggregate", type=Path)
    parser.add_argument("--result", type=Path)
    parser.add_argument("--completed-result", type=Path)
    parser.add_argument(
        "--helpers", type=Path, default=Path(__file__).resolve().parent.parent
    )
    args = parser.parse_args()
    plan = json.loads(args.plan.read_bytes())
    if args.verify_result_exit_code is not None:
        outputs = [
            (
                args.output,
                verify_result(plan, args.verify_result_exit_code, args.helpers),
            )
        ]
    elif args.verify_aggregate_exit_code is not None:
        if any(
            path is None
            for path in (
                args.arguments,
                args.aggregate,
                args.result,
                args.completed_result,
            )
        ):
            parser.error(
                "aggregate validation requires arguments, aggregate, result and completed-result"
            )
        completed = json.loads(args.completed_result.read_bytes())
        if completed["runId"] != plan["runId"]:
            raise ValueError("completed assessment belongs to another admitted run")
        outputs = [
            (
                args.output,
                verify_aggregate(
                    json.loads(args.arguments.read_bytes()),
                    args.aggregate,
                    args.result,
                    completed,
                    args.verify_aggregate_exit_code,
                    args.helpers,
                ),
            )
        ]
    else:
        if args.arguments is None:
            parser.error("inventory requires --arguments")
        source_arguments = None
        if args.completed_result is None:
            inventory, arguments = collect(plan)
        else:
            arguments = []
            inventory, source_arguments = collect(
                plan, source_arguments=True, retained_arguments=arguments
            )
        outputs = [(args.output, inventory), (args.arguments, arguments)]
        if args.completed_result is not None:
            completed = json.loads(args.completed_result.read_bytes())
            if source_arguments != completed["sourceArguments"]:
                raise ValueError(
                    "current qualification roles differ from validated assessment"
                )
            sealed = completed["inventory"]
            if any(
                inventory[field] != sealed[field]
                for field in ("runId", "sourceRoot", "maximumBytes", "entries")
            ):
                raise ValueError(
                    "current export inventory differs from validated assessment"
                )
            target = Path(str(args.arguments) + ".completed-result.json")
            if target.resolve() == args.completed_result.resolve():
                if arguments != completed["arguments"] or inventory != sealed:
                    raise ValueError(
                        "current qualification arguments differ from validated assessment"
                    )
            else:
                # An issued retry changes its destination; the sealed input closure stays exact.
                outputs.append(
                    (
                        target,
                        {**completed, "inventory": inventory, "arguments": arguments},
                    )
                )
    for target, value in outputs:
        if target.exists():
            raise ValueError("inventory output already exists")
    for target, value in outputs:
        target.parent.mkdir(parents=True, exist_ok=True)
        with target.open("x", encoding="utf-8") as stream:
            stream.write(json.dumps(value, indent=2) + "\n")


if __name__ == "__main__":
    main()
