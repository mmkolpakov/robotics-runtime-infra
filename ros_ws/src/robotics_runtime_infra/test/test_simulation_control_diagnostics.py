from __future__ import annotations

import json
import os
import unittest
from unittest.mock import Mock, patch

from rosgraph_msgs.msg import Clock
from simulation_interfaces.msg import Result, SimulationState
from simulation_interfaces.srv import GetSimulationState, StepSimulation

from robotics_runtime_infra import simulation_control as module


class TestSimulationDiagnostics(unittest.TestCase):
    def setUp(self):
        spin_once = patch.object(module.rclpy, "spin_once")
        spin_once.start()
        self.addCleanup(spin_once.stop)

    def node(self, *, diagnostics: bool = True):
        # Pure source controls: no Node constructor, ROS context or graph.
        node = object.__new__(module.SimulationControl)
        node._timeout_sec = 1.0
        node._namespace = "/simulator"
        node._clock_ns = 1_000_000
        node._clock_callback_times = None
        self.events = []
        node._diagnostics = (
            module._DiagnosticEvents(self.events.append) if diagnostics else None
        )
        return node

    def decoded_events(self):
        return [json.loads(event) for event in self.events]

    def clients(self, node):
        step_response = StepSimulation.Response()
        step_response.result.result = Result.RESULT_OK
        state_response = GetSimulationState.Response()
        state_response.result.result = Result.RESULT_OK
        state_response.state.state = SimulationState.STATE_PAUSED
        step_future = Mock()
        step_future.done.return_value = True
        step_future.result.return_value = step_response
        state_future = Mock()
        state_future.done.return_value = True
        state_future.result.return_value = state_response
        step_client = Mock(srv_name="/simulator/step_simulation")
        step_client.wait_for_service.return_value = True
        step_client.call_async.return_value = step_future
        state_client = Mock(srv_name="/simulator/get_simulation_state")
        state_client.wait_for_service.return_value = True
        state_client.call_async.return_value = state_future
        node._service_clients = {
            "step_simulation": step_client,
            "get_simulation_state": state_client,
        }
        return step_client, state_client

    def test_default_off_performs_original_calls_without_diagnostic_timestamps(self):
        node = self.node(diagnostics=False)
        step_client, state_client = self.clients(node)
        clock = Clock()
        clock.clock.nanosec = 2_000_000

        def spin(_node, future, **_kwargs):
            if future is step_client.call_async.return_value:
                node._on_clock(clock)

        with (
            patch.object(module.rclpy, "spin_until_future_complete", side_effect=spin),
            patch.object(
                module.time,
                "time_ns",
                side_effect=AssertionError("diagnostic clock read"),
            ),
            patch.object(
                module.time,
                "monotonic_ns",
                side_effect=AssertionError("diagnostic clock read"),
            ),
        ):
            self.assertEqual(node.step_and_wait(1_000_000, 1, 1_000_000), 2_000_000)
        self.assertEqual(step_client.call_async.call_args.args[0].steps, 1)
        self.assertEqual(state_client.call_async.call_count, 1)
        self.assertEqual(self.events, [])

    def test_clock_callback_before_response_preserves_its_actual_timestamp(self):
        node = self.node()
        step_client, _ = self.clients(node)
        clock = Clock()
        clock.clock.nanosec = 2_000_000

        def spin(_node, future, **_kwargs):
            if future is step_client.call_async.return_value:
                node._on_clock(clock)

        with (
            patch.object(module.rclpy, "spin_until_future_complete", side_effect=spin),
            patch.object(module.time, "time_ns", side_effect=range(100, 140)),
            patch.object(module.time, "monotonic_ns", side_effect=range(200, 240)),
        ):
            self.assertEqual(node.step_and_wait(1_000_000, 1, 1_000_000), 2_000_000)
        events = self.decoded_events()
        response = next(
            event for event in events if event["phase"] == "response_received"
        )
        observed = next(event for event in events if event["phase"] == "clock_observed")
        self.assertLess(observed["callback_utc_ns"], response["utc_ns"])
        self.assertLess(observed["callback_monotonic_ns"], response["monotonic_ns"])
        self.assertEqual(observed["source_time_ns"], 2_000_000)
        self.assertEqual(observed["observation_source"], "rclpy_subscription_callback")
        self.assertEqual(events[-1]["phase"], "state_observed")
        self.assertEqual(events[-1]["state"], SimulationState.STATE_PAUSED)
        self.assertTrue(all(event["timestamp_units"] == "ns" for event in events))

    def test_unavailable_service_has_no_issued_request_or_response(self):
        node = self.node()
        step_client, _ = self.clients(node)
        step_client.wait_for_service.return_value = False
        with self.assertRaisesRegex(module.ConformanceError, "service is unavailable"):
            node.step(1)
        step_client.call_async.assert_not_called()
        self.assertEqual(
            [event["phase"] for event in self.decoded_events()], ["service_unavailable"]
        )

    def test_missing_response_keeps_timeout_without_fabricating_ack(self):
        for future_done in (False, True):
            with self.subTest(future_done=future_done):
                node = self.node()
                step_client, _ = self.clients(node)
                step_client.call_async.return_value.done.return_value = future_done
                step_client.call_async.return_value.result.return_value = None
                with patch.object(module.rclpy, "spin_until_future_complete"):
                    with self.assertRaisesRegex(
                        module.ConformanceError, "service call timed out"
                    ):
                        node.step(1)
                self.assertEqual(
                    [event["phase"] for event in self.decoded_events()],
                    ["request_issued", "response_unavailable"],
                )

    def test_missing_clock_after_step_response_has_no_clock_or_paused_claim(self):
        node = self.node()
        _, state_client = self.clients(node)
        with (
            patch.object(module.rclpy, "spin_until_future_complete"),
            patch.object(module.rclpy, "spin_once"),
            patch.object(module.time, "monotonic", side_effect=[0.0, 0.5, 1.5]),
        ):
            with self.assertRaisesRegex(
                module.ConformanceError, "/clock did not reach"
            ):
                node.step_and_wait(1_000_000, 1, 1_000_000)
        phases = [event["phase"] for event in self.decoded_events()]
        self.assertEqual(
            phases, ["request_issued", "response_received", "step_response"]
        )
        state_client.call_async.assert_not_called()

    def test_rejected_step_preserves_result_code_and_original_refusal(self):
        node = self.node()
        step_client, state_client = self.clients(node)
        step_client.call_async.return_value.result.return_value.result.result = (
            Result.RESULT_OPERATION_FAILED
        )
        with patch.object(module.rclpy, "spin_until_future_complete"):
            with self.assertRaisesRegex(
                module.ConformanceError, "step_simulation failed"
            ):
                node.step_and_wait(1_000_000, 1, 1_000_000)
        events = self.decoded_events()
        self.assertEqual(events[-1]["phase"], "step_response")
        self.assertEqual(events[-1]["result_code"], Result.RESULT_OPERATION_FAILED)
        state_client.call_async.assert_not_called()

    def test_wrong_clock_is_retained_without_turning_readback_into_completion(self):
        node = self.node()
        step_client, _ = self.clients(node)
        clock = Clock()
        clock.clock.nanosec = 3_000_000

        def spin(_node, future, **_kwargs):
            if future is step_client.call_async.return_value:
                node._on_clock(clock)

        with patch.object(module.rclpy, "spin_until_future_complete", side_effect=spin):
            with self.assertRaisesRegex(module.ConformanceError, "expected 2000000"):
                node.step_and_wait(1_000_000, 1, 1_000_000)
        events = self.decoded_events()
        self.assertEqual(
            next(e for e in events if e["phase"] == "clock_observed")["source_time_ns"],
            3_000_000,
        )
        self.assertNotIn("passed", {event["phase"] for event in events})

    def test_event_bound_emits_one_explicit_drop_marker_and_keeps_work_callable(self):
        events = []
        diagnostic = module._DiagnosticEvents(events.append)
        with patch.object(module, "MAX_DIAGNOSTIC_EVENTS", 2):
            for _ in range(20):
                diagnostic.record(
                    "request_issued", service="/simulator/step_simulation"
                )
        decoded = [json.loads(event) for event in events]
        self.assertEqual(len(decoded), 3)
        self.assertEqual(decoded[-1]["phase"], "diagnostics_truncated")
        self.assertEqual(decoded[-1]["recorded_events"], 2)
        self.assertEqual(decoded[-1]["dropped_events_lower_bound"], 1)
        self.assertFalse(decoded[-1]["absence_proven"])

    def test_byte_bound_reserves_an_explicit_truncation_marker(self):
        events = []
        diagnostic = module._DiagnosticEvents(events.append)
        with patch.object(module, "MAX_DIAGNOSTIC_BYTES", 800):
            for _ in range(20):
                diagnostic.record(
                    "request_issued", service="/simulator/step_simulation"
                )
        self.assertLessEqual(sum(len(event.encode()) + 1 for event in events), 800)
        self.assertEqual(json.loads(events[-1])["phase"], "diagnostics_truncated")

    def test_one_oversized_diagnostic_field_cannot_bypass_line_bound(self):
        events = []
        diagnostic = module._DiagnosticEvents(events.append)
        diagnostic.record("request_issued", service="x" * 4096)
        self.assertEqual(len(events), 1)
        self.assertEqual(json.loads(events[0])["phase"], "diagnostics_truncated")
        self.assertLessEqual(
            len(events[0].encode()) + 1, module.MAX_DIAGNOSTIC_EVENT_BYTES
        )

    def test_cli_diagnostics_default_off_and_explicit_opt_in(self):
        with patch.dict(os.environ, {"ROBOTICS_SIMULATION_DIAGNOSTICS": "0"}):
            self.assertFalse(module._parser().parse_args(["step"]).diagnostics)
            self.assertTrue(
                module._parser().parse_args(["step", "--diagnostics"]).diagnostics
            )
        with patch.dict(os.environ, {"ROBOTICS_SIMULATION_DIAGNOSTICS": "1"}):
            self.assertTrue(module._parser().parse_args(["step"]).diagnostics)
        with patch.dict(os.environ, {"ROBOTICS_SIMULATION_DIAGNOSTICS": "invalid"}):
            with self.assertRaises(SystemExit) as error:
                module._parser()
            self.assertEqual(error.exception.code, 2)


if __name__ == "__main__":
    unittest.main()
