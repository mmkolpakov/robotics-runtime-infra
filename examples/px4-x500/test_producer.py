"""Installed SDK synthetic controls; no native flight or composition is qualified."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from pathlib import Path
from unittest.mock import patch

from robotics_acceptance_harness.evidence import VerifiedEvidence

ROOT = Path(__file__).parent
SPEC = importlib.util.spec_from_file_location("px4_producer", ROOT / "producer.py")
PRODUCER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PRODUCER)
RUN = "run-11111111-2222-4333-8444-555555555555"


def write(path, value):
    path.write_text(json.dumps(value))
    return path


def inputs(root, case="land"):
    profile = json.loads((ROOT / "native-profile.json").read_bytes())
    path = write(root / "profile.json", profile)
    prepared = root / "archive/inputs"
    supplied = os.environ.get("PX4_EVALUATOR_BINDING")
    binding = (
        Path(supplied)
        if supplied
        else write(
            root / "binding.json",
            {
                "namespace": PRODUCER.PROFILE,
                "entry_point": "px4_x500_evaluator:evaluate",
                "distribution": "px4-x500-evaluator",
                "version": "0.3.1",
                "artifact_sha256": "a" * 64,
                "receipt_sha256": "b" * 64,
            },
        )
    )
    manifest = PRODUCER.prepare(path, case, prepared, binding_path=binding, run_id=RUN)
    return prepared, manifest


def capture(prepared, case="land", *, ascent=1.5, missing_ground=False, cleanup=True):
    directory = prepared.parent / "capture"
    directory.mkdir()
    base = 1700000000000000000
    rows = []

    def record(kind, value):
        number = len(rows)
        value = {
            "run_id": RUN,
            "domain_id": "px4",
            "sequence": number,
            "kind": kind,
            "receiver_unix_ns": str(base + (number + 1) * 1000000),
            "receiver_monotonic_ms": (number + 1) * 1.0,
            "value": value,
        }
        path = write(directory / (str(number).zfill(4) + "-" + kind + ".json"), value)
        raw = path.read_bytes()
        rows.append(
            {
                "path": path.name,
                "kind": kind,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": len(raw),
            }
        )

    if case != "unarmed-refusal":
        record("action-issued", {"method": "takeoff"})
        record(
            "action-takeoff",
            {
                "monotonic_ms": 1,
                "value": {"action_result": {"result": "RESULT_SUCCESS"}},
            },
        )
    for altitude in (0, 0.05, 0.1, 0.05) if case == "unarmed-refusal" else (0, ascent):
        record(
            "telemetry-position",
            {"value": {"position": {"relative_altitude_m": altitude}}},
        )
    if case != "unarmed-refusal":
        record("action-issued", {"method": "land"})
        record(
            "action-land", {"value": {"action_result": {"result": "RESULT_SUCCESS"}}}
        )
    if not missing_ground:
        record(
            "telemetry-landed", {"value": {"landed_state": "LANDED_STATE_ON_GROUND"}}
        )
    record("telemetry-armed", {"value": {"is_armed": False}})
    outcome = {"case": case}
    if case == "unarmed-refusal":
        outcome.update(
            {
                "observed": "caller-refused-unarmed",
                "refusal": {
                    "method": "takeoff",
                    "boundary": "caller-precondition",
                    "reason": "unarmed",
                },
            }
        )
    record("controller-result", {"complete": True, "outcome": outcome})
    end = base + (len(rows) + 2) * 1000000
    manifest = {
        "run_id": RUN,
        "domain_id": "px4",
        "clock_source": PRODUCER.CLOCK["source_id"],
        "started_unix_ns": str(base),
        "finished_unix_ns": str(end),
        "complete": True,
        "records": rows,
        "total_bytes": sum(row["size_bytes"] for row in rows),
    }
    write(directory / "controller-manifest.json", manifest)
    if cleanup:
        write(
            directory / "engine-cleanup.json",
            {
                "owner_id": RUN,
                "released": True,
                "observed": {"containers": [], "networks": []},
                "clock_source": PRODUCER.CLOCK["source_id"],
                "receiver_unix_ns": str(end - 1000000),
            },
        )
    return directory


def rewrite_capture(folder, transform):
    """Synthetic record edits preserve the journal's actual byte links/order."""
    manifest_path = folder / "controller-manifest.json"
    manifest = json.loads(manifest_path.read_bytes())
    records = [
        json.loads((folder / entry["path"]).read_bytes())
        for entry in manifest["records"]
    ]
    transform(records)
    base = int(manifest["started_unix_ns"])
    rows = []
    for number, record in enumerate(records):
        record.update(
            sequence=number,
            receiver_unix_ns=str(base + (number + 1) * 1000000),
            receiver_monotonic_ms=(number + 1) * 1.0,
        )
        path = write(
            folder / (str(number).zfill(4) + "-" + record["kind"] + ".json"), record
        )
        raw = path.read_bytes()
        rows.append(
            {
                "path": path.name,
                "kind": record["kind"],
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": len(raw),
            }
        )
    manifest.update(
        records=rows,
        total_bytes=sum(row["size_bytes"] for row in rows),
        finished_unix_ns=str(base + (len(rows) + 2) * 1000000),
    )
    write(manifest_path, manifest)


