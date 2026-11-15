"""Assess an archived AAS Gym CPU benchmark using the published SDK."""

import argparse
from datetime import UTC, datetime
from decimal import Decimal
from hashlib import sha256
import json
from pathlib import Path
import re
import subprocess
import sys

from robotics_runtime_contracts import loads_mapping
from robotics_runtime_contracts.writers import (
    add_evidence_artifact,
    create_evidence_index,
    create_runtime_manifest,
    finalize_evidence_index,
    write_document,
)

PROFILE = "org.example.aas.gym.archive"
DOMAIN = "benchmark"
CLOCK = {"kind": "external", "source_id": "system-utc"}
LIMIT = 2 * 1024 * 1024
STEPS = 12500
STEP_CS = 2
SUMMARY = (
    r"Avg Duration:[ ]+([0-9]+\.[0-9]{2})s ± 0\.00s",
    r"Avg Step Time:[ ]+([0-9]+\.[0-9]{3}) ms",
    r"Avg Speedup:[ ]+([0-9]+\.[0-9]{2})x ± 0\.00x wall-clock",
    r"Avg Throughput:[ ]+([0-9]+\.[0-9]{2}) ± 0\.00 steps/second",
)
CRITERIA = {
    "rendered_steps": STEPS,
    "rendered_span_centiseconds": STEPS * STEP_CS,
    "rendered_clock_errors": 0,
    "summary_errors": 0,
}


def read_file(path):
    if not path.is_file():
        raise ValueError(f"missing regular file: {path}")
    with path.open("rb") as source:
        content = source.read(LIMIT + 1)
    if len(content) > LIMIT:
        raise ValueError(f"file exceeds the import limit: {path}")
    return content


def capture_sources(args, capture):
    inputs = {
        "worker.out": capture / "worker.out",
        "native-result.json": capture / "RUN-RESULT.json",
        "review.json": args.review,
        "binding.json": args.binding,
        "authorization.json": args.authorization,
    }
    raw = {name: read_file(path) for name, path in inputs.items()}
    if sha256(raw["review.json"]).hexdigest() != args.review_sha256:
        raise ValueError("review SHA-256 differs from the selected receipt")
    review = loads_mapping(raw["review.json"])
    for name, field in (
        ("worker.out", "stdout_sha256"),
        ("native-result.json", "result_sha256"),
    ):
        if sha256(raw[name]).hexdigest() != review[field]:
            raise ValueError(f"{name} SHA-256 differs from the review")
    result = loads_mapping(raw["native-result.json"])
    authorization = loads_mapping(raw["authorization.json"])
    binding = loads_mapping(raw["binding.json"])
    pilot = result["autopilot"]
    if pilot not in ("px4", "ardupilot"):
        raise ValueError("unsupported AAS benchmark autopilot")
    argv = [
        "--mode",
        "speedup",
        "--num_quads",
        "1",
        "--no-camera",
        "--no-lidar",
        "--autopilot",
        pilot,
        "--no-gpu",
    ]
    binding_sha256 = sha256(raw["binding.json"]).hexdigest()
    if (
        result["argv"] != argv
        or authorization["argv"] != argv
        or binding["cases"][pilot]["argv"] != argv
        or authorization["autopilot"] != pilot
        or authorization["source_commit"] != result["source_commit"]
        or authorization["images"] != result["images"]
        or binding["source_commit"] != result["source_commit"]
        or binding["images"] != result["images"]
        or not re.fullmatch(r"[0-9a-f]{40}", result["source_commit"])
        or result["scope_binding_sha256"] != binding_sha256
        or authorization["binding_sha256"] != binding_sha256
        or result["operator_binding_sha256"]
        != sha256(raw["authorization.json"]).hexdigest()
    ):
        raise ValueError("source, image or benchmark configuration differs")
    images = result["images"]
    if set(images) != {"aircraft", "simulation"} or any(
        not re.fullmatch(r"sha256:[0-9a-f]{64}", image[field])
        for image in images.values()
        for field in ("config", "manifest")
    ):
        raise ValueError("both image config and manifest digests are required")
    if (
        result["state"] != "benchmark-completed-and-owned-inventory-empty"
        or any(
            type(result[key]) is not int or result[key] != 0
            for key in ("worker_exit", "api_exit")
        )
        or result["cleanup_errors"] != []
        or result.get("evidence_errors", [])
    ):
        raise ValueError("the original benchmark and cleanup must be complete")
    started = datetime.fromisoformat(result["started_utc"])
    finished = datetime.fromisoformat(result["completed_utc"])
    if (
        started.utcoffset() != UTC.utcoffset(None)
        or finished.utcoffset() != UTC.utcoffset(None)
        or finished <= started
    ):
        raise ValueError("invalid original benchmark UTC interval")
    return raw, result


