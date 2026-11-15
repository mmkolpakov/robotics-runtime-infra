"""Sampled stop controls use source time and measured motion."""

import copy
import unittest

from nav2_turtlebot3_evaluator.stop import STOP_POLICY, assess_stop


def stopped_capture(case="cancel"):
    anchor = 10_000_000_000
    cutoff = 1_000_000_000
    samples = [
        {
            "source_ns": cutoff + i * 50_000_000,
            "receiver_ns": anchor + i * 60_000_000,
            "frame_id": "odom",
            "child_frame_id": "base_footprint",
            "x": 0.0,
            "y": 0.0,
            "orientation": {"x": 0.0, "y": 0.0, "z": 0.0, "w": 1.0},
            "vx": 0.0,
            "vy": 0.0,
            "wz": 0.0,
        }
        for i in range(1, 15)
    ]
    stamp_pairs = [
        {"source_ns": sample["source_ns"], "receiver_ns": sample["receiver_ns"]}
        for sample in samples
    ]
    report = {
        "goal_id": [1] * 16,
        "goal_accepted": True,
        "goal_started_monotonic_ns": anchor - 1_000_000_000,
        "goal_accepted_monotonic_ns": anchor - 900_000_000,
        "consumer_trigger_monotonic_ns": anchor - 100_000_000,
        "action_status": 5,
        "cancel_acknowledged": True,
        "result_observation": {"goal_id": [1] * 16},
        "result_observed_monotonic_ns": anchor,
        "result_observed_clock_ns": cutoff,
        "server_after_shutdown_monotonic_ns": anchor,
        "server_after_shutdown_clock_ns": cutoff,
        "server_available_after_shutdown": False,
        "stop_observation": {
            "anchor": {
                "goal_id": [1] * 16,
                "kind": "server_unavailable"
                if case == "server-failure"
                else "canceled_result",
                "receiver_monotonic_ns": anchor,
                "clock_ns": cutoff,
            },
            "deadline_monotonic_ns": anchor + 119_000_000_000,
            "observation_cutoff_monotonic_ns": anchor + 2_000_000_000,
            "closed_monotonic_ns": anchor + 2_000_001_000,
            "samples_omitted": False,
            "samples": samples,
            "clock_samples": copy.deepcopy(stamp_pairs),
            "transforms": [
                {**pair, "parent": "odom", "child": "base_footprint"}
                for pair in stamp_pairs
            ],
        },
    }
    config = {
        "case": case,
        "odometry_frame": "odom",
        "max_observation_age_sec": 2.0,
        "action_budget_sec": 120.0,
        "stop_condition": dict(STOP_POLICY),
    }
    return report, config


