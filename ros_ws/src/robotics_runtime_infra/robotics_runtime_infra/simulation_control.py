from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path
from typing import Any

import rclpy
from rclpy.node import Node
from rclpy.qos import qos_profile_sensor_data
from rosgraph_msgs.msg import Clock
from simulation_interfaces.msg import Result, SimulationState, SimulatorFeatures
from simulation_interfaces.srv import (
    GetSimulationState,
    GetSimulatorFeatures,
    SetSimulationState,
    StepSimulation,
)


class ConformanceError(RuntimeError):
    """The simulator does not satisfy the required standard interfaces."""


class SimulationControl(Node):
    def __init__(self, namespace: str, timeout_sec: float) -> None:
        super().__init__("simulation_control")
        self._namespace = "/" + namespace.strip("/")
        self._timeout_sec = timeout_sec
        self._clock_ns: int | None = None
        self._service_clients = {
            "get_simulator_features": self.create_client(
                GetSimulatorFeatures,
                self._service_name("get_simulator_features"),
            ),
            "get_simulation_state": self.create_client(
                GetSimulationState,
                self._service_name("get_simulation_state"),
            ),
            "set_simulation_state": self.create_client(
                SetSimulationState,
                self._service_name("set_simulation_state"),
            ),
            "step_simulation": self.create_client(
                StepSimulation,
                self._service_name("step_simulation"),
            ),
        }
        self.create_subscription(
            Clock,
            "/clock",
            self._on_clock,
            qos_profile_sensor_data,
        )

    def _on_clock(self, message: Clock) -> None:
        self._clock_ns = message.clock.sec * 1_000_000_000 + message.clock.nanosec

    def _service_name(self, suffix: str) -> str:
        return f"{self._namespace}/{suffix}"

    def _call(self, suffix: str, request: Any) -> Any:
        client = self._service_clients[suffix]
        if not client.wait_for_service(timeout_sec=self._timeout_sec):
            raise ConformanceError(f"service is unavailable: {client.srv_name}")
        future = client.call_async(request)
        rclpy.spin_until_future_complete(self, future, timeout_sec=self._timeout_sec)
        if not future.done() or future.result() is None:
            raise ConformanceError(f"service call timed out: {client.srv_name}")
        return future.result()

    @staticmethod
    def _require_ok(
        response: Any, operation: str, *, allow_already: bool = False
    ) -> None:
        accepted = {Result.RESULT_OK}
        if allow_already:
            accepted.add(SetSimulationState.Response.ALREADY_IN_TARGET_STATE)
        if response.result.result not in accepted:
            raise ConformanceError(
                f"{operation} failed with result {response.result.result}: "
                f"{response.result.error_message}"
            )

    def features(self) -> frozenset[int]:
        response = self._call(
            "get_simulator_features",
            GetSimulatorFeatures.Request(),
        )
        return frozenset(response.features.features)

    def set_state(self, state: int) -> None:
        request = SetSimulationState.Request()
        request.state.state = state
        response = self._call("set_simulation_state", request)
        self._require_ok(response, "set_simulation_state", allow_already=True)

    def state(self) -> int:
        response = self._call(
            "get_simulation_state",
            GetSimulationState.Request(),
        )
        self._require_ok(response, "get_simulation_state")
        return response.state.state

    def step(self, steps: int) -> None:
        request = StepSimulation.Request()
        request.steps = steps
        response = self._call("step_simulation", request)
        self._require_ok(response, "step_simulation")

    def wait_for_clock_after(self, previous_ns: int | None) -> int:
        deadline = time.monotonic() + self._timeout_sec
        while time.monotonic() < deadline:
            rclpy.spin_once(self, timeout_sec=0.1)
            if self._clock_ns is not None and (
                previous_ns is None or self._clock_ns > previous_ns
            ):
                return self._clock_ns
        raise ConformanceError("/clock did not advance before the timeout")

    def wait_for_quiescent_clock(self, stable_sec: float = 0.25) -> int:
        deadline = time.monotonic() + self._timeout_sec
        stable_since = time.monotonic()
        observed_ns = self._clock_ns
        while time.monotonic() < deadline:
            rclpy.spin_once(self, timeout_sec=min(0.05, stable_sec))
            if self._clock_ns is None:
                continue
            if self._clock_ns != observed_ns:
                observed_ns = self._clock_ns
                stable_since = time.monotonic()
            elif time.monotonic() - stable_since >= stable_sec:
                return self._clock_ns
        raise ConformanceError("/clock did not become quiescent while paused")

    def wait_for_clock_at_least(self, target_ns: int) -> int:
        deadline = time.monotonic() + self._timeout_sec
        while time.monotonic() < deadline:
            rclpy.spin_once(self, timeout_sec=0.05)
            if self._clock_ns is not None and self._clock_ns >= target_ns:
                return self._clock_ns
        raise ConformanceError(f"/clock did not reach {target_ns} before the timeout")

    def verify(self, steps: int, step_size_ns: int) -> dict[str, Any]:
        features = self.features()
        required = {
            SimulatorFeatures.SIMULATION_STATE_GETTING,
            SimulatorFeatures.SIMULATION_STATE_SETTING,
            SimulatorFeatures.SIMULATION_STATE_PAUSE,
            SimulatorFeatures.STEP_SIMULATION_SINGLE,
        }
        if steps > 1:
            required.add(SimulatorFeatures.STEP_SIMULATION_MULTIPLE)
        missing = sorted(required - features)
        if missing:
            raise ConformanceError(f"simulator features are missing: {missing}")

        self.set_state(SimulationState.STATE_PLAYING)
        playing_clock_ns = self.wait_for_clock_after(None)
        self.set_state(SimulationState.STATE_PAUSED)
        paused_clock_ns = self.wait_for_quiescent_clock()
        expected_stepped_clock_ns = paused_clock_ns + steps * step_size_ns
        self.step(steps)
        self.wait_for_clock_at_least(expected_stepped_clock_ns)
        stepped_clock_ns = self.wait_for_quiescent_clock()
        if stepped_clock_ns != expected_stepped_clock_ns:
            raise ConformanceError(
                "step_simulation advanced /clock by "
                f"{stepped_clock_ns - paused_clock_ns} ns; "
                f"expected {steps * step_size_ns} ns"
            )
        if self.state() != SimulationState.STATE_PAUSED:
            raise ConformanceError("step_simulation did not return to paused state")
        self.set_state(SimulationState.STATE_PLAYING)
        resumed_clock_ns = self.wait_for_clock_after(stepped_clock_ns)

        return {
            "schema_version": "simulation-conformance.v1",
            "service_namespace": self._namespace,
            "features": sorted(features),
            "steps": steps,
            "step_size_ns": step_size_ns,
            "clock": {
                "playing_ns": playing_clock_ns,
                "paused_ns": paused_clock_ns,
                "stepped_ns": stepped_clock_ns,
                "resumed_ns": resumed_clock_ns,
            },
            "status": "passed",
        }