def summary_errors(text, retained):
    fields = [
        list(re.finditer(rf"^{pattern}$", text, re.MULTILINE)) for pattern in SUMMARY
    ]
    if any(len(matches) != 1 for matches in fields):
        raise ValueError("missing, malformed or repeated benchmark summary")
    duration, step_ms, speedup, throughput = (
        Decimal(matches[0][1]) for matches in fields
    )
    if min(duration, step_ms, speedup, throughput) <= Decimal("0.005"):
        raise ValueError("benchmark summary values must be positive")
    d = Decimal("0.005")
    ms = Decimal("0.0005")
    nominal = Decimal(STEPS * STEP_CS) / 100
    # Convert each independent display's rounding interval to wall seconds.
    intervals = (
        (duration - d, duration + d),
        ((step_ms - ms) * STEPS / 1000, (step_ms + ms) * STEPS / 1000),
        (nominal / (speedup + d), nominal / (speedup - d)),
        (STEPS / (throughput + d), STEPS / (throughput - d)),
    )
    inconsistent = max(low for low, _ in intervals) > min(high for _, high in intervals)
    recorded = [fields[index][0][0] for index in (0, 2, 3)]
    return int(inconsistent) + int(recorded != retained)


def measure(raw, retained_summary):
    prefix, *segments = raw.decode("utf-8").split("\r")
    header = "Starting speed test: 1 runs of 12500 steps each."
    if prefix.splitlines().count(header) != 1 or not segments:
        raise ValueError("missing single-run benchmark progress")
    last, newline, tail = segments[-1].partition("\n")
    if not newline:
        raise ValueError("truncated benchmark progress or summary")
    segments[-1] = last
    clock = []
    for segment in segments:
        sample = re.fullmatch(
            r"\[[=-]{40}\][ ]+([0-9]{1,3}\.[0-9]{2})s / 300s", segment
        )
        if not sample:
            raise ValueError("malformed rendered benchmark clock")
        clock.append(int(Decimal(sample[1]) * 100))
    return {
        "rendered_steps": len(clock) - 1,
        "rendered_span_centiseconds": clock[-1] - clock[0],
        "rendered_clock_errors": sum(
            value != index * STEP_CS for index, value in enumerate(clock)
        ),
        "summary_errors": summary_errors(tail, retained_summary),
    }


def reference(path, media_type):
    raw = read_file(path)
    return {
        "uri": path.as_uri(),
        "sha256": sha256(raw).hexdigest(),
        "size_bytes": len(raw),
        "media_type": media_type,
    }


def scenario(binding):
    return {
        "schema_version": "acceptance-scenario.v2",
        "scenario_id": PROFILE,
        "execution": {
            "target_environment": "software",
            "data_source": "closed-aas-gym-benchmark",
        },
        "profile": {
            "profile_id": PROFILE,
            "executor": {
                "implementation": PROFILE,
                "version": "1",
                "configuration": binding,
            },
            "channels": [
                {
                    "name": "benchmark-stdout",
                    "original_type": {
                        "name": "AAS Gym speedup text",
                        "codec": {"implementation": "utf-8", "version": "1"},
                    },
                    "backend": "local-file",
                    "wire_envelope": "carriage-return-delimited-text",
                    "native_encoding": "utf-8",
                    "recorder": {
                        "implementation": "stdout-capture",
                        "version": "1",
                        "transformation": "none",
                    },
                }
            ],
            "clock": CLOCK,
            "observations": {
                "import": {"kind": "command_acceptance", "requirement": "required"},
                "imported-files": {
                    "kind": "native_final_state",
                    "requirement": "required",
                },
                "benchmark-consistency": {
                    "kind": "postcondition",
                    "requirement": "required",
                },
            },
        },
        "metric_definitions": [
            {
                "metric_name": f"{PROFILE}.{name}",
                "unit": "1",
                "instrument_kind": "gauge",
                "temporality": "instantaneous",
            }
            for name in CRITERIA
        ],
        "assertions": [
            {
                "assertion_id": name,
                "kind": "metric",
                "metric_name": f"{PROFILE}.{name}",
                "unit": "1",
                "aggregation": "max",
                "operator": "eq",
                "threshold": expected,
                "window_sec": 60,
                "attribute_match": {"native.profile.id": PROFILE},
            }
            for name, expected in CRITERIA.items()
        ],
        "evaluator_requirements": [],
        "evidence_policy": {
            "max_artifact_size_bytes": LIMIT,
            "max_archive_size_bytes": 16 * 1024 * 1024,
            "max_upload_lag_sec": 0,
            "upload_mode": "local_only",
            "retention_class": "pull-request-7d",
            "remote_sink_allowed": False,
        },
    }