class SampledStop(unittest.TestCase):
    def test_all_negative_cases_accept_a_complete_stationary_window(self):
        for case in ("cancel", "timeout", "server-failure"):
            with self.subTest(case=case):
                report, config = stopped_capture(case)
                window, stopped, _reason = assess_stop(report, config)
                self.assertIsNotNone(window)
                self.assertTrue(stopped)

    def test_velocity_violation_is_measured_and_failed(self):
        for field in ("vx", "vy", "wz"):
            with self.subTest(field=field):
                report, config = stopped_capture()
                report["stop_observation"]["samples"][-1][field] = 0.02
                window, stopped, _reason = assess_stop(report, config)
                self.assertIsNotNone(window)
                self.assertIs(stopped, False)

    def test_pose_motion_cannot_be_hidden_by_zero_twist(self):
        for mode in ("translation", "rotation"):
            report, config = stopped_capture()
            for index, sample in enumerate(report["stop_observation"]["samples"]):
                if mode == "translation":
                    sample["x"] = index * 0.01
                else:
                    import math

                    yaw = index * 0.1
                    sample["orientation"] = {
                        "x": 0.0,
                        "y": 0.0,
                        "z": math.sin(yaw / 2),
                        "w": math.cos(yaw / 2),
                    }
            window, stopped, _reason = assess_stop(report, config)
            self.assertIsNotNone(window)
            self.assertFalse(stopped)

    def test_missing_or_inconsistent_samples_are_unobserved(self):
        for change in (
            lambda window: window["samples"].clear(),
            lambda window: window["samples"][2].update(source_ns=1_100_000_000),
            lambda window: window["samples"][2].update(source_ns=1_900_000_000),
            lambda window: window["samples"][0].update(receiver_ns=9_000_000_000),
            lambda window: window["samples"][-1].update(receiver_ns=12_000_000_001),
            lambda window: window.update(
                observation_cutoff_monotonic_ns=window["deadline_monotonic_ns"] + 1,
                closed_monotonic_ns=window["deadline_monotonic_ns"] + 2,
            ),
            lambda window: window["samples"][0].update(frame_id="map"),
            lambda window: window["samples"][0].update(vx=float("nan")),
            lambda window: window["samples"][0].update(
                orientation={"x": 0, "y": 0, "z": 0, "w": 0}
            ),
            lambda window: window["clock_samples"].clear(),
            lambda window: window["transforms"][0].update(child="different"),
            lambda window: window["anchor"].update(goal_id=[2] * 16),
        ):
            report, config = stopped_capture()
            change(report["stop_observation"])
            window, stopped, reason = assess_stop(report, config)
            self.assertIsNone(window, reason)
            self.assertIsNone(stopped)

    def test_old_archives_keep_their_unobserved_condition(self):
        report, config = stopped_capture()
        config.pop("stop_condition")
        window, stopped, _reason = assess_stop(report, config)
        self.assertIsNone(window)
        self.assertIsNone(stopped)

    def test_quiet_earlier_samples_cannot_hide_final_motion(self):
        report, config = stopped_capture()
        for sample in report["stop_observation"]["samples"][-5:]:
            sample["vx"] = 0.1
        self.assertFalse(assess_stop(report, config)[1])

    def test_declared_policy_cannot_be_relaxed(self):
        report, config = stopped_capture()
        config["stop_condition"]["max_linear_speed_mps"] = 1.0
        with self.assertRaises(ValueError):
            assess_stop(report, config)

    def test_last_clock_cannot_extend_beyond_available_motion(self):
        report, config = stopped_capture()
        report["stop_observation"]["clock_samples"][-1]["source_ns"] += 200_000_000
        self.assertIsNone(assess_stop(report, config)[0])

    def test_twist_boundaries_are_inclusive(self):
        report, config = stopped_capture()
        for sample in report["stop_observation"]["samples"]:
            sample["vx"] = 0.01
            sample["wz"] = -0.01
        self.assertTrue(assess_stop(report, config)[1])

    def test_all_received_motion_is_validated_even_before_final_suffix(self):
        report, config = stopped_capture()
        report["stop_observation"]["samples"][0]["vx"] = float("inf")
        self.assertIsNone(assess_stop(report, config)[0])

    def test_wrapped_yaw_crossing_pi_is_a_small_motion(self):
        import math

        report, config = stopped_capture()
        for index, sample in enumerate(report["stop_observation"]["samples"]):
            yaw = math.pi - 0.001 + index * 0.0001
            sample["orientation"] = {
                "x": 0.0,
                "y": 0.0,
                "z": math.sin(yaw / 2),
                "w": math.cos(yaw / 2),
            }
        self.assertTrue(assess_stop(report, config)[1])

    def test_integrated_evaluator_keeps_motion_failure_separate_from_cancel(self):
        from test_evaluator import NativeCaseControls
        from nav2_turtlebot3_evaluator import evaluate

        helper = NativeCaseControls()
        helper.setUp()
        self.addCleanup(helper.tearDown)
        sample_report, config = stopped_capture()

        def captured(report):
            for key in (
                "goal_id",
                "goal_accepted",
                "action_status",
                "cancel_acknowledged",
                "result_observed_monotonic_ns",
                "result_observed_clock_ns",
                "goal_started_monotonic_ns",
                "stop_observation",
            ):
                report[key] = copy.deepcopy(sample_report[key])
            report["result_observation"]["goal_id"] = report["goal_id"]
            report["goal_accepted_monotonic_ns"] = (
                sample_report["goal_started_monotonic_ns"] + 1
            )
            report["goal_finished_monotonic_ns"] = sample_report["stop_observation"][
                "closed_monotonic_ns"
            ]
            report["parameters"]["stop_condition"] = config["stop_condition"]
            for sample in report["stop_observation"]["samples"]:
                sample["vx"] = 0.03

        results = {
            row.assertion_id: row
            for row in evaluate(helper.context("cancel", captured))
        }
        stop = results["org.example.nav2-turtlebot3.physical-stop"]
        self.assertEqual(stop.status, "failed")
        self.assertIs(stop.observed_value, False)
        self.assertEqual(
            results["org.example.nav2-turtlebot3.action-cancel"].status, "passed"
        )

    def test_source_collection_retains_terminal_anchor_and_clock_cutoff(self):
        import ast
        from pathlib import Path

        tree = ast.parse(Path(__file__).with_name("workload.py").read_text())
        source = ast.unparse(tree)
        self.assertIn("report['result_observed_clock_ns'] = latest_clock_ns", source)
        self.assertIn(
            "report['server_after_shutdown_clock_ns'] = latest_clock_ns", source
        )
        self.assertIn("append_stop_sample(stop_observation, 'samples'", source)
        self.assertIn("wait_for_sampled_stop(navigator, report, configuration)", source)
        self.assertIn("message.twist.twist.linear.x", source)
        self.assertIn("message.twist.twist.angular.z", source)

    def test_new_native_negative_preparation_requires_stop_policy(self):
        from test_workload_inputs import NativeAdmissionControls

        helper = NativeAdmissionControls()
        helper.setUp()
        self.addCleanup(helper.doCleanups)
        request = __import__("json").loads(helper.requirements.read_text())
        request["case"] = request["configuration"]["case"] = "cancel"
        helper.requirements.write_text(__import__("json").dumps(request))
        with self.assertRaisesRegex(ValueError, "stop_condition"):
            helper.prepare()

    def finalizer_observation(self, case, *, valid=True):
        import importlib.util
        import json
        import tempfile
        from pathlib import Path
        from test_v2_documents import completed, inputs

        root = Path(__file__).parent
        spec = importlib.util.spec_from_file_location(
            "stop_finalizer", root / "finalize.py"
        )
        finalizer = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(finalizer)
        with tempfile.TemporaryDirectory() as directory:
            prepared, manifest = inputs(Path(directory), case=case)
            capture, _facts = completed(prepared, manifest)
            (capture / "completed-facts.json").unlink()
            target = capture / case
            target.mkdir()
            (capture / "workload.json").rename(target / "workload.json")
            (capture / "get-result-response.cdr").rename(
                target / "get-result-response.cdr"
            )
            report = json.loads((target / "workload.json").read_text())
            sample_report, config = stopped_capture(case)
            sample_report["goal_id"] = report["goal_id"]
            sample_report["stop_observation"]["anchor"]["goal_id"] = report["goal_id"]
            sample_report["result_observation"] = report["result_observation"]
            for sample in sample_report["stop_observation"]["samples"]:
                sample["vx"] = 0.05
            report.update(sample_report)
            (target / "workload.json").write_text(json.dumps(report))
            scenario = json.loads((prepared / "scenario.json").read_text())
            scenario["extensions"]["org.example.nav2-turtlebot3"]["stop_condition"] = (
                config["stop_condition"]
            )
            (prepared / "scenario.json").write_text(json.dumps(scenario))
            (capture / "native-run.json").write_text(
                json.dumps(
                    {
                        "started_at": "2026-11-14T00:00:00Z",
                        "finished_at": "2026-11-14T00:00:01Z",
                    }
                )
            )
            (capture / "cleanup.json").write_text(
                json.dumps(
                    {"remaining": [], "worker_settled": True, "recorder_settled": True}
                )
            )
            (capture / "native-acquired.json").write_text(
                json.dumps({"HostConfig": {"NetworkMode": "none"}})
            )
            recorder = capture / "recorder-facts"
            recorder.mkdir()
            (recorder / "capture-state.json").write_text(
                json.dumps(
                    {
                        "run_id": manifest["run_id"],
                        "domain_id": "nav2",
                        "capture_status": "complete",
                        "closure_confirmed": True,
                        "policy_observation": {
                            "retention_class": "test-evidence",
                            "upload_mode": "local_only",
                        },
                    }
                )
            )
            for name in (
                "native-model.sdf",
                "native-world.sdf",
                "native-preflight.json",
            ):
                (prepared / name).write_text("{}")
            if not valid:
                report["stop_observation"]["samples"].clear()
                (target / "workload.json").write_text(json.dumps(report))
            if case == "server-failure":
                report.pop("action_status", None)
                report.pop("result_observation", None)
                report.pop("result_observed_monotonic_ns", None)
                report["goal_accepted_monotonic_ns"] = (
                    report["goal_started_monotonic_ns"] + 1
                )
                (target / "workload.json").write_text(json.dumps(report))
                (target / "get-result-response.cdr").unlink()
            return finalizer.complete_native(prepared, capture)

    def test_moving_valid_window_is_measured_by_finalizer(self):
        facts = self.finalizer_observation("cancel")
        condition = facts["observations"]["condition"]
        self.assertEqual(condition["state"], "measured")
        self.assertEqual(
            condition["value"]["sample_counts"],
            {"samples": 14, "transforms": 14, "clock_samples": 14},
        )
        self.assertEqual(condition["value"]["last_odometry_source_ns"], 1_700_000_000)
        self.assertTrue(condition["evidence"]["uri"].endswith("/workload.json"))

    def test_server_failure_preserves_terminal_fact_and_measured_motion_failure(self):
        facts = self.finalizer_observation("server-failure")
        self.assertEqual(facts["observations"]["condition"]["state"], "measured")
        self.assertEqual(facts["observations"]["terminal"]["state"], "measured")
        self.assertEqual(
            facts["observations"]["terminal"]["value"]["kind"], "server_unavailable"
        )

    def test_missing_stop_samples_remain_unobserved_after_server_failure(self):
        facts = self.finalizer_observation("server-failure", valid=False)
        self.assertEqual(facts["observations"]["condition"]["state"], "unobserved")
        self.assertEqual(facts["observations"]["terminal"]["state"], "measured")

    def test_server_failure_stop_uses_no_getresult_fields(self):
        report, config = stopped_capture("server-failure")
        for key in (
            "action_status",
            "result_observation",
            "result_observed_monotonic_ns",
            "result_observed_clock_ns",
        ):
            report.pop(key)
        window, stopped, _reason = assess_stop(report, config)
        self.assertIsNotNone(window)
        self.assertTrue(stopped)

    def test_native_clock_phase_does_not_shorten_the_last_odometry_window(self):
        report, config = stopped_capture()
        window = report["stop_observation"]
        prototype = window["samples"][0]
        window["samples"] = [
            {
                **prototype,
                "source_ns": 1_000_000_000 + i * 36_000_000,
                "receiver_ns": 10_000_000_000 + i * 40_000_000,
            }
            for i in range(1, 21)
        ]
        window["clock_samples"] = [
            {
                "source_ns": 1_000_000_000 + i * 3_000_000,
                "receiver_ns": 10_000_000_000 + i * 3_500_000,
            }
            for i in range(1, 252)
        ]
        window["transforms"] = [
            {
                "source_ns": sample["source_ns"],
                "receiver_ns": sample["receiver_ns"],
                "parent": "odom",
                "child": "base_footprint",
            }
            for sample in window["samples"]
        ]
        self.assertTrue(assess_stop(report, config)[1])


