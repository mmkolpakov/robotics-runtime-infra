"""Exercise control failures at the service/clock boundary without a ROS server."""

from __future__ import annotations

import contextlib
import importlib.util
import io
import sys
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest import mock

ROOT = Path(__file__).resolve().parents[2]
SOURCE = (
    ROOT
    / "ros_ws/src/robotics_runtime_infra/robotics_runtime_infra"
    / "simulation_control.py"
)
# Import-only stand-ins; live CI supplies the actual generated ROS types.
RESULT = SimpleNamespace(RESULT_OK=1, RESULT_OPERATION_FAILED=4)
STATE = SimpleNamespace(STATE_PAUSED=2, STATE_PLAYING=1)
FEATURES = SimpleNamespace(
    SIMULATION_STATE_GETTING=24,
    SIMULATION_STATE_SETTING=25,
    SIMULATION_STATE_PAUSE=26,
    STEP_SIMULATION_SINGLE=31,
    STEP_SIMULATION_MULTIPLE=32,
)
ROS = SimpleNamespace()
SET_STATE = SimpleNamespace(
    Request=lambda: SimpleNamespace(state=SimpleNamespace(state=0)),
    Response=SimpleNamespace(ALREADY_IN_TARGET_STATE=101),
)
modules = {
    "rclpy": ROS,
    "rclpy.node": SimpleNamespace(Node=object),
    "rclpy.qos": SimpleNamespace(qos_profile_sensor_data=object()),
    "rosgraph_msgs.msg": SimpleNamespace(Clock=object),
    "simulation_interfaces.msg": SimpleNamespace(
        Result=RESULT, SimulationState=STATE, SimulatorFeatures=FEATURES
    ),
    "simulation_interfaces.srv": SimpleNamespace(
        GetSimulationState=SimpleNamespace(Request=SimpleNamespace),
        GetSimulatorFeatures=SimpleNamespace(Request=SimpleNamespace),
        SetSimulationState=SET_STATE,
        StepSimulation=SimpleNamespace(Request=SimpleNamespace),
    ),
}
SPEC = importlib.util.spec_from_file_location("simulation_control", SOURCE)
assert SPEC is not None and SPEC.loader is not None
control = importlib.util.module_from_spec(SPEC)
with mock.patch.dict(sys.modules, modules):
    SPEC.loader.exec_module(control)


class Transport:
    """Only service replies and arriving clock samples are simulated."""

    def __init__(self):
        self.node = object.__new__(control.SimulationControl)
        self.node._namespace = "/simulator"
        self.node._timeout_sec = 1.0
        self.node._clock_ns = 100
        self.elapsed = 0.0
        self.phase = "initial"
        self.actual_state = STATE.STATE_PAUSED
        self.features = set(vars(FEATURES).values())
        self.advance_initial = True
        self.advance_resume = True
        self.wrong_state = {}
        self.delayed_paused = []
        self.state_read_delays = []
        self.overshoot = 0
        self.final_state = STATE.STATE_PAUSED
        self.failed_operation = None
        self.already = False
        self.steps = []
        self.step_size_ns = 10
        self.completion_spins = 0
        self.pending_clock = None
        self.pending_spins = 0

    def reply(self, suffix, request):
        result = SimpleNamespace(result=RESULT.RESULT_OK, error_message="")
        if suffix == self.failed_operation:
            result = SimpleNamespace(
                result=RESULT.RESULT_OPERATION_FAILED, error_message="provider failure"
            )
        if suffix == "get_simulator_features":
            return SimpleNamespace(features=SimpleNamespace(features=self.features))
        if suffix == "set_simulation_state":
            self.phase = (
                "paused"
                if request.state.state == STATE.STATE_PAUSED
                else "resumed"
                if self.steps
                else "playing"
            )
            self.actual_state = self.wrong_state.get(self.phase, request.state.state)
            if self.already:
                result.result = SET_STATE.Response.ALREADY_IN_TARGET_STATE
        if suffix == "get_simulation_state":
            if self.state_read_delays:
                self.elapsed += self.state_read_delays.pop(0)
            state = self.actual_state
            if self.phase == "paused" and self.delayed_paused:
                state = self.delayed_paused.pop(0)
            return SimpleNamespace(result=result, state=SimpleNamespace(state=state))
        if suffix == "step_simulation" and result.result == RESULT.RESULT_OK:
            self.queue_step(request.steps)
        return SimpleNamespace(result=result)

    def queue_step(self, steps):
        if self.pending_clock is not None:
            raise AssertionError("next step requested before the prior step completed")
        self.steps.append(steps)
        target = self.node._clock_ns + steps * self.step_size_ns + self.overshoot
        self.phase = "stepped"
        if self.completion_spins == 0:
            self.sample(target)
            self.actual_state = self.final_state
        else:
            # The native service acknowledges a queued command before execution.
            self.pending_clock = target
            self.pending_spins = self.completion_spins
            self.actual_state = STATE.STATE_PLAYING

    def sample(self, value):
        self.node._on_clock(
            SimpleNamespace(clock=SimpleNamespace(sec=0, nanosec=value))
        )

    def spin(self, node, timeout_sec):
        self.elapsed += timeout_sec
        if self.pending_clock is not None and self.pending_spins is not None:
            self.pending_spins -= 1
            if self.pending_spins == 0:
                self.sample(self.pending_clock)
                self.pending_clock = None
                self.actual_state = self.final_state
        advancing = (
            self.phase == "playing"
            and self.advance_initial
            or self.phase == "resumed"
            and self.advance_resume
        )
        if advancing:
            self.sample(100 if node._clock_ns is None else node._clock_ns + 10)