def unix_ns(timestamp):
    elapsed = timestamp - datetime(1970, 1, 1, tzinfo=UTC)
    return (
        (elapsed.days * 86400 + elapsed.seconds) * 1_000_000 + elapsed.microseconds
    ) * 1000


def write_metrics(path, values, run_id, observed_at):
    attributes = [
        {"key": key, "value": {"stringValue": value}}
        for key, value in (
            ("run.id", run_id),
            ("domain.id", DOMAIN),
            ("native.profile.id", PROFILE),
        )
    ]
    metrics = [
        {
            "name": f"{PROFILE}.{name}",
            "unit": "1",
            "gauge": {
                "dataPoints": [
                    {
                        "timeUnixNano": str(unix_ns(observed_at)),
                        "asInt": str(value),
                        "attributes": attributes,
                    }
                ]
            },
        }
        for name, value in values.items()
    ]
    path.write_text(
        json.dumps(
            {
                "resourceMetrics": [
                    {"scopeMetrics": [{"scope": {"name": PROFILE}, "metrics": metrics}]}
                ],
            }
        )
        + "\n",
        encoding="utf-8",
    )


def evidence_index(output, run_id, paths):
    draft = create_evidence_index(
        {
            "schema_version": "evidence-index.v1",
            "run_id": run_id,
            "generated_at": datetime.now(UTC).isoformat(),
            "policy_observation": {
                "recording_mode": "native-files",
                "compression": "none",
                "retention_class": "pull-request-7d",
                "upload_mode": "local_only",
                "remote_sink_used": False,
                "upload_lag_max_sec": 0,
                "spool_peak_size_bytes": sum(
                    path.stat().st_size for path, _, _ in paths
                ),
            },
        }
    )
    for path, kind, media in paths:
        draft = add_evidence_artifact(
            draft,
            path,
            {
                "artifact_id": path.stem,
                "kind": kind,
                "media_type": media,
                "retention_class": "pull-request-7d",
                "storage_state": "local",
            },
        )
    return write_document(
        finalize_evidence_index(draft), output / "evidence-index.json"
    )