class ServerFailureObservation(unittest.TestCase):
    def test_absence_poll_services_callbacks_within_the_existing_deadline(self):
        from pathlib import Path
        import runpy
        from types import SimpleNamespace
        from unittest.mock import Mock, patch

        function = runpy.run_path(str(Path(__file__).with_name("workload.py")))[
            "observe_action_server"
        ]
        client = Mock()
        navigator = object()
        now_ns = 0
        client.server_is_ready.side_effect = lambda: now_ns < 950_000_000
        polls = []

        def spin(node, *, timeout_sec):
            nonlocal now_ns
            self.assertIs(node, navigator)
            polls.append(timeout_sec)
            now_ns += round(timeout_sec * 1e9)

        with (
            patch.dict(
                function.__globals__, {"rclpy": SimpleNamespace(spin_once=spin)}
            ),
            patch.object(
                function.__globals__["time"],
                "monotonic",
                side_effect=lambda: now_ns / 1e9,
            ),
        ):
            self.assertFalse(function(navigator, client, 0.975))

        client.server_is_ready.assert_called_once()
        self.assertEqual(now_ns, 975_000_000)
        self.assertEqual(len(polls), 20)
        self.assertAlmostEqual(polls[-1], 0.025)

    def test_queued_and_unsupported_dds_receipts_do_not_enter_server_stop_window(self):
        from pathlib import Path
        import runpy

        from unittest.mock import patch

        append = runpy.run_path(str(Path(__file__).with_name("workload.py")))[
            "append_stop_sample"
        ]
        anchor = {"rmw_receive_after_unix_ns": 1_790_000_000_000_000_000}
        cutoff = anchor["rmw_receive_after_unix_ns"]
        window = {
            "anchor": anchor,
            "deadline_monotonic_ns": 10,
            "samples": [],
            "samples_omitted": False,
        }
        with patch.dict(append.__globals__, {"MAX_STOP_SAMPLES": 1}):
            for timestamp in (None, 0, cutoff - 1, cutoff, float(cutoff)):
                append(
                    window, "samples", {"receiver_ns": 5}, received_unix_ns=timestamp
                )
            self.assertEqual(window["samples"], [])
            append(window, "samples", {"receiver_ns": 6}, received_unix_ns=cutoff + 1)
            self.assertEqual(
                window["samples"],
                [{"receiver_ns": 6, "rmw_received_unix_ns": cutoff + 1}],
            )
            self.assertFalse(window["samples_omitted"])
            canceled = {**window, "anchor": {"kind": "canceled_result"}, "samples": []}
            append(canceled, "samples", {"receiver_ns": 7})
            self.assertEqual(canceled["samples"], [{"receiver_ns": 7}])


