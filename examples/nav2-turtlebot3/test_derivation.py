"""Offline projection controls; synthetic records are never native evidence."""

import hashlib
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

from robotics_acceptance_harness.otel import load_otlp_json_metrics

spec = importlib.util.spec_from_file_location(
    "derive_otlp", Path(__file__).with_name("derive-otlp.py")
)
module = importlib.util.module_from_spec(spec)
spec.loader.exec_module(module)


class ProjectionControls(unittest.TestCase):
    def rows(self):
        rows = []
        for index in range(3):
            for kind in ("odom", "clock"):
                rows.append(
                    {
                        "kind": kind,
                        "run_id": "owned-run",
                        "observed_unix_ns": 1_791_477_624_000_000_000
                        + index * 100_000_000,
                        "observed_monotonic_ns": 700_000_000_000 + index * 100_000_000,
                        "message": {"clock": {"sec": 12, "nanosec": index}},
                        "message_info": {
                            "source_timestamp": 1_791_477_624_000_000_000,
                            "received_timestamp": 1_791_477_624_001_000_000,
                            "publication_sequence_number": 2**53
                            + index
                            + (1 if index == 2 else 0),
                            "publisher_count": 1,
                            "publisher_gid": None,
                            "reception_sequence_number": None,
                        },
                    }
                )
        return rows

    def project(self, rows):
        temporary = tempfile.TemporaryDirectory()
        self.addCleanup(temporary.cleanup)
        root = Path(temporary.name)
        source = root / "observations.jsonl"
        source.write_text("".join(json.dumps(row) + "\n" for row in rows))
        output = root / "derived"
        module.derive(
            source,
            output,
            "owned-run",
            "nav2",
            hashlib.sha256(source.read_bytes()).hexdigest(),
        )
        return source, output

    def test_exact_native_u64_difference_and_unaltered_source(self):
        rows = self.rows()
        source, output = self.project(rows)
        self.assertEqual(
            [json.loads(line) for line in source.read_text().splitlines()], rows
        )
        result = json.loads((output / "derivation.json").read_bytes())
        self.assertEqual(result["native_odom_sequence_gaps"], 1)
        points = load_otlp_json_metrics(output / "metrics.otlp.jsonl")
        self.assertEqual(
            max(p.value for p in points if p.name == "robotics.message.lost"), 1
        )

    def test_wrong_selected_digest_refuses_before_output(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            source = root / "source.jsonl"
            source.write_text(json.dumps(self.rows()[0]) + "\n")
            with self.assertRaisesRegex(ValueError, "digest"):
                module.derive(source, root / "output", "owned-run", "nav2", "0" * 64)
            self.assertFalse((root / "output").exists())

    def test_boolean_publisher_count_refuses(self):
        rows = self.rows()
        rows[0]["message_info"]["publisher_count"] = True
        with self.assertRaisesRegex(ValueError, "single-publisher"):
            self.project(rows)

    def test_foreign_run_refuses(self):
        rows = self.rows()
        rows[0]["run_id"] = "foreign"
        with self.assertRaisesRegex(ValueError, "foreign"):
            self.project(rows)

    def test_multiple_publishers_refuse(self):
        rows = self.rows()
        rows[0]["message_info"]["publisher_count"] = 2
        with self.assertRaisesRegex(ValueError, "single-publisher"):
            self.project(rows)

    def test_unavailable_sequence_refuses(self):
        rows = self.rows()
        rows[0]["message_info"]["publication_sequence_number"] = None
        with self.assertRaisesRegex(ValueError, "sequence"):
            self.project(rows)

    def test_sequence_reset_refuses(self):
        rows = self.rows()
        rows[2]["message_info"]["publication_sequence_number"] = 1
        with self.assertRaisesRegex(ValueError, "reset"):
            self.project(rows)

    def test_missing_age_does_not_become_zero(self):
        rows = self.rows()
        rows[0]["message_info"]["source_timestamp"] = None
        with self.assertRaisesRegex(ValueError, "metadata"):
            self.project(rows)


if __name__ == "__main__":
    unittest.main()
