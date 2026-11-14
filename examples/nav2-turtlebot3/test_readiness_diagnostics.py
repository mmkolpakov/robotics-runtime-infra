"""Keep the public readiness decision and retain its last observed graph."""

from dataclasses import asdict, replace
from functools import partial
from pathlib import Path
import json
import runpy
import unittest
from unittest.mock import patch

from robotics_acceptance_harness.readiness import (
    EndpointObservation,
    GraphReadinessTimeout,
    GraphSnapshot,
    LifecycleObservation,
    TopicObservation,
    evaluate_graph,
    wait_for_readiness,
)


ROOT = Path(__file__).parent


class FakeTime:
    def __init__(self):
        self.value_ns = 0

    def now_ns(self):
        return self.value_ns

    def sleep(self, seconds):
        self.value_ns += round(seconds * 1_000_000_000)


class Observer:
    def __init__(self, clock, snapshot):
        self.clock = clock
        self.make_snapshot = snapshot
        self.calls = 0

    def snapshot(self):
        self.calls += 1
        return self.make_snapshot(self.clock.value_ns)


def expected_graph():
    return {
        "topics": [
            {
                "name": "/odom",
                "type": "nav_msgs/msg/Odometry",
                "min_publishers": 1,
                "min_subscribers": 0,
                "qos_profile": "system_default",
                "first_message_timeout_sec": 2.0,
            }
        ],
        "services": [],
        "actions": [
            {
                "name": "/navigate_to_pose",
                "type": "nav2_msgs/action/NavigateToPose",
                "server_required": True,
            }
        ],
        "lifecycle_nodes": [
            {
                "name": name,
                "required_state": "active",
                "timeout_sec": 10.0,
                "stable_for_sec": 0.5,
            }
            for name in ("/amcl", "/bt_navigator")
        ],
    }


def ready_snapshot(now):
    return GraphSnapshot(
        observed_at_ns=now,
        topics={
            "/odom": TopicObservation(
                types=("nav_msgs/msg/Odometry",),
                publishers=1,
                subscribers=0,
                first_message_at_ns=1_790_000_000_000_000_000,
                qos_compatible=True,
            )
        },
        actions={
            "/navigate_to_pose": EndpointObservation(
                types=("nav2_msgs/action/NavigateToPose",),
                server_nodes=1,
            )
        },
        lifecycle_nodes={
            name: LifecycleObservation(
                state="active",
                observed_at_ns=1_790_000_000_000_000_000,
            )
            for name in ("/amcl", "/bt_navigator")
        },
        node_names=frozenset(("/bt_navigator", "/amcl")),
    )


