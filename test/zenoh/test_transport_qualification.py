from __future__ import annotations

import importlib.util
import json
from datetime import UTC, datetime, timedelta
from pathlib import Path
from types import ModuleType
from typing import Any

from google.protobuf.json_format import MessageToJson
from opentelemetry.proto.collector.trace.v1.trace_service_pb2 import (
    ExportTraceServiceRequest,
)
from opentelemetry.proto.common.v1.common_pb2 import (
    AnyValue,
    InstrumentationScope,
    KeyValue,
)
from opentelemetry.proto.resource.v1.resource_pb2 import Resource
from opentelemetry.proto.trace.v1.trace_pb2 import ResourceSpans, ScopeSpans, Span
from robotics_acceptance_harness.aggregate import evaluate_transport_qualification
from robotics_acceptance_harness.traces import (
    evaluate_channel_delivery,
    load_otlp_json_traces,
)

RUN_ID = "run-01234567-89ab-4def-8123-456789abcdef"
TYPE_HASH = f"RIHS01_{'a' * 64}"
SOURCE_DOMAIN = "zenoh-source"
DESTINATION_DOMAIN = "zenoh-destination"
PRODUCER_SPAN = "robotics.zenoh.publish"
CONSUMER_SPAN = "robotics.zenoh.receive"
MESSAGE_COUNT = 20
REPOSITORY_ROOT = Path(__file__).resolve().parents[2]


def test_runner_owns_an_isolated_compose_project() -> None:
    runner = (REPOSITORY_ROOT / "test" / "zenoh" / "run").read_text(encoding="utf-8")
    compose = (REPOSITORY_ROOT / "compose.zenoh.yaml").read_text(encoding="utf-8")

    assert "COMPOSE_PROJECT_NAME" not in runner
    assert (
        'readonly project_name="robotics-zenoh-'
        '${GITHUB_RUN_ID:-$$}-${GITHUB_RUN_ATTEMPT:-0}-${RANDOM}"'
    ) in runner
    assert 'readonly report_dir="${report_root}/${project_name}"' in runner
    assert '"${compose[@]}" down --volumes --timeout 10' in runner
    assert "--remove-orphans" not in runner
    assert "rm -rf" not in runner
    assert "robotics-acceptance transport-evaluate" in compose
    assert "runtime-manifest" not in compose
    assert "acceptance-run" not in compose
    assert "aggregate-v1" not in compose
    assert "channel-observation.jq" not in runner
    assert "channel-observation.jq" not in compose


def _key_value(key: str, value: str) -> KeyValue:
    return KeyValue(key=key, value=AnyValue(string_value=value))


def _write_otlp_trace(
    path: Path,
    *,
    domain_id: str,
    span_name: str,
    consumer: bool,
    start_time_ns: int,
) -> None:
    spans: list[Span] = []
    for index in range(MESSAGE_COUNT):
        trace_id = (index + 1).to_bytes(16, "big")
        producer_span_id = (1000 + index).to_bytes(8, "big")
        span_id = (2000 + index).to_bytes(8, "big") if consumer else producer_span_id
        span_start_ns = (
            start_time_ns + index * 10_000_000 + (2_000_000 if consumer else 0)
        )
        spans.append(
            Span(
                trace_id=trace_id,
                span_id=span_id,
                parent_span_id=producer_span_id if consumer else b"",
                trace_state="runtime=zenoh",
                name=span_name,
                kind=(Span.SPAN_KIND_CONSUMER if consumer else Span.SPAN_KIND_PRODUCER),
                start_time_unix_nano=span_start_ns,
                end_time_unix_nano=span_start_ns + 1_000_000,
                attributes=[
                    _key_value(
                        "messaging.message.id",
                        f"zenoh-{index + 1:032x}",
                    ),
                    _key_value("messaging.system", "zenoh"),
                ],
            )
        )
    request = ExportTraceServiceRequest(
        resource_spans=[
            ResourceSpans(
                resource=Resource(
                    attributes=[
                        _key_value("run.id", RUN_ID),
                        _key_value("domain.id", domain_id),
                    ]
                ),
                scope_spans=[
                    ScopeSpans(
                        scope=InstrumentationScope(name="robotics.zenoh.qualification"),
                        spans=spans,
                    )
                ],
            )
        ]
    )
    document = json.loads(
        MessageToJson(
            request,
            preserving_proto_field_name=False,
            indent=None,
        )
    )
    encoded_spans = document["resourceSpans"][0]["scopeSpans"][0]["spans"]
    for encoded, span in zip(encoded_spans, spans, strict=True):
        # OTLP/JSON represents trace and span identifiers as lower-case hex.
        encoded["traceId"] = span.trace_id.hex()
        encoded["spanId"] = span.span_id.hex()
        if span.parent_span_id:
            encoded["parentSpanId"] = span.parent_span_id.hex()
    path.write_text(json.dumps(document) + "\n", encoding="utf-8")


