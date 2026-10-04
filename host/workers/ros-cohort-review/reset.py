import json
import sys
import time
import math
import rclpy
from rclpy.qos import qos_profile_sensor_data
from rosgraph_msgs.msg import Clock
from rosidl_runtime_py.convert import message_to_ordereddict
from simulation_interfaces.msg import Result, SimulationState, SimulatorFeatures
from simulation_interfaces.srv import (
    GetEntities,
    GetEntityState,
    SetEntityState,
    SpawnEntity,
    ResetSimulation,
)
from robotics_runtime_infra.simulation_control import SimulationControl

rclpy.init()
node = SimulationControl("/simulator", 40)
report = {
    "scope": "fresh independent native stock reset/unsupported effect probe",
    "requests": [],
}
samples = []
passed = False
node.create_subscription(
    Clock,
    "/clock",
    lambda m: (
        samples.append(str(m.clock.sec * 1000000000 + m.clock.nanosec))
        if len(samples) < 20000
        else None
    ),
    qos_profile_sensor_data,
)


def call(kind, name, request):
    client = node.create_client(kind, "/simulator/" + name)
    if not client.wait_for_service(timeout_sec=40):
        raise RuntimeError("native service unavailable: " + name)
    started = time.monotonic()
    future = client.call_async(request)
    rclpy.spin_until_future_complete(node, future, timeout_sec=40)
    if not future.done() or future.result() is None:
        raise RuntimeError("native service timeout: " + name)
    response = future.result()
    report["requests"].append(
        {
            "service": client.srv_name,
            "request": message_to_ordereddict(request),
            "response": message_to_ordereddict(response),
            "durationMs": (time.monotonic() - started) * 1000,
        }
    )
    node.destroy_client(client)
    return response


def entities():
    value = call(GetEntities, "get_entities", GetEntities.Request())
    assert value.result.result == Result.RESULT_OK
    return list(value.entities)


def state(entity):
    req = GetEntityState.Request()
    req.entity = entity
    value = call(GetEntityState, "get_entity_state", req)
    return value


try:
    features = node.features()
    report["features"] = sorted(features)
    report["initialNativeState"] = node.state()
    assert SimulatorFeatures.SIMULATION_RESET in features
    assert not any(
        v in features
        for v in [
            SimulatorFeatures.SIMULATION_RESET_TIME,
            SimulatorFeatures.SIMULATION_RESET_STATE,
            SimulatorFeatures.SIMULATION_RESET_SPAWNED,
        ]
    )
    node.set_state(SimulationState.STATE_PLAYING)
    node.wait_for_state(SimulationState.STATE_PLAYING)
    report["initialPlayingClockNs"] = str(node.wait_for_clock_after(None))
    report["initialEntities"] = entities()
    assert "reset_probe_robot" not in report["initialEntities"]
    spawn = SpawnEntity.Request()
    spawn.name = "reset_probe_robot"
    spawn.allow_renaming = False
    spawn.uri = "file:///opt/robotics_ws/install/share/robotics_runtime_infra/description/neutral_robot.urdf"
    spawn.initial_pose.header.frame_id = "world"
    spawn.initial_pose.pose.orientation.w = 1.0
    result = call(SpawnEntity, "spawn_entity", spawn)
    assert result.result.result == Result.RESULT_OK
    name = result.entity_name
    assert name == "reset_probe_robot"
    until = time.monotonic() + 15
    while name not in entities():
        if time.monotonic() > until:
            raise RuntimeError("native spawned model never observed")
        rclpy.spin_once(node, timeout_sec=0.05)
    node.set_state(SimulationState.STATE_PAUSED)
    node.wait_for_state(SimulationState.STATE_PAUSED)
    node.wait_for_quiescent_clock()
    req = SetEntityState.Request()
    req.entity = name
    req.state.header.frame_id = "world"
    req.state.pose.position.x = 3.0
    req.state.pose.position.y = 2.0
    req.state.pose.position.z = 5.0
    req.state.pose.orientation.w = 1.0
    moved = call(SetEntityState, "set_entity_state", req)
    assert moved.result.result == Result.RESULT_OK
    before = state(name)
    assert before.result.result == Result.RESULT_OK
    assert math.isclose(
        before.state.pose.position.x, 3.0, abs_tol=1e-6
    ) and math.isclose(before.state.pose.position.y, 2.0, abs_tol=1e-6)
    beforeClock = node.wait_for_quiescent_clock()
    report["beforePartial"] = {
        "clockNs": str(beforeClock),
        "state": node.state(),
        "entities": entities(),
        "model": message_to_ordereddict(before.state),
    }
    partial = ResetSimulation.Request()
    partial.scope = ResetSimulation.Request.SCOPE_TIME
    response = call(ResetSimulation, "reset_simulation", partial)
    assert response.result.result == Result.RESULT_FEATURE_UNSUPPORTED
    afterClock = node.wait_for_quiescent_clock()
    afterPartial = state(name)
    assert afterPartial.result.result == Result.RESULT_OK
    report["afterPartial"] = {
        "clockNs": str(afterClock),
        "state": node.state(),
        "entities": entities(),
        "model": message_to_ordereddict(afterPartial.state),
    }
    assert afterClock == beforeClock and node.state() == SimulationState.STATE_PAUSED
    assert message_to_ordereddict(afterPartial.state) == message_to_ordereddict(
        before.state
    )
    report["unsupportedPartialEffectAbsent"] = True
    reset = ResetSimulation.Request()
    reset.scope = ResetSimulation.Request.SCOPE_ALL
    index = len(samples)
    response = call(ResetSimulation, "reset_simulation", reset)
    report["resetResultOk"] = response.result.result == Result.RESULT_OK
    until = time.monotonic() + 0.6
    while time.monotonic() < until:
        rclpy.spin_once(node, timeout_sec=0.02)
    afterSamples = samples[index:]
    finalEntities = entities()
    finalModel = state(name)
    finalClock = int(afterSamples[-1]) if afterSamples else None
    report["afterAll"] = {
        "clockNs": str(finalClock) if finalClock is not None else None,
        "state": node.state(),
        "entities": finalEntities,
        "modelResponse": message_to_ordereddict(finalModel),
        "clockSamplesAfterRequest": samples[index:],
    }
    report["resetClockEpochObserved"] = any(
        int(sample) < beforeClock for sample in afterSamples
    )
    report["resetClockZeroObserved"] = "0" in afterSamples
    report["spawnedModelDespawned"] = name not in finalEntities
    report["missingModelStateResult"] = finalModel.result.result
    report["missingModelStateGetterSucceeded"] = (
        finalModel.result.result == Result.RESULT_OK
    )
    report["nativePausedAfterReset"] = node.state() == SimulationState.STATE_PAUSED
    report["pausePreservationRequiredByResetServiceContract"] = False
    node.set_state(SimulationState.STATE_PAUSED)
    node.wait_for_state(SimulationState.STATE_PAUSED)
    report["separatePostResetPause"] = {
        "requestedState": SimulationState.STATE_PAUSED,
        "state": node.state(),
        "quiescentClockNs": str(node.wait_for_quiescent_clock()),
    }
    passed = all(
        report.get(k) is True
        for k in [
            "unsupportedPartialEffectAbsent",
            "resetResultOk",
            "resetClockEpochObserved",
            "spawnedModelDespawned",
        ]
    )
except Exception as error:
    report["error"] = str(error)
finally:
    report["passed"] = passed
    print(json.dumps(report, indent=2))
    node.destroy_node()
    rclpy.shutdown()
if not passed:
    sys.exit(70)
