"""Exercise the archive consumer against the installed Contracts and Harness."""

from hashlib import sha256
import json
from pathlib import Path
import subprocess
import sys
from tempfile import TemporaryDirectory
import unittest


SUMMARY = (
    "Avg Duration:       72.20s ± 0.00s\n"
    "Avg Step Time:      5.776 ms\n"
    "Avg Speedup:        3.46x ± 0.00x wall-clock\n"
    "Avg Throughput:     173.12 ± 0.00 steps/second\n"
)


def digest(path):
    return sha256(path.read_bytes()).hexdigest()


def synthetic_stdout(*, change_clock=False, skip_frame=False, summary=SUMMARY):
    records = [
        f"\r[{'-' * 40}] {(index + int(change_clock and index == 500)) / 50:6.2f}s / 300s"
        for index in range(12501)
        if not (skip_frame and index == 500)
    ]
    return (
        "Starting speed test: 1 runs of 12500 steps each.\n"
        + "".join(records)
        + "\n"
        + summary
    ).encode()


class ArchiveConsumer(unittest.TestCase):
    def setUp(self):
        root = TemporaryDirectory()
        self.addCleanup(root.cleanup)
        self.path = Path(root.name)
        self.capture = self.path / "capture"
        self.capture.mkdir()
        self.stdout = self.capture / "worker.out"
        self.native = self.capture / "RUN-RESULT.json"
        self.binding = self.path / "binding.json"
        self.authorization = self.path / "authorization.json"
        self.review = self.path / "review.json"
        self.output = self.path / "output"

    def fixture(self, stdout, pilot="px4", *, binding_argv=None):
        facts = {
            "autopilot": pilot,
            "source_commit": "a" * 40,
            "argv": [
                "--mode",
                "speedup",
                "--num_quads",
                "1",
                "--no-camera",
                "--no-lidar",
                "--autopilot",
                pilot,
                "--no-gpu",
            ],
            "images": {
                "aircraft": {
                    "config": "sha256:" + "b" * 64,
                    "manifest": "sha256:" + "c" * 64,
                },
                "simulation": {
                    "config": "sha256:" + "d" * 64,
                    "manifest": "sha256:" + "e" * 64,
                },
            },
        }
        self.binding.write_text(
            json.dumps(
                {
                    "source_commit": facts["source_commit"],
                    "images": facts["images"],
                    "cases": {
                        pilot: {
                            "argv": facts["argv"]
                            if binding_argv is None
                            else binding_argv
                        }
                    },
                }
            ),
            encoding="utf-8",
        )
        self.authorization.write_text(
            json.dumps(
                {
                    **facts,
                    "binding_sha256": digest(self.binding),
                }
            ),
            encoding="utf-8",
        )
        self.native.write_text(
            json.dumps(
                {
                    **facts,
                    "scope_binding_sha256": digest(self.binding),
                    "operator_binding_sha256": digest(self.authorization),
                    "state": "benchmark-completed-and-owned-inventory-empty",
                    "worker_exit": 0,
                    "api_exit": 0,
                    "cleanup_errors": [],
                    "started_utc": "2026-01-01T00:00:00+00:00",
                    "completed_utc": "2026-01-01T00:01:30+00:00",
                    "benchmark_summary": [SUMMARY.splitlines()[i] for i in (0, 2, 3)],
                }
            ),
            encoding="utf-8",
        )
        self.stdout.write_bytes(stdout)
        self.review.write_text(
            json.dumps(
                {
                    "stdout_sha256": digest(self.stdout),
                    "result_sha256": digest(self.native),
                }
            ),
            encoding="utf-8",
        )
        self.review_sha256 = digest(self.review)

    def run_archive(self):
        return subprocess.run(
            [
                sys.executable,
                "-I",
                "-B",
                str(Path(__file__).with_name("archive.py")),
                "--capture",
                str(self.capture),
                "--binding",
                str(self.binding),
                "--authorization",
                str(self.authorization),
                "--review",
                str(self.review),
                "--review-sha256",
                self.review_sha256,
                "--output",
                str(self.output),
            ],
            capture_output=True,
            text=True,
            check=False,
            timeout=30,
        )

    def result(self, process):
        identity = json.loads(process.stdout)
        document = json.loads(Path(identity["result"]).read_bytes())
        self.assertEqual(identity["run_id"], document["run_id"])
        self.assertTrue(Path(identity["evidence_index"]).is_file())
        return document

    def test_published_metric_method_accepts_consistent_benchmark(self):
        self.fixture(synthetic_stdout(), "ardupilot")
        process = self.run_archive()
        self.assertEqual(process.returncode, 0, process.stderr)
        document = self.result(process)
        self.assertEqual(document["status"], "passed")
        self.assertEqual(document["execution"]["target_environment"], "software")
        self.assertEqual(document["evaluators"], [])
        self.assertEqual(
            (self.output / "raw/worker.out").read_bytes(), self.stdout.read_bytes()
        )
        observation = json.loads((self.output / "observation.json").read_bytes())
        self.assertEqual(
            observation["observations"]["imported-files"]["value"][
                "original_benchmark"
            ]["started_utc"],
            "2026-01-01T00:00:00+00:00",
        )
        self.assertNotEqual(observation["started_at"], "2026-01-01T00:00:00+00:00")
        self.assertEqual(
            observation["observations"]["benchmark-consistency"]["value"],
            {
                "rendered_steps": 12500,
                "rendered_span_centiseconds": 25000,
                "rendered_clock_errors": 0,
                "summary_errors": 0,
            },
        )

    def test_hashed_but_wrong_clock_fails_harness(self):
        self.fixture(synthetic_stdout(change_clock=True))
        process = self.run_archive()
        self.assertEqual(process.returncode, 1, process.stderr)
        document = self.result(process)
        self.assertEqual(document["status"], "failed")
        assertion = next(
            x
            for x in document["assertion_results"]
            if x["assertion_id"] == "rendered_clock_errors"
        )
        self.assertEqual(assertion["status"], "failed")
        self.assertEqual(assertion["observed_value"], 1)

    def test_truncated_clock_fails_harness(self):
        self.fixture(synthetic_stdout(skip_frame=True))
        process = self.run_archive()
        self.assertEqual(process.returncode, 1, process.stderr)
        assertion = next(
            x
            for x in self.result(process)["assertion_results"]
            if x["assertion_id"] == "rendered_steps"
        )
        self.assertEqual(assertion["observed_value"], 12499)

    def test_inconsistent_summary_fails_harness(self):
        self.fixture(synthetic_stdout(summary=SUMMARY.replace("5.776", "5.900")))
        process = self.run_archive()
        self.assertEqual(process.returncode, 1, process.stderr)
        assertion = next(
            x
            for x in self.result(process)["assertion_results"]
            if x["assertion_id"] == "summary_errors"
        )
        self.assertEqual(assertion["status"], "failed")
        self.assertEqual(assertion["observed_value"], 1)

    def test_malformed_capture_cannot_create_a_result(self):
        for name, summary in (
            ("missing", SUMMARY.split("Avg Throughput:")[0]),
            ("repeated", SUMMARY + SUMMARY),
        ):
            with self.subTest(name=name):
                self.output = self.path / name
                self.fixture(synthetic_stdout(summary=summary))
                process = self.run_archive()
                self.assertEqual(process.returncode, 2, process.stderr)
                self.assertIn("benchmark summary", process.stderr)
                self.assertFalse(
                    (self.output / "assessment/acceptance-result.json").exists()
                )

    def test_correctly_hashed_but_foreign_binding_refused(self):
        self.fixture(synthetic_stdout(), binding_argv=["--mode", "step"])
        process = self.run_archive()
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("benchmark configuration differs", process.stderr)
        self.assertFalse(self.output.exists())

    def test_missing_custody_refused_before_output_creation(self):
        self.fixture(synthetic_stdout())
        self.binding.unlink()
        process = self.run_archive()
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("missing regular file", process.stderr)
        self.assertFalse(self.output.exists())

    def test_tamper_refused_before_output_creation(self):
        self.fixture(synthetic_stdout())
        with self.stdout.open("ab") as output:
            output.write(b"changed\n")
        process = self.run_archive()
        self.assertEqual(process.returncode, 2, process.stderr)
        self.assertIn("worker.out SHA-256", process.stderr)
        self.assertFalse(self.output.exists())


if __name__ == "__main__":
    unittest.main()
