"""Finite worker checks. Qualification uses repository fixtures, not a live-run PASS claim."""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import tempfile
import unittest
from pathlib import Path

WORKERS = Path("/opt/robotics/finalizer/workers")
import sys

sys.path.insert(0, str(WORKERS))
import collect_inventory
import export_retained

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
            package = root / "portable"

            def run(
                command: list[str], cwd: Path = root
            ) -> subprocess.CompletedProcess[str]:
                result = subprocess.run(
                    command,
                    cwd=cwd,
                    capture_output=True,
                    text=True,
                    timeout=45,
                    check=False,
                )
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                return result

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
                    str(
                        HELPERS
                        / "scripts/ci/foundation/sign-ephemeral-qualification.sh"
                    ),
                    str(statement),
                    str(bundle),
                    str(key),
                ]
            )
            for path in (statement, bundle, key):
                shutil.copyfile(path, package / path.name)
            portable = (
                (package / "qualification-arguments.txt").read_text().splitlines()
            )
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
            recording_spec = next(
                v for v in portable[1::2] if v.startswith("recording:")
            )
            copied = package / recording_spec.split("=", 1)[1]
            self.assertEqual(expected["recording-0.mcap"], digest(copied))
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
