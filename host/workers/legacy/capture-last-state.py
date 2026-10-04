#!/usr/bin/env python3
"""Capture native state after the caller freezes its periodic writer, before reset."""
import json
import rclpy
from robotics_runtime_infra.simulation_control import SimulationControl
from simulation_interfaces.msg import SimulationState, Result
from simulation_interfaces.srv import GetEntities
rclpy.init();node=SimulationControl('/simulator',15)
try:
 node.set_state(SimulationState.STATE_PAUSED);node.wait_for_state(SimulationState.STATE_PAUSED)
 clock_ns=node.wait_for_quiescent_clock()
 client=node.create_client(GetEntities,'/simulator/get_entities')
 if not client.wait_for_service(timeout_sec=15):raise RuntimeError('native GetEntities unavailable at final state')
 future=client.call_async(GetEntities.Request());rclpy.spin_until_future_complete(node,future,timeout_sec=15)
 response=future.result() if future.done() else None
 if response is None:raise RuntimeError('native final entity call timed out')
 if response.result.result!=Result.RESULT_OK:raise RuntimeError('native final GetEntities failed: '+response.result.error_message)
 print(json.dumps({'phase':'native-last-state-before-destructive-reset','clock_ns':str(clock_ns),'state':node.state(),'entities':list(response.entities),'result':response.result.result,'result_ok':True,'result_ok_code':Result.RESULT_OK,'error':response.result.error_message,'reset_performed':False,'precision':'native ROS Clock integer ns'}))
finally:node.destroy_node();rclpy.shutdown()