def _write_probe(
    path: Path,
    *,
    domain_id: str,
    role: str,
    started_at: datetime,
    first_message_at_ns: int,
) -> None:
    finished_at = started_at + timedelta(seconds=1)
    path.write_text(
        json.dumps(
            {
                "schema_version": "zenoh-probe-observation.v1",
                "run_id": RUN_ID,
                "domain_id": domain_id,
                "role": role,
                "started_at": started_at.isoformat().replace("+00:00", "Z"),
                "finished_at": finished_at.isoformat().replace("+00:00", "Z"),
                "topic": "/robotics/trace_context",
                "message_type": ("robotics_observability_msgs/msg/TraceContext"),
                "type_hash": TYPE_HASH,
                "publishers": 1,
                "subscribers": 1,
                "published_count": MESSAGE_COUNT if role == "source" else 0,
                "received_count": MESSAGE_COUNT if role == "destination" else 0,
                "unique_traceparent_count": MESSAGE_COUNT,
                "matched_tracestate_count": MESSAGE_COUNT,
                "first_message_at_ns": first_message_at_ns,
            }
        )
        + "\n",
        encoding="utf-8",
    )


def _load_prepare_module() -> ModuleType:
    path = REPOSITORY_ROOT / "test" / "zenoh" / "prepare_qualification.py"
    specification = importlib.util.spec_from_file_location(
        "zenoh_prepare_qualification",
        path,
    )
    if specification is None or specification.loader is None:
        raise RuntimeError(f"cannot load {path}")
    module = importlib.util.module_from_spec(specification)
    specification.loader.exec_module(module)
    return module


def _evaluate(report_dir: Path, output_name: str, observation_dir: str) -> Path:
    qualification = report_dir / "qualification"
    output = qualification / output_name
    evaluate_transport_qualification(
        run_id=RUN_ID,
        causal_chain_paths=[qualification / "causal-chain.json"],
        channel_contract_paths=[qualification / "channel.json"],
        trace_paths={
            SOURCE_DOMAIN: report_dir / "source" / "traces.otlp.jsonl",
            DESTINATION_DOMAIN: (report_dir / "destination" / "traces.otlp.jsonl"),
        },
        evidence_index_paths={
            SOURCE_DOMAIN: qualification / "source-evidence-index.json",
            DESTINATION_DOMAIN: qualification / "destination-evidence-index.json",
        },
        observation_output_dir=qualification / observation_dir,
        output_path=output,
    )
    return output