class StopSettlement(unittest.TestCase):
    def run_capture(self, report, config, *, assessment_cost_ns=0):
        from pathlib import Path
        import runpy
        from types import SimpleNamespace
        from unittest.mock import patch

        worker = runpy.run_path(str(Path(__file__).with_name("workload.py")))
        wait = worker["wait_for_sampled_stop"]
        append = worker["append_stop_sample"]
        window = report["stop_observation"]
        next_rows = []
        now = window["anchor"]["receiver_monotonic_ns"]
        for stream in ("samples", "clock_samples", "transforms"):
            for index, sample in enumerate(window[stream], 1):
                next_rows.append(
                    (stream, {**sample, "receiver_ns": now + index * 200_000_000})
                )
            window[stream] = []
        next_rows.sort(key=lambda row: row[1]["receiver_ns"])

        def spin(node, *, timeout_sec):
            nonlocal now
            now += round(timeout_sec * 1e9)
            for stream, sample in next_rows[:]:
                if sample["receiver_ns"] > now:
                    break
                append(window, stream, sample)
                next_rows.pop(0)

        def assess(report, config):
            nonlocal now
            result = assess_stop(report, config)
            if result[1] is True:
                now += assessment_cost_ns
            return result

        with (
            patch.dict(
                wait.__globals__,
                {
                    "rclpy": SimpleNamespace(spin_once=spin),
                    "assess_stop": assess,
                    "MAX_STOP_SAMPLES": 4096,
                },
            ),
            patch.object(
                wait.__globals__["time"], "monotonic_ns", side_effect=lambda: now
            ),
        ):
            wait(object(), report, config)
        return window

    def test_slow_simulation_collects_fresh_samples_beyond_two_wall_seconds(self):
        report, config = stopped_capture("timeout")
        for sample in report["stop_observation"]["samples"][:2]:
            sample["vx"] = 0.1
        report["stop_observation"]["samples"][-1]["vx"] = 0.1
        window = self.run_capture(report, config)
        self.assertGreater(
            window["closed_monotonic_ns"] - window["anchor"]["receiver_monotonic_ns"],
            2_000_000_000,
        )
        self.assertLess(window["closed_monotonic_ns"], window["deadline_monotonic_ns"])
        self.assertEqual(window["samples"][0]["vx"], 0.1)
        self.assertEqual(len(window["samples"]), 13)
        self.assertTrue(assess_stop(report, config)[1])

    def test_continued_motion_at_action_deadline_remains_measured_and_failed(self):
        report, config = stopped_capture("timeout")
        window = report["stop_observation"]
        config["action_budget_sec"] = 4
        window["deadline_monotonic_ns"] = (
            report["goal_started_monotonic_ns"] + 4_000_000_000
        )
        for sample in window["samples"]:
            sample["vx"] = 0.1

        self.run_capture(report, config)

        self.assertEqual(
            window["observation_cutoff_monotonic_ns"], window["deadline_monotonic_ns"]
        )
        self.assertIs(assess_stop(report, config)[1], False)
        self.assertIsNotNone(assess_stop(report, config)[0])

    def test_live_assessment_returning_after_deadline_cannot_complete(self):
        report, config = stopped_capture("timeout")
        window = report["stop_observation"]
        config["action_budget_sec"] = 4
        window["deadline_monotonic_ns"] = (
            report["goal_started_monotonic_ns"] + 4_000_000_000
        )

        self.run_capture(report, config, assessment_cost_ns=1_000_000_000)

        self.assertEqual(
            window["observation_cutoff_monotonic_ns"], window["deadline_monotonic_ns"]
        )
        self.assertGreater(
            window["closed_monotonic_ns"], window["deadline_monotonic_ns"]
        )
        self.assertIs(assess_stop(report, config)[1], False)

    def test_quiet_samples_do_not_pass_after_action_deadline(self):
        report, config = stopped_capture("timeout")
        window = report["stop_observation"]
        window["closed_monotonic_ns"] = window["deadline_monotonic_ns"]
        for stream in ("samples", "clock_samples", "transforms"):
            for sample in window[stream]:
                sample["receiver_ns"] += 117_000_000_000
        window["observation_cutoff_monotonic_ns"] = window["deadline_monotonic_ns"]

        retained, stopped, reason = assess_stop(report, config)

        self.assertIsNotNone(retained)
        self.assertIs(stopped, False)
        self.assertIn("action deadline", reason)

    def test_receiver_freshness_is_still_enforced_at_capture_close(self):
        report, config = stopped_capture()
        report["stop_observation"]["closed_monotonic_ns"] += 1_000_000_000
        retained, stopped, reason = assess_stop(report, config)
        self.assertIsNone(retained)
        self.assertIsNone(stopped)
        self.assertIn("stale", reason)

    def test_worker_sample_limit_retains_prefix_and_marks_it_incomplete(self):
        from pathlib import Path
        import runpy
        from unittest.mock import patch

        report, config = stopped_capture()
        window = report["stop_observation"]
        append = runpy.run_path(str(Path(__file__).with_name("workload.py")))[
            "append_stop_sample"
        ]
        with patch.dict(
            append.__globals__, {"MAX_STOP_SAMPLES": len(window["samples"])}
        ):
            append(window, "samples", dict(window["samples"][-1]))
        self.assertTrue(window["samples_omitted"])
        self.assertEqual(len(window["samples"]), 14)
        self.assertIsNone(assess_stop(report, config)[0])
