# B3 initialization and clock ownership

The retained released B3 run 37157837270 remains FAIL. Its Clock overshoot of
107 ms, empty qualifying JointState output, skipped TF/consumer and original
raw files are preserved in the [baseline](qualification-baseline.md). This
source diagnostic explains the initialization race; it does not close full
B3 business evaluation or published consumer acceptance.

## Native cause

The retained source fixture's installed cohort is ros_gz_sim
1.0.22-1noble.20260615.173223, simulation_interfaces
1.5.1-1noble.20260615.112513 and Gazebo Sim 8.11.0. The later C13 target
ros_gz_sim 1.0.24 is separate from that observed inventory.

[GazeboProxy in ros_gz 1.0.22](https://github.com/gazebosim/ros_gz/blob/1.0.22/ros_gz_sim/src/gz_simulation_interfaces/gazebo_proxy.cpp)
handles newly created canonical links and scene-info updates by sending a
WorldControlState with component state and no explicit world-control pause.
[SimulationRunner in Gazebo Sim 8.11.0](https://github.com/gazebosim/gz-sim/blob/gz-sim8_8.11.0/src/SimulationRunner.cc)
reads that message's default pause value, then applies it through
ProcessWorldControl. The default false can unpause a world already owned by
an exact periodic stepper. This is a second native control effect during
initialization. The same proxy behavior is present in
[ros_gz 1.0.24](https://github.com/gazebosim/ros_gz/blob/1.0.24/ros_gz_sim/src/gz_simulation_interfaces/gazebo_proxy.cpp).

The existing runner starts its periodic stepper before the neutral robot's
native creation/readiness phase. A stepper service-type healthcheck proves
service discovery, not continuing execution or correct clock ownership.
After an exact-step error, the stepper exits; a cached nonzero Clock sample
can still pass the first topic check while sim-time publisher timers cease
advancing. The exact wall ordering of the historical 107 ms failure is not
reconstructed from its grouped cleanup log.

## Bounded native counterfactual

`host/providers/gazebo-ros-v1/startup-diagnostic.py` runs the unchanged
SimulationControl guard and native ROS/Gazebo APIs in two fresh, isolated
source worlds. It retains requests/cursors/clock results, native GetEntities,
server and robot logs, qualifying JointState/TF, last native state and reaped
application cleanup. Measurement is exported before application stop.

The overlapping run established a 140 ms ownership cursor and passed 19
exact 1 ms steps to 159 ms. Native robot/canonical initialization then caused
the same strict guard to reject Clock 205 ms where 160 ms was required.
The robot was present through native GetEntities and two canonical
initializations were observed. The diagnostic reproduces the cause with a
45 ms overshoot; it does not relabel the old 107 ms run.

The ordered run created the robot, observed native entity/canonical
initialization, then acquired paused/quiescent clock ownership at 1807 ms.
It passed 200 exact 1 ms steps to 2007 ms. Native JointState and TF samples
were both stamped 2000 ms, after the ownership cursor, with the unchanged
zero joint position and exact transform filters. Both bounded diagnostic
processes exited zero and their applications were reaped.

The required production order is asset admission/create and canonical
initialization, then exclusive clock ownership and actual software/backend
readiness, then measurement. Inputs and assets are frozen once ownership is
established. Dynamic scene mutation during measurement requires a new
controlled lifecycle boundary; no guard is relaxed or upstream patched.

## Remaining acceptance

C09 still must express these stages in the admitted host/provider profile.
The released caller must run new reviewed tooling against the unchanged
released image lock, retain all wrong-digest/entity/Clock/JointState/TF gates,
complete the original metric windows and JUnit, export payloads before
teardown, and pass independent verification. The old FAIL remains historical
FAIL even after a new successful attempt.
