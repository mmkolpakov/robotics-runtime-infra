"""Finite worker checks. Qualification uses repository fixtures, not a live-run PASS claim."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

WORKERS = Path("/opt/robotics/finalizer/workers")

sys.path.insert(0, str(WORKERS))
import collect_inventory  # noqa: E402 - the installed worker directory is selected above
import export_retained  # noqa: E402 - the installed worker directory is selected above

HELPERS = Path("/opt/robotics/finalizer")
FIXTURES = Path("/source/test/qualification/fixtures")


def digest(path: Path) -> str:
    return hashlib.sha256(path.read_bytes()).hexdigest()


class ByteExport(unittest.TestCase):
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        self.source.mkdir()
        (self.source / "opaque.json").write_bytes(
            b'{ "dsseEnvelope": {"payload":"eyBcInhcIjoxfQ=="} }\n'
        )
        (self.source / "raw.bin").write_bytes(bytes(range(256)) * 4096)
        self.plan = {
            "version": 1,
            "runId": "byte-export-fixture",
            "sourceRoot": str(self.source),
            "destinationRoot": str(self.root / "retained"),
            "maximumBytes": 8 * 1024**2,
            "entries": [
                {
                    "name": p.name,
                    "source": p.name,
                    "relativePath": p.name,
                    "sha256": digest(p),
                    "size_bytes": p.stat().st_size,
                }
                for p in sorted(self.source.iterdir())
            ],
        }

    def test_source_removed_after_complete_bytes(self) -> None:
        original = {p.name: p.read_bytes() for p in self.source.iterdir()}
        result = export_retained.export(self.plan)
        self.assertEqual(result["status"], "complete")
        shutil.rmtree(self.source)
        for name, raw in original.items():
            self.assertEqual((self.root / "retained" / name).read_bytes(), raw)

    def test_expected_hash_failure_retains_source_and_partial_diagnostic(self) -> None:
        before = {p.name: digest(p) for p in self.source.iterdir()}
        self.plan["entries"][-1]["sha256"] = "0" * 64
        with self.assertRaises(ValueError):
            export_retained.export(self.plan)
        self.assertEqual(before, {p.name: digest(p) for p in self.source.iterdir()})
        self.assertTrue((self.root / "retained/export-incomplete.json").exists())
        self.assertFalse((self.root / "retained/export-manifest.json").exists())
        # Explicit new attempt succeeds while preserving the failed attempt and source.
        self.plan["destinationRoot"] = str(self.root / "retained-retry")
        self.plan["entries"][-1]["sha256"] = digest(
            self.source / self.plan["entries"][-1]["source"]
        )
        retried = export_retained.export(self.plan)
        self.assertEqual(retried["status"], "complete")
        self.assertEqual(before, {p.name: digest(p) for p in self.source.iterdir()})
        self.assertTrue((self.root / "retained/export-incomplete.json").exists())

    def test_no_overwrite_or_source_alias(self) -> None:
        export_retained.export(self.plan)
        before = digest(self.root / "retained/opaque.json")
        with self.assertRaises(FileExistsError):
            export_retained.export(self.plan)
        self.assertEqual(before, digest(self.root / "retained/opaque.json"))
        self.plan["destinationRoot"] = str(self.source / "nested")
        with self.assertRaises(ValueError):
            export_retained.export(self.plan)

    def test_links_duplicate_and_byte_bound_refuse_before_copy(self) -> None:
        (self.source / "raw.bin").unlink()
        (self.source / "raw.bin").symlink_to(self.source / "opaque.json")
        with self.assertRaises(ValueError):
            export_retained.export(self.plan)
        self.assertFalse((self.root / "retained").exists())
        (self.source / "raw.bin").unlink()
        (self.source / "raw.bin").write_bytes(b"x")
        self.plan["entries"] = [self.plan["entries"][0], dict(self.plan["entries"][0])]
        with self.assertRaises(ValueError):
            export_retained.export(self.plan)
        self.plan["entries"] = [self.plan["entries"][0]]
        self.plan["maximumBytes"] = 1
        with self.assertRaises(ValueError):
            export_retained.export(self.plan)


class Inventory(unittest.TestCase):
    def test_complete_inventory_and_recording_negatives(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source"
            shutil.copytree(FIXTURES, source)
            (source / "bags").mkdir()
            shutil.copyfile(
                source / "recording-0.mcap", source / "bags/recording-0.mcap"
            )
            (source / "summaries").mkdir()
            shutil.copyfile(
                source / "recording-summary.json",
                source / "summaries/0.recording-summary.json",
            )
            core = [
                ("--scenario", "", "acceptance-scenario.yaml"),
                ("--runtime-manifest", "primary", "runtime-manifest.json"),
                ("--acceptance-run", "", "acceptance-run.json"),
                ("--result", "primary", "acceptance-result.json"),
                ("--evidence-index", "primary", "evidence-index.json"),
            ]
            subjects = [
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
                "other_evidence:providers/configuration.json",
                "other_evidence:providers/observation.json",
                "other_evidence:logs/foundation.log",
                "other_evidence:logs/observer.log",
                "other_evidence:providers/world.sdf",
            ]
            bindings = [
                {"flag": flag, "subject": subject, "source": path}
                for flag, subject, path in core
            ]
            for index, subject in enumerate(subjects):
                path = "inventory-fixture-" + str(index)
                (source / path).write_bytes(b"opaque inventory fixture\n")
                bindings.append(
                    {"flag": "--artifact", "subject": subject, "source": path}
                )
            plan = {
                "sourceRoot": str(source),
                "destinationRoot": str(root / "retained"),
                "runId": "inventory-fixture",
                "maximumBytes": 64 * 1024**2,
                "bindings": bindings,
                "dataSource": "simulator",
                "bagsDirectory": "bags",
                "summariesDirectory": "summaries",
            }
            inventory, arguments = collect_inventory.collect(plan)
            self.assertIn("--recording-summary", arguments)
            self.assertTrue(
                any(v.startswith("recording:primary-0.mcap=") for v in arguments)
            )
            for entry in inventory["entries"]:
                self.assertEqual(entry["sha256"], digest(source / entry["source"]))
            saved = plan["bindings"]
            plan["bindings"] = bindings[:-1]
            with self.assertRaises(ValueError):
                collect_inventory.collect(plan)
            plan["bindings"] = saved
            (source / "bags/recording-1.mcap").write_bytes(b"unmatched")
            with self.assertRaises(ValueError):
                collect_inventory.collect(plan)
            (source / "bags/recording-1.mcap").unlink()
            plan["dataSource"] = "recording_playback"
            bindings.append(
                {
                    "flag": "--artifact",
                    "subject": "dataset_manifest:dataset-manifest.json",
                    "source": "runtime-manifest.json",
                }
            )
            plan["playbackSourceSha256"] = digest(source / "bags/recording-0.mcap")
            with self.assertRaises(ValueError):
                collect_inventory.collect(plan)


class PublicQualification(unittest.TestCase):
    def portable(
        self,
        root: Path,
        retained: Path,
        args: list[str],
        recording_sha256: str,
        *,
        aggregate: Path | None = None,
    ) -> None:
        package = root / "portable"

        def run(
            command: list[str], cwd: Path = root, expected_exit: int = 0
        ) -> subprocess.CompletedProcess[str]:
            result = subprocess.run(
                command,
                cwd=cwd,
                capture_output=True,
                text=True,
                timeout=45,
                check=False,
            )
            self.assertEqual(
                result.returncode, expected_exit, result.stdout + result.stderr
            )
            return result

        if aggregate is None:
            derived = retained / "derived-aggregate.json"
            run(
                [
                    "/opt/contracts/bin/robotics-acceptance",
                    "aggregate",
                    "--scenario",
                    str(retained / "acceptance-scenario.yaml"),
                    "--run-context",
                    str(retained / "acceptance-run.json"),
                    "--result",
                    str(retained / "acceptance-result.json"),
                    "--output",
                    str(derived),
                ]
            )
        else:
            derived = aggregate
            args += ["--aggregate", str(derived)]
        for index in range(1, len(args), 2):
            if args[index].startswith("acceptance_aggregate:"):
                args[index] = args[index].split("=", 1)[0] + "=" + str(derived)
        run(
            [
                str(HELPERS / "scripts/qualification/package-artifacts"),
                "--output",
                str(package),
                *args,
            ]
        )
        statement, bundle, key = (
            retained / "statement.json",
            retained / "bundle.json",
            retained / "public.key",
        )
        run(
            [
                str(HELPERS / "scripts/qualification/create-statement"),
                *args,
                "--output",
                str(statement),
            ]
        )
        run(
            [
                "bash",
                str(HELPERS / "scripts/ci/foundation/sign-ephemeral-qualification.sh"),
                str(statement),
                str(bundle),
                str(key),
            ]
        )
        for path in (statement, bundle, key):
            shutil.copyfile(path, package / path.name)
        portable = (package / "qualification-arguments.txt").read_text().splitlines()
        shutil.rmtree(retained)
        verified = run(
            [
                str(HELPERS / "scripts/qualification/verify-bundle"),
                *portable,
                "--bundle",
                "bundle.json",
                "--key",
                "public.key",
            ],
            package,
        )
        self.assertIn("qualification bundle verified", verified.stdout)
        recording_spec = next(v for v in portable[1::2] if v.startswith("recording:"))
        copied = package / recording_spec.split("=", 1)[1]
        self.assertEqual(recording_sha256, digest(copied))
        raw = copied.read_bytes()
        copied.chmod(0o640)
        copied.write_bytes(raw + b"tamper")
        rejected = subprocess.run(
            [
                str(HELPERS / "scripts/qualification/verify-bundle"),
                *portable,
                "--bundle",
                "bundle.json",
                "--key",
                "public.key",
            ],
            cwd=package,
            capture_output=True,
            timeout=45,
            check=False,
        )
        self.assertNotEqual(rejected.returncode, 0)

    def test_existing_helpers_portable_after_raw_teardown(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source, retained = root / "producer", root / "retained"
            shutil.copytree(FIXTURES, source)
            specs = json.loads((source / "single-artifacts.json").read_bytes())[
                "artifacts"
            ]
            names = sorted({s["file"] for s in specs})
            plan = {
                "version": 1,
                "runId": "repository-qualification-fixture",
                "sourceRoot": str(source),
                "destinationRoot": str(retained),
                "maximumBytes": 64 * 1024**2,
                "entries": [
                    {
                        "name": name,
                        "source": name,
                        "relativePath": name,
                        "sha256": digest(source / name),
                        "size_bytes": (source / name).stat().st_size,
                    }
                    for name in names
                ],
            }
            export_retained.export(plan)
            expected = {name: digest(retained / name) for name in names}
            shutil.rmtree(source)
            args = []
            for spec in specs:
                args += [
                    "--artifact",
                    spec["kind"]
                    + ":"
                    + spec["subject_name"]
                    + "="
                    + str(retained / spec["file"]),
                ]
            self.portable(root, retained, args, expected["recording-0.mcap"])


class CompletedAssessment(unittest.TestCase):
    # Repository unit fixtures only; no native cleanup or performance proof.
    def setUp(self) -> None:
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.source = self.root / "source"
        shutil.copytree(FIXTURES, self.source)
        self.retained = self.root / "retained"
        self.original = json.loads(
            (self.source / "acceptance-result.json").read_bytes()
        )
        self.result_path = self.source / "acceptance-result.json"
        self.bindings = [
            {"flag": "--scenario", "source": "acceptance-scenario.yaml"},
            {
                "flag": "--runtime-manifest",
                "subject": "primary",
                "source": "runtime-manifest.json",
            },
            {"flag": "--acceptance-run", "source": "acceptance-run.json"},
            {
                "flag": "--result",
                "subject": "primary",
                "source": "acceptance-result.json",
            },
            {
                "flag": "--evidence-index",
                "subject": "primary",
                "source": "evidence-index.json",
            },
        ]
        specs = json.loads((self.source / "single-artifacts.json").read_bytes())[
            "artifacts"
        ]
        excluded = {
            "scenario",
            "runtime_manifest",
            "acceptance_run",
            "domain_result",
            "acceptance_aggregate",
            "evidence_index",
            "recording",
            "recording_summary",
        }
        for spec in specs:
            if (
                spec["kind"] not in excluded
                and spec["kind"] != "metrics"
                and spec["file"] != "fastdds-profile.xml"
            ):
                self.bindings.append(
                    {
                        "flag": "--artifact",
                        "subject": spec["kind"] + ":" + spec["subject_name"],
                        "source": spec["file"],
                    }
                )
        selected = {
            "metrics:metrics.otlp.jsonl": "metrics.otlp.jsonl",
            "other_evidence:fastdds-profile.xml": "fastdds-profile.xml",
            "qualification_profile:providers/profile.json": "provider-profile.json",
            "provider_conformance:providers/conformance.json": "provider-conformance.json",
        }
        opaque = (
            "junit:junit.xml",
            "other_evidence:host-topology.json",
            "other_evidence:runtime-resources.json",
            "other_evidence:capture/qos-overrides.yaml",
            "other_evidence:capture/mcap-writer.yaml",
            "other_evidence:providers/configuration.json",
            "other_evidence:providers/observation.json",
            "other_evidence:logs/foundation.log",
            "other_evidence:logs/observer.log",
            "other_evidence:providers/world.sdf",
        )
        for index, subject in enumerate(opaque):
            name = f"unit-inventory-extra-{index}.bin"
            (self.source / name).write_text(
                "opaque auxiliary unit fixture: " + subject + "\n"
            )
            selected[subject] = name
        existing = {item.get("subject") for item in self.bindings}
        self.bindings += [
            {"flag": "--artifact", "subject": subject, "source": name}
            for subject, name in selected.items()
            if subject not in existing
        ]
        (self.source / "bags").mkdir()
        shutil.copyfile(
            self.source / "recording-0.mcap", self.source / "bags/recording-0.mcap"
        )
        (self.source / "summaries").mkdir()
        shutil.copyfile(
            self.source / "recording-summary.json",
            self.source / "summaries/0.recording-summary.json",
        )
        self.plan = {
            "sourceRoot": str(self.source),
            "destinationRoot": str(self.retained),
            "runId": self.original["run_id"],
            "maximumBytes": 64 * 1024**2,
            "bindings": self.bindings,
            "dataSource": "simulator",
            "bagsDirectory": "bags",
            "summariesDirectory": "summaries",
        }

    def negative(self) -> None:
        result = dict(self.original)
        result["assertion_results"] = [
            dict(item) for item in result["assertion_results"]
        ]
        item = next(
            row
            for row in result["assertion_results"]
            if row["assertion_id"] == "data-plane-message-age"
        )
        item.update(
            status="failed",
            observed_value=1000.0,
            message="repository unit fixture negative assessment",
        )
        result["status"] = "failed"
        self.result_path.write_text(json.dumps(result) + "\n")

    def retained_assessment(self):
        completed = collect_inventory.verify_result(self.plan, 1, HELPERS)
        self.assertEqual(completed["verdict"], "failed")
        inventory, arguments = collect_inventory.collect(self.plan)
        self.assertEqual(arguments, completed["arguments"])
        export_retained.export(inventory)
        result = self.retained / completed["resultRelativePath"]
        aggregate = self.retained / "derived-aggregate.json"
        cli = subprocess.run(
            [
                "/opt/contracts/bin/robotics-acceptance",
                "aggregate",
                "--scenario",
                str(self.retained / "payloads/acceptance-scenario.yaml"),
                "--run-context",
                str(self.retained / "payloads/acceptance-run.json"),
                "--result",
                str(result),
                "--output",
                str(aggregate),
            ],
            capture_output=True,
            text=True,
            timeout=45,
            check=False,
        )
        self.assertEqual(cli.returncode, 1, cli.stdout + cli.stderr)
        return completed, arguments, result, aggregate

    def test_negative_is_signed_and_portable_after_raw_source_removal(self):
        self.negative()
        completed, arguments, result, aggregate = self.retained_assessment()
        original_digest = digest(result)
        shutil.rmtree(self.source)
        verified = collect_inventory.verify_aggregate(
            arguments, aggregate, result, completed, 1, HELPERS
        )
        self.assertEqual(verified["verdict"], "failed")
        self.assertEqual(verified["result"]["sha256"], original_digest)
        PublicQualification.portable(
            self,
            self.root,
            self.retained,
            arguments,
            digest(self.retained / "payloads/bags/recording-0.mcap"),
            aggregate=aggregate,
        )

    def test_exit_and_canonical_verdict_must_agree(self):
        positive = collect_inventory.verify_result(self.plan, 0, HELPERS)
        self.assertEqual(positive["verdict"], "passed")
        for code in (1, 2, -1, True):
            with self.subTest(passed_exit=code), self.assertRaises(ValueError):
                collect_inventory.verify_result(self.plan, code, HELPERS)
        self.negative()
        for code in (0, 2, -1, True):
            with self.subTest(negative_exit=code), self.assertRaises(ValueError):
                collect_inventory.verify_result(self.plan, code, HELPERS)

    def test_bad_missing_and_foreign_result_refuse(self):
        for field, value in (
            ("run_id", "run-00000000-0000-4000-8000-000000000999"),
            ("domain_id", "foreign"),
        ):
            with self.subTest(field=field):
                value_result = {**self.original, field: value}
                self.result_path.write_text(json.dumps(value_result))
                with self.assertRaises(ValueError):
                    collect_inventory.verify_result(self.plan, 0, HELPERS)
        self.result_path.write_bytes(b"not a canonical result")
        with self.assertRaises(ValueError):
            collect_inventory.verify_result(self.plan, 0, HELPERS)
        self.result_path.unlink()
        with self.assertRaises((OSError, ValueError)):
            collect_inventory.verify_result(self.plan, 0, HELPERS)

    def test_sealed_result_and_payload_bytes_cannot_change(self):
        self.negative()
        completed, arguments, result, aggregate = self.retained_assessment()
        for path in (result, self.retained / "payloads/metrics.otlp.jsonl"):
            raw = path.read_bytes()
            path.chmod(0o640)
            path.write_bytes(raw + b"\n")
            with self.subTest(payload=path.name), self.assertRaises(ValueError):
                collect_inventory.verify_aggregate(
                    arguments, aggregate, result, completed, 1, HELPERS
                )
            path.write_bytes(raw)
        for code in (0, 2):
            with self.subTest(aggregate_exit=code), self.assertRaises(ValueError):
                collect_inventory.verify_aggregate(
                    arguments, aggregate, result, completed, code, HELPERS
                )

    def test_issued_retry_preserves_original_subject_roles(self):
        self.negative()
        completed = collect_inventory.verify_result(self.plan, 1, HELPERS)
        plan_path = self.root / "plan.json"
        completed_path = self.root / "completed.json"
        completed_path.write_text(json.dumps(completed))
        original_seal = completed_path.read_bytes()
        self.plan["destinationRoot"] = str(self.root / "issued-retry")
        plan_path.write_text(json.dumps(self.plan))

        def invoke(output: Path, arguments: Path):
            return subprocess.run(
                [
                    sys.executable,
                    str(WORKERS / "collect_inventory.py"),
                    "--plan",
                    str(plan_path),
                    "--output",
                    str(output),
                    "--arguments",
                    str(arguments),
                    "--completed-result",
                    str(completed_path),
                ],
                capture_output=True,
                timeout=45,
                check=False,
            )

        output, arguments = (
            self.root / "retry-inventory.json",
            self.root / "retry-arguments.json",
        )
        cli = invoke(output, arguments)
        self.assertEqual(cli.returncode, 0, cli.stdout + cli.stderr)
        retry = json.loads(Path(str(arguments) + ".completed-result.json").read_bytes())
        self.assertEqual(retry["result"], completed["result"])
        self.assertEqual(retry["sourceArguments"], completed["sourceArguments"])
        self.assertEqual(
            retry["inventory"]["destinationRoot"], self.plan["destinationRoot"]
        )
        self.assertNotEqual(retry["arguments"], completed["arguments"])
        self.assertEqual(completed_path.read_bytes(), original_seal)

        next(
            row
            for row in self.bindings
            if row.get("subject") == "other_evidence:evidence/diagnostics.json"
        )["subject"] = "other_evidence:renamed-diagnostics.json"
        plan_path.write_text(json.dumps(self.plan))
        output, arguments = (
            self.root / "invalid-inventory.json",
            self.root / "invalid-arguments.json",
        )
        cli = invoke(output, arguments)
        self.assertNotEqual(cli.returncode, 0)
        self.assertIn(
            b"current qualification roles differ from validated assessment", cli.stderr
        )
        self.assertFalse(output.exists())
        self.assertFalse(arguments.exists())
        self.assertFalse(Path(str(arguments) + ".completed-result.json").exists())
        self.assertEqual(completed_path.read_bytes(), original_seal)


if __name__ == "__main__":
    unittest.main(verbosity=2)