class SimulationControlTests(unittest.TestCase):
    @contextlib.contextmanager
    def transport_boundary(self):
        transport = Transport()
        with (
            mock.patch.object(transport.node, "_call", side_effect=transport.reply),
            mock.patch.object(
                control.time, "monotonic", side_effect=lambda: transport.elapsed
            ),
            mock.patch.object(ROS, "spin_once", transport.spin, create=True),
        ):
            yield transport

    def setUp(self):
        self.transport = self.enterContext(self.transport_boundary())
        self.node = self.transport.node

    def verify(self):
        return self.node.verify(5, 10)

    def test_exact_step_and_resume_with_existing_already_state_reply(self):
        self.transport.already = True
        report = self.verify()
        self.assertEqual(report["status"], "passed")
        clock = report["clock"]
        self.assertGreater(clock["playing_ns"], 100)
        self.assertEqual(clock["stepped_ns"] - clock["paused_ns"], 50)
        self.assertGreater(clock["resumed_ns"], clock["stepped_ns"])

    def test_cached_clock_cannot_prove_initial_playing(self):
        self.transport.advance_initial = False
        with self.assertRaisesRegex(control.ConformanceError, "did not advance"):
            self.verify()
        self.assertEqual(self.transport.steps, [])
        self.assertLessEqual(self.transport.elapsed, 1.1)

    def test_unknown_clock_requires_two_advancing_samples(self):
        self.node._clock_ns = None
        self.assertGreater(self.verify()["clock"]["playing_ns"], 100)

    def test_wrong_state_blocks_exact_step_or_passing_resume(self):
        for phase, state in (
            ("playing", STATE.STATE_PAUSED),
            ("paused", STATE.STATE_PLAYING),
            ("resumed", STATE.STATE_PAUSED),
        ):
            with self.subTest(phase=phase), self.transport_boundary() as transport:
                transport.wrong_state[phase] = state
                with self.assertRaisesRegex(control.ConformanceError, "state"):
                    transport.node.verify(5, 10)
                if phase != "resumed":
                    self.assertEqual(transport.steps, [])

    def test_delayed_paused_readback_is_allowed_before_step(self):
        self.transport.delayed_paused = [STATE.STATE_PLAYING] * 2
        self.assertEqual(self.verify()["status"], "passed")
        self.assertEqual(self.transport.delayed_paused, [])

    def test_late_target_readback_cannot_confirm_state_before_timeout(self):
        for delays in ([1.1], [0.0, 1.1]):
            with self.subTest(delays=delays), self.transport_boundary() as transport:
                transport.phase = "paused"
                transport.actual_state = STATE.STATE_PLAYING
                transport.state_read_delays = delays.copy()
                if len(delays) > 1:
                    transport.delayed_paused = [STATE.STATE_PAUSED]
                with self.assertRaisesRegex(
                    control.ConformanceError, "before the timeout"
                ):
                    transport.node.wait_for_state(STATE.STATE_PLAYING)

    def test_step_overshoot_and_wrong_final_state_remain_rejected(self):
        self.transport.overshoot = 1
        with self.assertRaisesRegex(control.ConformanceError, "expected 50 ns"):
            self.verify()
        self.transport.overshoot = 0
        self.transport.final_state = STATE.STATE_PLAYING
        with self.assertRaisesRegex(control.ConformanceError, "return to paused"):
            self.verify()

    def test_resume_must_advance_clock(self):
        self.transport.advance_resume = False
        with self.assertRaisesRegex(control.ConformanceError, "did not advance"):
            self.verify()

    def test_missing_multi_step_capability_blocks_control(self):
        self.transport.features.remove(FEATURES.STEP_SIMULATION_MULTIPLE)
        with self.assertRaisesRegex(control.ConformanceError, "features are missing"):
            self.verify()
        self.assertEqual(self.transport.phase, "initial")

    def test_native_operation_failures_are_preserved(self):
        for suffix in (
            "set_simulation_state",
            "get_simulation_state",
            "step_simulation",
        ):
            with (
                self.subTest(operation=suffix),
                self.transport_boundary() as transport,
            ):
                transport.failed_operation = suffix
                with self.assertRaisesRegex(
                    control.ConformanceError, "provider failure"
                ):
                    transport.node.verify(5, 10)

    def test_unavailable_and_timed_out_service_remain_failures(self):
        client = mock.Mock(srv_name="/simulator/step_simulation")
        self.node._service_clients = {"step_simulation": client}
        client.wait_for_service.return_value = False
        with self.assertRaisesRegex(control.ConformanceError, "unavailable"):
            control.SimulationControl._call(self.node, "step_simulation", object())
        client.wait_for_service.return_value = True
        client.call_async.return_value = SimpleNamespace(done=lambda: False)
        with mock.patch.object(ROS, "spin_until_future_complete", create=True):
            with self.assertRaisesRegex(control.ConformanceError, "timed out"):
                control.SimulationControl._call(self.node, "step_simulation", object())

    def test_failed_probe_does_not_publish_report_or_skip_cleanup(self):
        self.transport.advance_initial = False
        self.node.destroy_node = mock.Mock()
        with tempfile.TemporaryDirectory() as temporary:
            report = Path(temporary) / "conformance.json"
            arguments = [
                "control",
                "verify",
                "--step-size-ns",
                "10",
                "--report",
                str(report),
            ]
            with (
                mock.patch.object(sys, "argv", arguments),
                mock.patch.object(control, "SimulationControl", return_value=self.node),
                mock.patch.object(ROS, "init", create=True),
                mock.patch.object(ROS, "shutdown", create=True) as shutdown,
                contextlib.redirect_stderr(io.StringIO()),
                contextlib.redirect_stdout(io.StringIO()) as output,
            ):
                self.assertEqual(control.main(), 1)
            self.assertFalse(report.exists())
            self.assertEqual(output.getvalue(), "")
            self.node.destroy_node.assert_called_once()
            shutdown.assert_called_once()

    def run_stepper(self, transport, arguments=()):
        node = transport.node
        node.destroy_node = mock.Mock()
        sleeps = []
        with (
            mock.patch.object(
                sys, "argv", ["control", "step", "--steps", "3", *arguments]
            ),
            mock.patch.object(control, "SimulationControl", return_value=node),
            mock.patch.object(ROS, "init", create=True),
            mock.patch.object(ROS, "shutdown", create=True) as shutdown,
            mock.patch.object(ROS, "ok", side_effect=[True, True, False], create=True),
            mock.patch.object(
                control.time,
                "sleep",
                side_effect=lambda interval: sleeps.append((interval, node._clock_ns)),
            ),
            contextlib.redirect_stderr(io.StringIO()) as errors,
        ):
            result = control.main()
        node.destroy_node.assert_called_once()
        shutdown.assert_called_once()
        return result, errors.getvalue(), sleeps

    def test_periodic_command_waits_for_acknowledged_step_completion(self):
        self.transport.step_size_ns = 1_000_000
        self.transport.completion_spins = 3
        result, errors, sleeps = self.run_stepper(
            self.transport, ["--interval-sec", "0.01"]
        )
        self.assertEqual((result, errors), (0, ""))
        self.assertEqual(self.transport.steps, [3, 3])
        self.assertEqual(sleeps, [(0.01, 3_000_100), (0.01, 6_000_100)])
        self.assertIsNone(self.transport.pending_clock)

    def test_periodic_command_refuses_missing_or_overshot_completion(self):
        for completion_spins, overshoot, message in (
            (None, 0, "did not reach"),
            (3, 1, "expected"),
        ):
            with self.subTest(message=message), self.transport_boundary() as transport:
                transport.step_size_ns = 1_000_000
                transport.completion_spins = completion_spins
                transport.overshoot = overshoot
                result, errors, sleeps = self.run_stepper(transport)
                self.assertEqual(result, 1)
                self.assertIn(message, errors)
                self.assertEqual(transport.steps, [3])
                self.assertEqual(sleeps, [])

    def test_periodic_command_requires_paused_completion_state(self):
        self.transport.step_size_ns = 1_000_000
        self.transport.completion_spins = 3
        self.transport.final_state = STATE.STATE_PLAYING
        result, errors, sleeps = self.run_stepper(self.transport)
        self.assertEqual(result, 1)
        self.assertIn("not confirmed", errors)
        self.assertEqual(self.transport.steps, [3])
        self.assertEqual(sleeps, [])

    def test_periodic_command_honors_declared_step_size_and_default_interval(self):
        self.transport.step_size_ns = 20
        self.transport.completion_spins = 3
        result, errors, sleeps = self.run_stepper(
            self.transport, ["--step-size-ns", "20"]
        )
        self.assertEqual((result, errors), (0, ""))
        self.assertEqual(self.transport.steps, [3, 3])
        self.assertEqual(sleeps, [(0.2, 160), (0.2, 220)])

    def test_periodic_command_refuses_missing_initial_clock_before_step(self):
        self.node._clock_ns = None
        result, errors, sleeps = self.run_stepper(self.transport)
        self.assertEqual(result, 1)
        self.assertIn("did not become quiescent", errors)
        self.assertEqual(self.transport.steps, [])
        self.assertEqual(sleeps, [])

    def test_periodic_command_refuses_unconfirmed_pause_before_any_step(self):
        self.transport.wrong_state["paused"] = STATE.STATE_PLAYING
        self.node.destroy_node = mock.Mock()
        with (
            mock.patch.object(sys, "argv", ["control", "step"]),
            mock.patch.object(control, "SimulationControl", return_value=self.node),
            mock.patch.object(ROS, "init", create=True),
            mock.patch.object(ROS, "shutdown", create=True),
            mock.patch.object(ROS, "ok", return_value=True, create=True),
            contextlib.redirect_stderr(io.StringIO()) as errors,
        ):
            self.assertEqual(control.main(), 1)
        self.assertIn("not confirmed before the timeout", errors.getvalue())
        self.assertEqual(self.transport.steps, [])
        self.node.destroy_node.assert_called_once()

    def test_timeout_and_interval_reject_nonfinite_or_nonpositive_values(self):
        for value in ("nan", "inf", "-inf", "0", "-0.1"):
            for arguments in (
                [f"--timeout-sec={value}", "verify"],
                ["step", f"--interval-sec={value}"],
            ):
                with self.subTest(arguments=arguments):
                    with contextlib.redirect_stderr(io.StringIO()):
                        with self.assertRaises(SystemExit) as exit_status:
                            control._parser().parse_args(arguments)
                    self.assertEqual(exit_status.exception.code, 2)
        self.assertEqual(control._positive_float("0.125"), 0.125)


if __name__ == "__main__":
    unittest.main()