def assess(args):
    capture = args.capture.resolve(strict=True)
    output = args.output.resolve()
    if output.is_relative_to(capture):
        raise ValueError("output must be outside the source capture")
    raw, original = capture_sources(args, capture)
    output.mkdir(mode=0o700)
    raw_dir = output / "raw"
    raw_dir.mkdir(mode=0o700)
    raw_paths = []
    for name, content in raw.items():
        path = raw_dir / name
        path.write_bytes(content)
        raw_paths.append(
            (
                path,
                "other_evidence",
                "text/plain" if name == "worker.out" else "application/json",
            )
        )

    config = scenario(reference(raw_dir / "binding.json", "application/json"))
    scenario_path = write_document(config, output / "scenario.json")
    run_path = output / "run.json"
    cli = [
        sys.executable,
        "-I",
        "-B",
        str(Path(sys.executable).with_name("robotics-acceptance")),
    ]
    created = subprocess.run(
        [
            *cli,
            "create-run",
            "--scenario",
            str(scenario_path),
            "--output",
            str(run_path),
            "--domain",
            f"{DOMAIN}=primary",
            "--time-authority",
            CLOCK["kind"],
            "--time-source",
            CLOCK["source_id"],
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    if created.returncode != 0:
        raise ValueError(created.stderr.strip() or "SDK could not create a run")
    run_id = loads_mapping(read_file(run_path))["run_id"]
    scenario_sha256 = reference(scenario_path, "application/json")["sha256"]
    runtime_path = write_document(
        create_runtime_manifest(
            {
                "schema_version": "runtime-manifest.v2",
                "runtime_id": "aas-gym-archive",
                "generated_at": datetime.now(UTC).isoformat(),
                "scenario_sha256": scenario_sha256,
                "execution": config["execution"],
                "profile": config["profile"],
                "evaluator_bindings": [],
            }
        ),
        output / "runtime.json",
    )

    started = datetime.now(UTC)
    values = measure(raw["worker.out"], original["benchmark_summary"])
    metrics_path = output / "metrics.jsonl"
    write_metrics(metrics_path, values, run_id, datetime.now(UTC))
    finished = datetime.now(UTC)
    stdout_ref = reference(raw_dir / "worker.out", "text/plain")
    review_ref = reference(raw_dir / "review.json", "application/json")
    observation_path = write_document(
        {
            "schema_version": "acceptance-observation.v2",
            "observation_id": "aas-gym-archive",
            "run_id": run_id,
            "scenario_id": PROFILE,
            "domain_id": DOMAIN,
            "scenario_sha256": scenario_sha256,
            "runtime_manifest_sha256": reference(runtime_path, "application/json")[
                "sha256"
            ],
            "started_at": started.isoformat(),
            "finished_at": finished.isoformat(),
            "measurement_window": {
                "start_ns": unix_ns(started),
                "end_ns": unix_ns(finished),
                "clock": CLOCK,
                "timestamp_encoding": "unix_ns",
            },
            "observations": {
                "import": {"state": "measured", "value": True, "evidence": review_ref},
                "imported-files": {
                    "state": "measured",
                    "evidence": review_ref,
                    "value": {
                        "sha256": {
                            name: sha256(content).hexdigest()
                            for name, content in raw.items()
                        },
                        "original_benchmark": {
                            key: original[key]
                            for key in (
                                "autopilot",
                                "source_commit",
                                "started_utc",
                                "completed_utc",
                                "state",
                            )
                        },
                    },
                },
                "benchmark-consistency": {
                    "state": "measured",
                    "value": values,
                    "evidence": stdout_ref,
                },
            },
            "evidence": [
                *(reference(path, media) for path, _, media in raw_paths),
                reference(metrics_path, "application/x-ndjson"),
            ],
        },
        output / "observation.json",
    )
    index_path = evidence_index(
        output,
        run_id,
        [
            *raw_paths,
            (metrics_path, "metrics", "application/x-ndjson"),
            (observation_path, "acceptance_observation", "application/json"),
        ],
    )
    assessment = output / "assessment"
    evaluated = subprocess.run(
        [
            *cli,
            "evaluate",
            "--scenario",
            str(scenario_path),
            "--runtime",
            str(runtime_path),
            "--run-id",
            run_id,
            "--domain-id",
            DOMAIN,
            "--run-context",
            str(run_path),
            "--evidence-index",
            str(index_path),
            "--otel-metrics",
            str(metrics_path),
            "--window-start-ns",
            str(unix_ns(started)),
            "--window-end-ns",
            str(unix_ns(finished)),
            "--output",
            str(assessment),
        ],
        capture_output=True,
        text=True,
        check=False,
        timeout=60,
    )
    result = assessment / "acceptance-result.json"
    if evaluated.returncode not in (0, 1) or not result.is_file():
        raise ValueError(
            evaluated.stderr.strip() or "SDK assessment did not write a result"
        )
    print(
        json.dumps(
            {"run_id": run_id, "result": str(result), "evidence_index": str(index_path)}
        )
    )
    return evaluated.returncode


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    for flag in ("--capture", "--binding", "--authorization", "--review", "--output"):
        parser.add_argument(flag, type=Path, required=True)
    parser.add_argument("--review-sha256", required=True)
    try:
        return assess(parser.parse_args(argv))
    except (
        OSError,
        ValueError,
        KeyError,
        TypeError,
        subprocess.SubprocessError,
    ) as error:
        print(f"AAS archive: {error}", file=sys.stderr)
        return 2


if __name__ == "__main__":
    raise SystemExit(main())