def incomplete_controller(records):
    for record in records:
        if record["kind"] == "controller-result":
            record["value"] = {"complete": False, "error": "interrupted"}


def initial_state_only(records):
    states = [
        record
        for record in records
        if record["kind"] in ("telemetry-landed", "telemetry-armed")
    ]
    records[:] = states + [record for record in records if record not in states]


def action_result(value):
    def transform(records):
        for record in records:
            if record["kind"] == "action-takeoff":
                record["value"]["value"]["action_result"]["result"] = value

    return transform


class PublicRunIssuanceControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.invoke = subprocess.run

    def test_installed_cli_issues_the_bound_run_without_native_startup(self):
        prepared, manifest = inputs(self.root)
        run = json.loads((prepared / "run.json").read_bytes())
        self.assertEqual(run["run_id"], RUN)
        self.assertEqual(run["scenario_sha256"], manifest["scenario"]["sha256"])
        self.assertEqual(run["domains"], [{"domain_id": "px4", "role": "simulation"}])
        self.assertEqual(run["time_authority"], PRODUCER.CLOCK)

    def test_cli_uses_read_only_snapshot_and_refuses_changed_source(self):
        def changed(arguments, **options):
            snapshot = Path(arguments[arguments.index("--scenario") + 1])
            self.assertEqual(snapshot.stat().st_mode & 0o777, 0o400)
            self.assertEqual(snapshot.parent.stat().st_mode & 0o777, 0o700)
            original = self.root / "archive/inputs/scenario.json"
            self.assertNotEqual(snapshot, original)
            result = self.invoke(arguments, **options)
            document = json.loads(original.read_bytes())
            document["scenario_id"] += "-changed"
            write(original, document)
            return result

        with (
            patch.object(PRODUCER.subprocess, "run", side_effect=changed) as command,
            self.assertRaisesRegex(ValueError, "prepared PX4 inputs"),
        ):
            inputs(self.root)
        self.assertEqual(command.call_count, 1)
        self.assertFalse((self.root / "archive/inputs/pre-run-inputs.json").exists())

    def test_each_run_binding_is_checked_after_actual_cli(self):
        mutations = {
            "run": lambda r: r.update(run_id="run-foreign"),
            "scenario": lambda r: r.update(scenario_id="foreign"),
            "digest": lambda r: r.update(scenario_sha256="f" * 64),
            "domain": lambda r: r.update(
                domains=[{"domain_id": "foreign", "role": "simulation"}]
            ),
            "role": lambda r: r.update(
                domains=[{"domain_id": "px4", "role": "measurement"}]
            ),
            "clock": lambda r: r.update(
                time_authority={"kind": "external", "source_id": "foreign"}
            ),
        }
        for name, mutate in mutations.items():
            with self.subTest(binding=name):
                (self.root / name).mkdir()

                def altered(arguments, mutate=mutate, **options):
                    result = self.invoke(arguments, **options)
                    output = Path(arguments[arguments.index("--output") + 1])
                    document = json.loads(output.read_bytes())
                    mutate(document)
                    write(output, document)
                    return result

                with (
                    patch.object(PRODUCER.subprocess, "run", side_effect=altered),
                    self.assertRaises(ValueError),
                ):
                    inputs(self.root / name)

    def test_lost_acknowledgement_does_not_retry_or_remove_created_run(self):
        def lost(arguments, **options):
            result = self.invoke(arguments, **options)
            self.assertEqual(result.returncode, 0)
            options["stderr"].write(b"acknowledgement lost")
            return subprocess.CompletedProcess(arguments, 2)

        with (
            patch.object(PRODUCER.subprocess, "run", side_effect=lost) as command,
            self.assertRaisesRegex(ValueError, "acknowledgement lost"),
        ):
            inputs(self.root)
        self.assertEqual(command.call_count, 1)
        self.assertTrue((self.root / "archive/inputs/run.json").is_file())
        self.assertFalse((self.root / "archive/inputs/pre-run-inputs.json").exists())

    def test_wrong_empty_or_oversized_stdout_is_not_a_run_acknowledgement(self):
        for name, payload in [
            ("wrong", b"run-foreign\n"),
            ("empty", b""),
            ("oversized", b"x" * 4097),
        ]:
            with self.subTest(output=name):
                (self.root / name).mkdir()

                def altered(arguments, payload=payload, **options):
                    result = self.invoke(arguments, **options)
                    options["stdout"].seek(0)
                    options["stdout"].truncate()
                    options["stdout"].write(payload)
                    return result

                with (
                    patch.object(
                        PRODUCER.subprocess, "run", side_effect=altered
                    ) as command,
                    self.assertRaisesRegex(ValueError, "different run identity"),
                ):
                    inputs(self.root / name)
                self.assertEqual(command.call_count, 1)

    def test_failure_diagnostic_is_bounded_and_stdout_is_not_disclosed(self):
        def refused(arguments, **options):
            options["stdout"].write(b"PRIVATE-STDOUT")
            options["stderr"].write(b"reason-" + b"x" * 5000)
            return subprocess.CompletedProcess(arguments, 2)

        with (
            patch.object(PRODUCER.subprocess, "run", side_effect=refused),
            self.assertRaises(ValueError) as caught,
        ):
            inputs(self.root)
        message = str(caught.exception)
        self.assertIn("exit 2", message)
        self.assertIn("reason-", message)
        self.assertIn("[diagnostic truncated]", message)
        self.assertNotIn("PRIVATE-STDOUT", message)
        self.assertLess(len(message), 4300)

    def test_missing_cli_and_timeout_have_no_fallback_or_retry(self):
        for name, error in [
            ("missing", FileNotFoundError("CLI unavailable")),
            ("timeout", subprocess.TimeoutExpired("robotics-acceptance", 30)),
        ]:
            with self.subTest(failure=name):
                (self.root / name).mkdir()
                with (
                    patch.object(
                        PRODUCER.subprocess, "run", side_effect=error
                    ) as command,
                    self.assertRaises(type(error)),
                ):
                    inputs(self.root / name)
                self.assertEqual(command.call_count, 1)
                self.assertFalse(
                    (self.root / name / "archive/inputs/pre-run-inputs.json").exists()
                )

    def test_existing_output_is_refused_by_the_installed_cli(self):
        prepared, _manifest = inputs(self.root)
        output = prepared / "run.json"
        before = output.read_bytes()
        with self.assertRaisesRegex(ValueError, "create-run failed"):
            PRODUCER.create_run(prepared / "scenario.json", output, RUN)
        self.assertEqual(output.read_bytes(), before)


class ProducerControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.admission = os.environ.get("PX4_ADMISSION")

    def assess(
        self,
        *,
        ascent=1.5,
        missing_ground=False,
        cleanup=True,
        case="land",
        transform=None,
        operator_profile=None,
        include_trust=True,
    ):
        if not self.admission:
            self.skipTest(
                "actual external wheel authentication/receipt fixture required"
            )
        prepared, _manifest = inputs(self.root, case)
        folder = capture(
            prepared,
            case,
            ascent=ascent,
            missing_ground=missing_ground,
            cleanup=cleanup,
        )
        if transform:
            transform(folder)
        before = {path: path.read_bytes() for path in prepared.iterdir()}
        result = PRODUCER.complete(prepared, folder)
        arguments = [
            str(Path(sys.executable).parent / "robotics-acceptance"),
            "evaluate",
        ]
        for key, value in result.items():
            arguments += ["--" + key.replace("_", "-"), str(value)]
        output = self.root / "assessment"
        arguments += ["--output", str(output)]
        admission = Path(self.admission)
        if include_trust:
            arguments += [
                "--evaluator-trust-profile",
                str(operator_profile or admission / "operator-profile.json"),
            ]
        for flag, name in (
            ("--evaluator-receipt", "receipt.json"),
            ("--evaluator-verification", "verification.json"),
        ):
            arguments += [flag, str(admission / name)]
        for name in ("statement.json", "publisher.json", "verified-report.txt"):
            arguments += ["--evaluator-receipt-dependency", str(admission / name)]
        environment = os.environ.copy()
        environment.pop("PYTHONPATH", None)
        environment.pop("PYTHONHOME", None)
        completed = subprocess.run(
            arguments,
            env=environment,
            stdin=subprocess.DEVNULL,
            capture_output=True,
            text=True,
            timeout=30,
            check=False,
        )
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        return completed, output

    def test_oversized_and_mismatched_record_refuse_before_writer(self):
        for oversized in (False, True):
            with (
                self.subTest(oversized=oversized),
                tempfile.TemporaryDirectory() as temporary,
            ):
                prepared, _manifest = inputs(Path(temporary))
                folder = capture(prepared)
                manifest = json.loads(
                    (folder / "controller-manifest.json").read_bytes()
                )
                path = folder / manifest["records"][0]["path"]
                path.write_bytes(
                    b"x" * (PRODUCER.LIMIT + 1)
                    if oversized
                    else path.read_bytes() + b"x"
                )
                with patch.object(PRODUCER, "add_evidence_artifact") as writer:
                    with self.assertRaises(ValueError):
                        PRODUCER.complete(prepared, folder)
                    writer.assert_not_called()
                self.assertFalse((prepared.parent / "source-records").exists())
                self.assertFalse((prepared.parent / "evidence-index.json").exists())

    def test_cleanup_symlink_refuses_before_writer(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = folder / "engine-cleanup.json"
        other = self.root / "outside.json"
        path.rename(other)
        path.symlink_to(other)
        with patch.object(PRODUCER, "add_evidence_artifact") as writer:
            with self.assertRaisesRegex(ValueError, "symlink"):
                PRODUCER.complete(prepared, folder)
            writer.assert_not_called()

    def test_receipt_documents_without_external_authentication_refuse_loading(self):
        result, _output = self.assess(include_trust=False)
        self.assertEqual(result.returncode, 2)
        self.assertIn("requires authenticated wheel/source admission", result.stderr)

    def test_genuine_signature_with_wrong_external_publisher_key_refuses(self):
        if not self.admission:
            self.skipTest("actual stock Cosign publisher fixture required")
        admission = Path(self.admission)
        profile = json.loads((admission / "operator-profile.json").read_bytes())
        wrong_key = admission / "other.pub"
        digest = hashlib.sha256(wrong_key.read_bytes()).hexdigest()
        profile["verifier"].update(public_key=str(wrong_key), public_key_sha256=digest)
        profile["evaluators"][0]["publisher"]["public_key_sha256"] = digest
        path = write(self.root / "other-operator-profile.json", profile)
        path.chmod(0o400)
        result, _output = self.assess(operator_profile=path)
        self.assertEqual(result.returncode, 2)
        self.assertIn("Cosign", result.stderr)

    def test_pre_run_documents_exist_before_capture_and_are_not_rewritten(self):
        prepared, manifest = inputs(self.root)
        before = {path: path.read_bytes() for path in prepared.iterdir()}
        self.assertFalse((prepared.parent / "observation.json").exists())
        folder = capture(prepared)
        result = PRODUCER.complete(prepared, folder)
        self.assertEqual(before, {path: path.read_bytes() for path in before})
        observation = json.loads((prepared.parent / "observation.json").read_bytes())
        self.assertEqual(
            observation["runtime_manifest_sha256"], manifest["runtime"]["sha256"]
        )
        self.assertEqual(result["run_id"], RUN)

    def test_each_original_payload_is_parsed_from_one_verified_snapshot(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        original = VerifiedEvidence.read_local
        reads = []

        def read(evidence, path, **keywords):
            raw = original(evidence, path, **keywords)
            reads.append(path)
            return raw

        with patch.object(VerifiedEvidence, "read_local", read):
            PRODUCER.complete(prepared, folder)
        self.assertEqual(len(reads), len(set(reads)))
        self.assertEqual(
            len(reads),
            len(
                json.loads((folder / "controller-manifest.json").read_bytes())[
                    "records"
                ]
            )
            + 1,
        )

    def test_sdk_observations_do_not_invent_otlp_instrumentation(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = folder / "engine-cleanup.json"
        facts = json.loads(path.read_bytes())
        del facts["receiver_unix_ns"]
        write(path, facts)
        PRODUCER.complete(prepared, folder)
        self.assertFalse((prepared.parent / "metrics.jsonl").exists())

    def test_foreign_cleanup_owner_refuses(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = folder / "engine-cleanup.json"
        facts = json.loads(path.read_bytes())
        facts["owner_id"] = "foreign"
        write(path, facts)
        with self.assertRaisesRegex(ValueError, "another native owner"):
            PRODUCER.complete(prepared, folder)

    def test_manifest_complete_requires_json_boolean_true(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = folder / "controller-manifest.json"
        document = json.loads(path.read_bytes())
        document["complete"] = 1
        write(path, document)
        with patch.object(PRODUCER, "add_evidence_artifact") as writer:
            with self.assertRaisesRegex(ValueError, "closed manifest"):
                PRODUCER.complete(prepared, folder)
            writer.assert_not_called()

    def test_changed_pre_run_input_refuses_before_completed_outputs(self):
        prepared, _manifest = inputs(self.root)
        folder = capture(prepared)
        path = prepared / "runtime.json"
        path.write_bytes(path.read_bytes() + b"\n")
        with self.assertRaisesRegex(ValueError, "pre-run input bytes changed"):
            PRODUCER.complete(prepared, folder)
        self.assertFalse((prepared.parent / "evidence-index.json").exists())

    def test_versioned_method_does_not_promote_receiver_samples_to_ulog_facts(self):
        prepared, _ = inputs(self.root)
        folder = capture(prepared)
        PRODUCER.complete(prepared, folder)
        observation = json.loads((prepared.parent / "observation.json").read_bytes())
        self.assertEqual(
            observation["observations"]["postcondition"]["state"], "unobserved"
        )
        self.assertEqual(
            json.loads((prepared / "configuration.json").read_bytes())[
                "measurement_method"
            ],
            "px4-valid-home-sampled-v0.2",
        )

    def test_installed_public_evaluate_keeps_missing_native_chain_incomplete(self):
        completed, output = self.assess()
        self.assertEqual(completed.returncode, 1, completed.stderr)
        self.assertEqual(json.loads(completed.stdout)["status"], "incomplete")
        result = json.loads((output / "acceptance-result.json").read_bytes())
        self.assertEqual(result["schema_version"], "acceptance-result.v2")
        self.assertTrue(ET.parse(output / "junit.xml").findall(".//skipped"))

    def test_installed_public_evaluate_consumes_original_chain_with_stock_decoder(self):
        from test_ulog_custody import native_case

        completed, output = self.assess(transform=lambda folder: native_case(folder))
        self.assertEqual(completed.returncode, 1, completed.stderr)
        result = json.loads((output / "acceptance-result.json").read_bytes())
        self.assertEqual(result["status"], "incomplete")
        rows = {
            row["assertion_id"]: row
            for row in result["assertion_results"]
            if row["source"] == "product"
        }
        postcondition = rows[PRODUCER.PROFILE + ".postcondition"]
        self.assertEqual(postcondition["status"], "skipped")
        self.assertIn("stock ULog decoding", postcondition.get("message", ""))

    def test_native_original_uri_is_registered_unchanged(self):
        prepared, _ = inputs(self.root)
        folder = capture(prepared)
        payload = folder / "native.ulg"
        payload.write_bytes(b"opaque original retained ULog")
        raw = payload.read_bytes()
        ref = {
            "uri": payload.as_uri(),
            "sha256": hashlib.sha256(raw).hexdigest(),
            "size_bytes": len(raw),
            "media_type": "application/octet-stream",
        }
        binding = {
            "run_id": RUN,
            "domain_id": "px4",
            "kind": "native-evidence",
            "value": {"ulog": ref, "custody": {}},
        }
        write(folder / "native-evidence.json", binding)
        PRODUCER.complete(prepared, folder)
        index = json.loads((prepared.parent / "evidence-index.json").read_bytes())
        registered = [
            v
            for v in index["artifacts"]
            if v["artifact_id"].startswith("native-")
            and v["artifact_id"] != "native-binding"
        ]
        self.assertEqual(len(registered), 1)
        self.assertEqual({k: registered[0][k] for k in ref}, ref)
        self.assertEqual(payload.read_bytes(), raw)

    def test_original_parent_facts_are_registered_without_rewriting_their_uri(self):
        prepared, _ = inputs(self.root)
        folder = capture(prepared)
        parent = prepared.parent / "parent-facts"
        parent.mkdir()
        actor = write(parent / "actor.json", {"owner_id": RUN})
        raw = actor.read_bytes()
        ref = {
            "uri": actor.as_uri(),
            "sha256": hashlib.sha256(raw).hexdigest(),
            "size_bytes": len(raw),
            "media_type": "application/json",
        }
        write(
            folder / "native-evidence.json",
            {
                "run_id": RUN,
                "domain_id": "px4",
                "kind": "native-evidence",
                "value": {"custody": {"actor_before": ref}},
            },
        )
        PRODUCER.complete(prepared, folder)
        index = json.loads((prepared.parent / "evidence-index.json").read_bytes())
        self.assertEqual(
            len(
                [
                    v
                    for v in index["artifacts"]
                    if all(v.get(k) == value for k, value in ref.items())
                ]
            ),
            1,
        )
        self.assertEqual(actor.read_bytes(), raw)

    def test_ulog_cannot_escape_capture_via_parent_facts_and_inputs_are_not_parent_facts(
        self,
    ):
        for role in ("ulog-parent", "actor-inputs"):
            with self.subTest(role=role), tempfile.TemporaryDirectory() as directory:
                prepared, _ = inputs(Path(directory))
                folder = capture(prepared)
                if role == "ulog-parent":
                    parent = prepared.parent / "parent-facts"
                    parent.mkdir()
                    payload = parent / "source.ulg"
                    payload.write_bytes(b"source")
                else:
                    payload = prepared / "configuration.json"
                raw = payload.read_bytes()
                ref = {
                    "uri": payload.as_uri(),
                    "sha256": hashlib.sha256(raw).hexdigest(),
                    "size_bytes": len(raw),
                    "media_type": "application/json",
                }
                value = (
                    {"ulog": ref, "custody": {}}
                    if role == "ulog-parent"
                    else {"custody": {"actor_before": ref}}
                )
                write(
                    folder / "native-evidence.json",
                    {
                        "run_id": RUN,
                        "domain_id": "px4",
                        "kind": "native-evidence",
                        "value": value,
                    },
                )
                with patch.object(PRODUCER, "add_evidence_artifact") as writer:
                    with self.assertRaisesRegex(ValueError, "fixed retained roots"):
                        PRODUCER.complete(prepared, folder)
                    writer.assert_not_called()

    def test_native_original_tamper_symlink_and_foreign_uri_refuse(self):
        for mode in ("tamper", "symlink", "foreign"):
            with self.subTest(mode=mode), tempfile.TemporaryDirectory() as temporary:
                prepared, _ = inputs(Path(temporary))
                folder = capture(prepared)
                payload = folder / "native.ulg"
                payload.write_bytes(b"native")
                ref = {
                    "uri": payload.as_uri(),
                    "sha256": hashlib.sha256(b"native").hexdigest(),
                    "size_bytes": 6,
                    "media_type": "application/octet-stream",
                }
                if mode == "tamper":
                    payload.write_bytes(b"changed")
                else:
                    outside = prepared.parent / "outside.ulg"
                    payload.rename(outside)
                    if mode == "symlink":
                        payload.symlink_to(outside)
                    else:
                        ref["uri"] = outside.as_uri()
                write(
                    folder / "native-evidence.json",
                    {
                        "run_id": RUN,
                        "domain_id": "px4",
                        "kind": "native-evidence",
                        "value": {"ulog": ref, "custody": {}},
                    },
                )
                with patch.object(PRODUCER, "add_evidence_artifact") as writer:
                    with self.assertRaises(ValueError):
                        PRODUCER.complete(prepared, folder)
                    writer.assert_not_called()


if __name__ == "__main__":
    unittest.main()
