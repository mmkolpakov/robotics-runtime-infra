"""Consumer predicate controls; qualified installed CLI is a separate gate."""

import copy
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from nav2_turtlebot3_evaluator import NAMESPACE, evaluate
from robotics_acceptance_harness import EvaluationContext
from robotics_acceptance_harness.documents import DocumentBundle, LoadedDocument
from robotics_acceptance_harness.evidence import VerifiedEvidence


class NativeCaseControls(unittest.TestCase):
    def context(self, case="success", mutate=None):
        source = self.root / case
        report = json.loads((source / "workload.json").read_bytes())
        if mutate:
            mutate(report)
        directory = Path(self.temporary.name)
        path = directory / "workload.json"
        path.write_text(json.dumps(report))
        cdr = directory / "get-result-response.cdr"
        cdr.write_bytes((source / cdr.name).read_bytes())
        links = {
            path: {
                "sha256": hashlib.sha256(path.read_bytes()).hexdigest(),
                "media_type": "application/json",
            },
            cdr: {
                "sha256": hashlib.sha256(cdr.read_bytes()).hexdigest(),
                "media_type": "application/octet-stream",
            },
        }
        scenario = {
            "extensions": {
                NAMESPACE: {**copy.deepcopy(report["parameters"]), "case": case}
            }
        }
        loaded = LoadedDocument(path, scenario, "0" * 64)
        context = EvaluationContext(
            report["run_id"],
            report["domain_id"],
            DocumentBundle(loaded, loaded),
            VerifiedEvidence(loaded, tuple(links.values()), links),
            (),
            0,
            1,
        )
        return context

    def setUp(self):
        import os

        self.root = Path(
            os.environ.get(
                "NAV2_NATIVE_CASES", Path(__file__).parent / "evaluator/tests/fixtures"
            )
        )
        self.temporary = tempfile.TemporaryDirectory()

    def tearDown(self):
        self.temporary.cleanup()

    def test_four_original_outcomes(self):
        for case in ("success", "cancel", "timeout", "server-failure"):
            with self.subTest(case=case):
                self.assertEqual(
                    [r.status for r in evaluate(self.context(case))],
                    ["passed", "passed"],
                )

    def test_stale_required_dynamic_tf_refuses(self):
        def stale(report):
            for edge in report["tf_edges"]:
                if edge["source_topic"] == "/tf":
                    edge["observed_monotonic_ns"] = (
                        report["result_observed_monotonic_ns"] - 1
                    )

        self.assertEqual(list(evaluate(self.context(mutate=stale)))[1].status, "failed")

    def test_missing_native_observation_is_error(self):
        self.assertEqual(
            list(
                evaluate(
                    self.context(mutate=lambda r: r["message_counts"].update(odom=0))
                )
            )[1].status,
            "error",
        )

    def test_foreign_goal_identity_refuses(self):
        def foreign(report):
            report["result_observation"]["goal_id"][0] ^= 1

        self.assertEqual(
            list(evaluate(self.context(mutate=foreign)))[1].status, "failed"
        )

    def test_incomplete_negative_is_error(self):
        self.assertEqual(
            list(
                evaluate(
                    self.context(
                        "cancel", lambda r: r.update(observation_status="incomplete")
                    )
                )
            )[1].status,
            "error",
        )

    def test_available_server_refuses_expected_failure(self):
        self.assertEqual(
            list(
                evaluate(
                    self.context(
                        "server-failure",
                        lambda r: r.update(server_available_after_shutdown=True),
                    )
                )
            )[1].status,
            "failed",
        )

    def test_early_application_cancel_refuses_timeout(self):
        self.assertEqual(
            list(
                evaluate(
                    self.context(
                        "timeout", lambda r: r.update(consumer_trigger_elapsed_sec=1)
                    )
                )
            )[1].status,
            "failed",
        )

    def test_late_result_refuses(self):
        def late(report):
            report["result_observed_monotonic_ns"] = (
                report["goal_accepted_monotonic_ns"] + 121_000_000_000
            )
            report["goal_finished_monotonic_ns"] = report[
                "result_observed_monotonic_ns"
            ]

        self.assertEqual(
            list(evaluate(self.context("cancel", late)))[1].status, "failed"
        )

    def test_acceptance_delay_is_inside_action_budget(self):
        def delayed(report):
            start = report["goal_started_monotonic_ns"]
            report["goal_accepted_monotonic_ns"] = start + 9_000_000_000
            report["result_observed_monotonic_ns"] = start + 128_000_000_000
            report["goal_finished_monotonic_ns"] = start + 128_000_000_001

        self.assertEqual(
            list(evaluate(self.context("cancel", delayed)))[1].status, "failed"
        )

    def test_late_success_arrival_refuses(self):
        def delayed(report):
            finish = (
                report["amcl_nomotion_update"]["responded_monotonic_ns"] + 3_000_000_000
            )
            report["goal_finished_monotonic_ns"] = finish
            for key in report["last_observation_monotonic_ns"]:
                report["last_observation_monotonic_ns"][key] = finish
            for edge in report["tf_edges"]:
                edge["observed_monotonic_ns"] = finish

        self.assertEqual(
            list(evaluate(self.context(mutate=delayed)))[1].status, "failed"
        )

    def test_mutated_verified_bytes_refuse(self):
        context = self.context()
        next(
            p for p in context.evidence.local_files if p.name == "workload.json"
        ).write_text("{}")
        with self.assertRaisesRegex(ValueError, "changed"):
            list(evaluate(context))

    def test_mutated_cdr_refuses(self):
        context = self.context()
        next(
            p for p in context.evidence.local_files if p.name.endswith(".cdr")
        ).write_bytes(b"bad")
        with self.assertRaisesRegex(ValueError, "CDR"):
            list(evaluate(context))


if __name__ == "__main__":
    unittest.main()