def test_canonical_transport_qualification_is_strict(
    tmp_path: Path,
    monkeypatch: Any,
) -> None:
    config_dir = tmp_path / "config"
    report_dir = tmp_path / "reports"
    qualification = report_dir / "qualification"
    config_dir.mkdir()
    for directory in (
        report_dir / "source",
        report_dir / "destination",
        qualification / "observations",
    ):
        directory.mkdir(parents=True)
    for name in ("source.json5", "destination.json5"):
        source = REPOSITORY_ROOT / "config" / "zenoh" / name
        (config_dir / name).write_bytes(source.read_bytes())

    started_at = datetime.now(UTC)
    start_time_ns = int(started_at.timestamp() * 1_000_000_000)
    _write_otlp_trace(
        report_dir / "source" / "traces.otlp.jsonl",
        domain_id=SOURCE_DOMAIN,
        span_name=PRODUCER_SPAN,
        consumer=False,
        start_time_ns=start_time_ns,
    )
    _write_otlp_trace(
        report_dir / "destination" / "traces.otlp.jsonl",
        domain_id=DESTINATION_DOMAIN,
        span_name=CONSUMER_SPAN,
        consumer=True,
        start_time_ns=start_time_ns,
    )
    _write_probe(
        report_dir / "source" / "probe.json",
        domain_id=SOURCE_DOMAIN,
        role="source",
        started_at=started_at,
        first_message_at_ns=start_time_ns,
    )
    _write_probe(
        report_dir / "destination" / "probe.json",
        domain_id=DESTINATION_DOMAIN,
        role="destination",
        started_at=started_at,
        first_message_at_ns=start_time_ns,
    )
    monkeypatch.setenv("ROBOTICS_RUN_ID", RUN_ID)
    monkeypatch.setenv("ROBOTICS_ZENOH_REPORT_DIR", str(report_dir))
    monkeypatch.setenv("ROBOTICS_ZENOH_CONFIG_DIR", str(config_dir))
    monkeypatch.setenv("ROBOTICS_MESSAGE_COUNT", str(MESSAGE_COUNT))
    prepare = _load_prepare_module()
    prepare.main()

    output = _evaluate(report_dir, "transport-qualification.json", "observations")
    result = json.loads(output.read_text(encoding="utf-8"))
    observation = json.loads(
        (qualification / "observations" / "zenoh.trace-context.json").read_text(
            encoding="utf-8"
        )
    )
    assert result["schema_version"] == "transport-qualification-result.v1"
    assert result["run_id"] == RUN_ID
    assert result["verdict"]["status"] == "passed"
    assert result["causal_chains"][0]["status"] == "passed"
    assert "per_domain_results" not in result
    assert "scenario_id" not in result
    assert "runtime_manifest_sha256" not in result
    assert observation["sent_count"] == MESSAGE_COUNT
    assert observation["received_count"] == MESSAGE_COUNT
    assert observation["lost_count"] == 0
    assert observation["loss_ratio"] == 0

    destination_trace = report_dir / "destination" / "traces.otlp.jsonl"
    trace = json.loads(destination_trace.read_text(encoding="utf-8"))
    trace["resourceSpans"][0]["scopeSpans"][0]["spans"].pop()
    destination_trace.write_text(
        json.dumps(trace) + "\n",
        encoding="utf-8",
    )
    prepare.write_evidence_index(
        path=qualification / "destination-evidence-index.json",
        run_id=RUN_ID,
        generated_at=datetime.now(UTC),
        trace_path=destination_trace,
        observation_path=report_dir / "destination" / "probe.json",
    )
    channel = json.loads((qualification / "channel.json").read_text(encoding="utf-8"))
    loss_evaluation = evaluate_channel_delivery(
        channel,
        {
            SOURCE_DOMAIN: load_otlp_json_traces(
                report_dir / "source" / "traces.otlp.jsonl",
                expected_run_id=RUN_ID,
                expected_domain_id=SOURCE_DOMAIN,
            ),
            DESTINATION_DOMAIN: load_otlp_json_traces(
                destination_trace,
                expected_run_id=RUN_ID,
                expected_domain_id=DESTINATION_DOMAIN,
            ),
        },
    )
    assert loss_evaluation.status == "failed"
    assert loss_evaluation.sent_count == MESSAGE_COUNT
    assert loss_evaluation.received_count == MESSAGE_COUNT - 1
    assert loss_evaluation.lost_count == 1
    assert loss_evaluation.loss_ratio > 0
    assert [item.code for item in loss_evaluation.violations] == ["loss_ratio_exceeded"]

    failed_output = _evaluate(
        report_dir,
        "transport-qualification-loss.json",
        "observations-loss",
    )
    failed_result = json.loads(failed_output.read_text(encoding="utf-8"))
    failed_observation = json.loads(
        (qualification / "observations-loss" / "zenoh.trace-context.json").read_text(
            encoding="utf-8"
        )
    )
    assert failed_result["verdict"]["status"] == "failed"
    assert failed_observation["status"] == "failed"
    assert failed_observation["received_count"] == MESSAGE_COUNT - 1
    assert [item["code"] for item in failed_observation["violations"]] == [
        "loss_ratio_exceeded"
    ]
    assert all("channel_id" not in item for item in failed_observation["violations"])
