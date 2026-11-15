# Aerial Autonomy Stack consumer

The Aerial Autonomy Stack (AAS) integration programme covers its published
simulation, development and deployment workflows. AAS supplies the aircraft,
worlds, autopilot integration and application logic. Robotics supplies attempt
ownership, retained evidence and independent assessment. The acceptance scope
is tracked in [issue 146](https://github.com/mmkolpakov/robotics-runtime-infra/issues/146).
A runnable robotics consumer is planned.

## Integration boundary

The consumer belongs in `examples/aerial-autonomy-stack`. It invokes AAS through
its existing shell entry points, Gymnasium API and ROS actions, services and
topics. Its evaluator interprets the selected native observations. AAS-specific
commands, message types and flight criteria stay in the consumer.

The host runs a finite attempt through public `Jobs` and resource ownership.
The consumer retains logs before disposing its own processes, containers and
networks. Dagu can schedule the local campaign. An agent can invoke the same
published CLI through its configured execution tools and inspect retained
results through the robotics MCP server. Native execution through the robotics
MCP itself remains a planned interface.

## Workflows to verify

- Headless PX4 and ArduPilot Gymnasium execution, including reset, step, speedup
  and vector environments.
- Each supplied world and supported quadrotor, VTOL and tailsitter combination,
  including wind controls and backend-specific limitations.
- Takeoff, landing, orbit, reposition, speed, offboard control and gimbal
  interfaces. Each case checks the supported backend, goal identity, feedback,
  terminal response and observed vehicle state.
- Every supplied mission and its conditional branches, offboard search and
  tracking, external tracks and the simulated radio delay/loss model.
- Multi-vehicle coordination, concurrent instances and interruption of one
  instance while another continues.
- Camera and LiDAR pipelines, detection, odometry, video and native log export.
- The live development loop, operator applications, gamepad and PX4 external
  modes.
- ARM64 deployment, Jetson integration and multi-Jetson compute/network-in-loop
  execution on the required equipment.

The upstream instructions define each supported command and its prerequisites.
Retain their restrictions when choosing a case, including autopilot, airframe,
sensor, GPU and operator-display requirements.
[Upstream workflows](https://github.com/JacopoPan/aerial-autonomy-stack#readme)

## Results and resource ownership

Each attempt records its source and image identities, configuration, native
command, outcome and resource inventory. A successful command or ROS action
response is one observation. Flight completion also requires the selected
vehicle-state postcondition. Cancellation, deadlines and connection loss retain
their own outcomes and cleanup evidence.

Keep rosbag2/MCAP, ULog and ArduPilot BIN files in their native formats. Use the
upstream plotting and track-comparison tools for inspection. Feed the retained
observations to the consumer evaluator through published contracts and Harness
CLI, producing JSON and JUnit. Verify a copied archive independently of the
original workspace.
[Evidence producers](evidence-producers.md)

Startup, recording and export failures must leave enough evidence to identify
remaining resources. Cleanup uses the attempt's resource identities and checks
for surviving processes, containers, networks and IPC paths. Shared resources
and concurrent attempts retain separate owners.

## Distribution

Review the actual image packages, aircraft assets, worlds, models and weights
for the intended distribution. AAS's repository licence is one part of that
composition. Record the selected software and hardware qualification scope with
each supported consumer recipe.
[Supply-chain checks](supply-chain.md)
