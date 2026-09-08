"""Use synthetic OTLP bytes to exercise the installed transport contract pipeline."""

from __future__ import annotations

import json
import runpy
import tempfile
import unittest
from copy import deepcopy
from datetime import UTC, datetime
from hashlib import sha256
from pathlib import Path

from robotics_acceptance_harness.aggregate import evaluate_transport_qualification
from robotics_runtime_contracts import validate_document
from robotics_runtime_contracts.writers import (
    add_evidence_artifact,
    create_evidence_index,
    finalize_evidence_index,
    write_document,
)

ROOT = Path(__file__).resolve().parents[2]
PREPARER = ROOT / "test/transport/prepare_qualification.py"
prepare = runpy.run_path(str(PREPARER))["prepare"]
RUN_ID = "run-01234567-89ab-4def-8123-456789abcdef"
TIME_NS = 1_788_868_800_000_000_000  # 2026-09-08T12:00:00Z


def save_json(path: Path, document: object) -> None:
    path.write_text(json.dumps(document), encoding="utf-8")


class TransportQualificationTests(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.directory = Path(self.temporary.name)
        self.configuration_dir = self.directory / "configuration"
        self.configuration_dir.mkdir()
        self.configuration_path = self.configuration_dir / "implementation.json"
        self.configure("ros2.domain_bridge")
        self.observations = {}
        self.traces = {}
        for role in ("source", "destination"):
            destination = role == "destination"
            directory = self.directory / role
            directory.mkdir()
            self.observations[role] = {
                "schema_version": "transport-probe-observation.v1",
                "run_id": RUN_ID,
                "domain_id": f"transport-{role}",
                "role": role,
                "topic": "/robotics/trace_context",
                "message_type": "robotics_observability_msgs/msg/TraceContext",
                "type_hash": "RIHS01_" + "a" * 64,
                "publishers": 1,
                "subscribers": 1,
                "published_count": 0 if destination else 2,
                "received_count": 2 if destination else 0,
                "unique_traceparent_count": 2,
                "matched_tracestate_count": 2,
                "started_at": "2026-09-08T12:00:00Z",
                "finished_at": "2026-09-08T12:00:02Z",
                "clock_identity": {
                    "authority": "shared-linux-kernel-clock-realtime",
                    "boot_id": "01234567-89ab-4def-8123-456789abcdef",
                    "implementation": "clock_gettime(CLOCK_REALTIME)",
                    "resolution_sec": 1e-9,
                },
            }
            save_json(directory / "probe.json", self.observations[role])
            spans = []
            for index in (1, 2):
                span = {
                    "traceId": f"{index:032x}",
                    "spanId": f"{index + (2 if destination else 0):016x}",
                    "name": "robotics.transport.receive"
                    if destination
                    else "robotics.transport.publish",
                    "kind": 5 if destination else 4,
                    "startTimeUnixNano": str(
                        TIME_NS + index * 20_000_000 + (1_000_000 if destination else 0)
                    ),
                    "endTimeUnixNano": str(
                        TIME_NS
                        + index * 20_000_000
                        + (2_000_000 if destination else 100_000)
                    ),
                    "attributes": [
                        {
                            "key": "messaging.message.id",
                            "value": {"stringValue": f"message-{index}"},
                        }
                    ],
                }
                if destination:
                    span["parentSpanId"] = f"{index:016x}"
                spans.append(span)
            self.traces[role] = {
                "resourceSpans": [
                    {
                        "resource": {
                            "attributes": [
                                {"key": "run.id", "value": {"stringValue": RUN_ID}},
                                {
                                    "key": "domain.id",
                                    "value": {"stringValue": f"transport-{role}"},
                                },
                            ]
                        },
                        "scopeSpans": [
                            {
                                "scope": {"name": "transport-unit-fixture"},
                                "spans": spans,
                            }
                        ],
                    }
                ],
            }
            save_json(directory / "traces.otlp.jsonl", self.traces[role])

    def configure(self, implementation: str) -> None:
        native = implementation == "ros2.domain_bridge"
        names = (
            ("domain-bridge.yaml", "udp-only.xml")
            if native
            else ("source.json5", "destination.json5")
        )
        for name in names:
            source = (
                ROOT
                / (
                    "config/fastdds"
                    if name == "udp-only.xml"
                    else "config/transport"
                    if native
                    else "config/zenoh"
                )
                / name
            )
            (self.configuration_dir / name).write_bytes(source.read_bytes())
        version = "0.5.0" if native else "1.9.0"
        (self.configuration_dir / "version.txt").write_text(version, encoding="utf-8")
        self.configuration = {
            "schema_version": "transport-implementation.v1",
            "implementation_id": implementation,
            "version": version,
            "image_config_digest": "sha256:" + "b" * 64,
            "artifacts": [
                {
                    "path": name,
                    "sha256": sha256(
                        (self.configuration_dir / name).read_bytes()
                    ).hexdigest(),
                }
                for name in (*names, "version.txt")
            ],
        }
        save_json(self.configuration_path, self.configuration)

    def evaluate(self) -> dict:
        prepare(self.directory, RUN_ID, 2)
        qualification = self.directory / "qualification"
        paths = [
            self.directory / role / name
            for role in ("source", "destination")
            for name in ("traces.otlp.jsonl", "probe.json")
        ] + [qualification / "shared-clock-identity.json", self.configuration_path]
        paths.extend(
            self.configuration_dir / item["path"]
            for item in self.configuration["artifacts"]
        )
        draft = create_evidence_index(
            {
                "run_id": RUN_ID,
                "generated_at": "2026-09-08T12:00:03Z",
                "policy_observation": {
                    "recording_mode": "bounded",
                    "compression": "zstd",
                    "retention_class": "pull-request-7d",
                    "upload_mode": "local_only",
                    "remote_sink_used": False,
                    "spool_peak_size_bytes": sum(path.stat().st_size for path in paths),
                    "upload_lag_max_sec": 0,
                },
            }
        )
        for index, path in enumerate(paths):
            draft = add_evidence_artifact(
                draft,
                path,
                {
                    "artifact_id": f"artifact-{index}",
                    "kind": "observation",
                    "media_type": "application/x-ndjson"
                    if path.name.endswith("jsonl")
                    else "application/json",
                    "retention_class": "pull-request-7d",
                    "segment_index": index,
                    "storage_state": "local",
                },
            )
        evidence_index = write_document(
            finalize_evidence_index(draft), self.directory / "evidence-index.json"
        )
        output = evaluate_transport_qualification(
            run_id=RUN_ID,
            scenario_path=PREPARER.with_name("scenario.yaml"),
            causal_chain_paths=[qualification / "causal-chain.json"],
            channel_contract_paths=[qualification / "channel.json"],
            clock_relation_paths=[qualification / "clock-relation.json"],
            trace_paths={
                f"transport-{role}": self.directory / role / "traces.otlp.jsonl"
                for role in ("source", "destination")
            },
            evidence_index_paths={
                f"transport-{role}": evidence_index
                for role in ("source", "destination")
            },
            observation_output_dir=qualification / "observations",
            output_path=qualification / "transport-qualification.json",
            generated_at=datetime(2026, 9, 8, 12, 0, 4, tzinfo=UTC),
        )
        document = json.loads(output.read_bytes())
        validate_document(document)
        return document

    def test_both_configurations_use_the_same_real_evaluator(self) -> None:
        for implementation in ("ros2.domain_bridge", "zenoh_bridge_ros2dds"):
            with self.subTest(implementation=implementation):
                self.configure(implementation)
                result = self.evaluate()
                self.assertEqual(result["verdict"]["status"], "passed")
                self.assertEqual(result["verdict"]["passed_chain_count"], 1)
                observation = json.loads(
                    (
                        self.directory
                        / "qualification/observations/transport.trace-context.json"
                    ).read_bytes()
                )
                self.assertEqual(
                    (
                        observation["sent_count"],
                        observation["received_count"],
                        observation["lost_count"],
                    ),
                    (2, 2, 0),
                )
                channel = json.loads(
                    (self.directory / "qualification/channel.json").read_bytes()
                )
                self.assertEqual(
                    channel["implementation_binding"]["configuration_sha256"],
                    sha256(self.configuration_path.read_bytes()).hexdigest(),
                )

    def test_changed_configuration_is_rejected_before_qualification(self) -> None:
        with (self.configuration_dir / "domain-bridge.yaml").open("ab") as stream:
            stream.write(b"\n# changed after startup\n")
        with self.assertRaisesRegex(ValueError, "configuration digest mismatch"):
            prepare(self.directory, RUN_ID, 2)
        self.assertFalse((self.directory / "qualification").exists())

    def test_incomplete_or_duplicate_configuration_inventory_is_rejected(self) -> None:
        original = deepcopy(self.configuration["artifacts"])
        for artifacts in ([], original[:1], [original[0]] * 3):
            with self.subTest(artifacts=artifacts):
                self.configuration["artifacts"] = artifacts
                save_json(self.configuration_path, self.configuration)
                with self.assertRaisesRegex(
                    ValueError, "inventory is incomplete or duplicated"
                ):
                    prepare(self.directory, RUN_ID, 2)

    def test_foreign_clock_and_run_are_rejected(self) -> None:
        original = deepcopy(self.observations["destination"])
        for key, value, message in (
            ("run_id", "run-foreign", "probe field 'run_id'"),
            (
                "clock_identity",
                {**original["clock_identity"], "boot_id": "other-boot"},
                "one Linux realtime clock",
            ),
        ):
            with self.subTest(field=key):
                save_json(
                    self.directory / "destination/probe.json", {**original, key: value}
                )
                with self.assertRaisesRegex(RuntimeError, message):
                    prepare(self.directory, RUN_ID, 2)

    def test_missing_trace_is_not_accepted_as_complete_evidence(self) -> None:
        self.traces["destination"]["resourceSpans"][0]["scopeSpans"][0]["spans"].pop()
        save_json(
            self.directory / "destination/traces.otlp.jsonl", self.traces["destination"]
        )
        with self.assertRaisesRegex(RuntimeError, "contains 1/2"):
            prepare(self.directory, RUN_ID, 2)

    def test_broken_parent_produces_failed_verdict(self) -> None:
        spans = self.traces["destination"]["resourceSpans"][0]["scopeSpans"][0]["spans"]
        spans[0]["parentSpanId"] = "f" * 16
        save_json(
            self.directory / "destination/traces.otlp.jsonl", self.traces["destination"]
        )
        result = self.evaluate()
        self.assertEqual(result["verdict"]["status"], "failed")
        self.assertEqual(result["causal_chains"][0]["status"], "failed")


if __name__ == "__main__":
    unittest.main()