class ReadinessDiagnostics(unittest.TestCase):
    def invoke(
        self,
        clock,
        observer,
        report,
        thrown=None,
        poll_interval_sec=0.1,
        ready_deadline=10.0,
        serialization_cost_ns=0,
    ):
        function = runpy.run_path(str(ROOT / "workload.py"))["wait_for_graph_readiness"]
        public_wait = partial(
            wait_for_readiness,
            now_ns=clock.now_ns,
            sleep_fn=clock.sleep,
            poll_interval_sec=poll_interval_sec,
        )

        def wait(*args, **kwargs):
            try:
                return public_wait(*args, **kwargs)
            except GraphReadinessTimeout as error:
                if thrown is not None:
                    thrown.append(error)
                raise

        serialized = False

        def serialize(observation):
            nonlocal serialized
            if not serialized:
                clock.value_ns += serialization_cost_ns
                serialized = True
            return asdict(observation)

        with (
            patch.dict(
                function.__globals__,
                {
                    "wait_for_readiness": wait,
                    "GraphReadinessTimeout": GraphReadinessTimeout,
                    "evaluate_graph": evaluate_graph,
                    "asdict": serialize,
                },
            ),
            patch.object(function.__globals__["time"], "monotonic_ns", clock.now_ns),
            patch.object(
                function.__globals__["time"],
                "monotonic",
                side_effect=lambda: clock.value_ns / 1_000_000_000,
            ),
            patch.object(
                function.__globals__["time"],
                "time_ns",
                side_effect=(1_790_000_001_000_000_000, 1_790_000_003_000_000_000),
            ),
        ):
            return function(
                expected_graph(),
                observer,
                timeout_sec=ready_deadline - clock.value_ns / 1_000_000_000,
                stable_for_sec=0.5,
                ready_deadline=ready_deadline,
                report=report,
            )

    def test_first_message_timeout_keeps_final_snapshot_and_original_exception(self):
        clock = FakeTime()

        def without_message(now):
            snapshot = ready_snapshot(now)
            return replace(
                snapshot,
                topics={
                    "/odom": replace(
                        snapshot.topics["/odom"],
                        publishers=2 if now == 2_000_000_000 else 1,
                        first_message_at_ns=None,
                    )
                },
                node_names=None,
            )

        observer = Observer(clock, without_message)
        report, thrown = {}, []
        with self.assertRaises(GraphReadinessTimeout) as caught:
            self.invoke(clock, observer, report, thrown)

        self.assertIs(caught.exception, thrown[0])
        self.assertEqual(clock.value_ns, 2_000_000_000)
        diagnostic = json.loads(json.dumps(report, allow_nan=False))["graph_readiness"]
        self.assertEqual(diagnostic["retained_snapshot_count"], observer.calls)
        self.assertEqual(diagnostic["call_started_monotonic_ns"], 0)
        self.assertEqual(diagnostic["call_finished_monotonic_ns"], 2_000_000_000)
        self.assertEqual(diagnostic["call_started_unix_ns"], 1_790_000_001_000_000_000)
        self.assertEqual(diagnostic["call_finished_unix_ns"], 1_790_000_003_000_000_000)
        snapshot = diagnostic["last_snapshot"]
        self.assertEqual(snapshot["observed_at_monotonic_ns"], 2_000_000_000)
        self.assertIsNone(snapshot["node_names"])
        topic = snapshot["topics"]["/odom"]
        self.assertEqual(topic["publishers"], 2)
        self.assertTrue(topic["qos_compatible"])
        self.assertIsNone(topic["first_message_unix_ns"])
        self.assertEqual(
            diagnostic["timeout_issues"],
            [
                {
                    "json_path": issue.json_path,
                    "message": issue.message,
                    "status": issue.status,
                }
                for issue in caught.exception.issues
            ],
        )
        self.assertEqual(
            diagnostic["snapshot_issues"][0]["status"],
            "error",
        )
        self.assertEqual(diagnostic["timeout_issues"][0]["status"], "failed")

    def test_ready_graph_returns_the_same_public_result_after_half_second(self):
        baseline_clock = FakeTime()
        baseline_observer = Observer(baseline_clock, ready_snapshot)
        expected = wait_for_readiness(
            expected_graph(),
            baseline_observer,
            timeout_sec=10.0,
            stable_for_sec=0.5,
            now_ns=baseline_clock.now_ns,
            sleep_fn=baseline_clock.sleep,
        )
        clock = FakeTime()
        observer = Observer(clock, ready_snapshot)
        report = {}
        result = self.invoke(clock, observer, report)

        self.assertEqual(result, expected)
        self.assertEqual(clock.value_ns, 500_000_000)
        self.assertEqual(observer.calls, baseline_observer.calls)
        diagnostic = json.loads(json.dumps(report, allow_nan=False))["graph_readiness"]
        self.assertEqual(diagnostic["retained_snapshot_count"], observer.calls)
        self.assertEqual(
            diagnostic["last_snapshot"]["node_names"], ["/amcl", "/bt_navigator"]
        )
        self.assertEqual(diagnostic["snapshot_issues"], [])
        self.assertNotIn("timeout_issues", diagnostic)
        self.assertEqual(
            diagnostic["last_snapshot"]["topics"]["/odom"]["first_message_unix_ns"],
            1_790_000_000_000_000_000,
        )

    def test_missing_action_keeps_the_original_ten_second_deadline(self):
        clock = FakeTime()
        observer = Observer(
            clock,
            lambda now: replace(ready_snapshot(now), actions={}),
        )
        report = {}
        with self.assertRaises(GraphReadinessTimeout) as caught:
            self.invoke(clock, observer, report)

        self.assertEqual(clock.value_ns, 10_000_000_000)
        diagnostic = json.loads(json.dumps(report, allow_nan=False))["graph_readiness"]
        self.assertEqual(
            diagnostic["last_snapshot"]["observed_at_monotonic_ns"], clock.value_ns
        )
        self.assertEqual(diagnostic["retained_snapshot_count"], observer.calls)
        self.assertEqual(diagnostic["last_snapshot"]["actions"], {})
        self.assertEqual(
            diagnostic["timeout_issues"][0]["json_path"],
            "$.expected_ros_graph.actions[0]",
        )
        self.assertEqual(
            caught.exception.issues[0].message,
            "action server /navigate_to_pose is absent",
        )

    def test_serializing_trace_after_wait_cannot_fail_an_on_time_result(self):
        clock = FakeTime()
        observer = Observer(clock, ready_snapshot)
        report = {}

        result = self.invoke(
            clock,
            observer,
            report,
            ready_deadline=0.51,
            serialization_cost_ns=20_000_000,
        )

        self.assertEqual(result.stable_for_sec, 0.5)
        self.assertEqual(clock.value_ns, 520_000_000)
        diagnostic = report["graph_readiness"]
        self.assertEqual(diagnostic["timeout_sec"], 0.51)
        self.assertEqual(diagnostic["call_finished_monotonic_ns"], 500_000_000)
        self.assertGreater(clock.value_ns / 1_000_000_000, 0.51)
        self.assertNotIn("timeout_issues", diagnostic)

    def test_result_at_absolute_deadline_keeps_the_original_timeout(self):
        clock = FakeTime()
        observer = Observer(clock, ready_snapshot)
        report = {}

        with self.assertRaises(TimeoutError) as caught:
            self.invoke(
                clock,
                observer,
                report,
                ready_deadline=0.5,
                serialization_cost_ns=20_000_000,
            )

        self.assertIs(type(caught.exception), TimeoutError)
        self.assertEqual(
            str(caught.exception),
            "published graph observation exceeded readiness deadline",
        )
        self.assertEqual(clock.value_ns, 520_000_000)
        diagnostic = report["graph_readiness"]
        self.assertEqual(diagnostic["call_finished_monotonic_ns"], 500_000_000)
        self.assertEqual(
            diagnostic["last_snapshot"]["observed_at_monotonic_ns"], 500_000_000
        )

    def test_trace_keeps_only_128_latest_snapshots_without_changing_timeout(self):
        clock = FakeTime()

        def without_message(now):
            snapshot = ready_snapshot(now)
            return replace(
                snapshot,
                topics={
                    "/odom": replace(
                        snapshot.topics["/odom"],
                        first_message_at_ns=None,
                    )
                },
            )

        observer = Observer(clock, without_message)
        report = {}
        with self.assertRaises(GraphReadinessTimeout):
            self.invoke(clock, observer, report, poll_interval_sec=0.01)

        diagnostic = json.loads(json.dumps(report, allow_nan=False))["graph_readiness"]
        self.assertEqual(clock.value_ns, 2_000_000_000)
        self.assertGreater(observer.calls, 128)
        self.assertEqual(diagnostic["snapshot_limit"], 128)
        self.assertEqual(diagnostic["retained_snapshot_count"], 128)
        self.assertEqual(len(diagnostic["snapshots"]), 128)
        self.assertEqual(
            diagnostic["snapshots"][-1]["observed_at_monotonic_ns"],
            clock.value_ns,
        )
        self.assertGreater(
            diagnostic["snapshots"][0]["observed_at_monotonic_ns"],
            0,
        )

    def test_observer_error_is_preserved_without_inventing_a_snapshot(self):
        clock = FakeTime()
        failure = RuntimeError("observer failed before its first snapshot")

        def unavailable(now):
            raise failure

        observer = Observer(clock, unavailable)
        report = {}
        with self.assertRaises(RuntimeError) as caught:
            self.invoke(clock, observer, report)

        self.assertIs(caught.exception, failure)
        self.assertEqual(clock.value_ns, 0)
        diagnostic = json.loads(json.dumps(report, allow_nan=False))["graph_readiness"]
        self.assertEqual(diagnostic["retained_snapshot_count"], 0)
        self.assertEqual(diagnostic["snapshots"], [])
        self.assertNotIn("last_snapshot", diagnostic)
        self.assertNotIn("timeout_issues", diagnostic)


if __name__ == "__main__":
    unittest.main()