def _positive_int(value: str) -> int:
    parsed = int(value)
    if parsed < 1:
        raise argparse.ArgumentTypeError("value must be a positive integer")
    return parsed


def _positive_float(value: str) -> float:
    parsed = float(value)
    if parsed <= 0:
        raise argparse.ArgumentTypeError("value must be positive")
    return parsed


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        description="Control a simulator through ROS 2 simulation_interfaces."
    )
    parser.add_argument("--namespace", default="simulator")
    parser.add_argument("--timeout-sec", default=30.0, type=_positive_float)
    subparsers = parser.add_subparsers(dest="command", required=True)

    verify = subparsers.add_parser("verify", help="Run the conformance checks once.")
    verify.add_argument("--steps", default=5, type=_positive_int)
    verify.add_argument("--step-size-ns", default=1_000_000, type=_positive_int)
    verify.add_argument("--report", type=Path)

    step = subparsers.add_parser(
        "step", help="Advance a paused simulator periodically."
    )
    step.add_argument("--steps", default=1, type=_positive_int)
    step.add_argument("--interval-sec", default=0.2, type=_positive_float)
    return parser


def main() -> int:
    args = _parser().parse_args()
    rclpy.init()
    node = SimulationControl(args.namespace, args.timeout_sec)
    try:
        if args.command == "verify":
            report = node.verify(args.steps, args.step_size_ns)
            serialized = json.dumps(report, indent=2, sort_keys=True) + "\n"
            if args.report is not None:
                args.report.parent.mkdir(parents=True, exist_ok=True)
                args.report.write_text(serialized, encoding="utf-8")
            sys.stdout.write(serialized)
            return 0

        node.set_state(SimulationState.STATE_PAUSED)
        while rclpy.ok():
            node.step(args.steps)
            time.sleep(args.interval_sec)
        return 0
    except (ConformanceError, OSError, ValueError) as error:
        print(f"simulation control failed: {error}", file=sys.stderr)
        return 1
    finally:
        node.destroy_node()
        rclpy.shutdown()


if __name__ == "__main__":
    raise SystemExit(main())
