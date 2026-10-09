# Planned Agilicious consumer

Agilicious is a planned external consumer of the published host and acceptance
interfaces. The integration targets its native `agilib` controller and simulator
first. Upstream describes `agilib` as C++ with Eigen; its `agiros` ROS binding
and RotorS bridge belong to a separate ROS environment. They are not a ROS 2
Jazzy/Gazebo Harmonic recipe.

## Execution boundary

The planned recipe belongs in `examples/agilicious`; its product evaluator
and native artifact export remain consumer code.

The consumer owns the Agilicious installation, pipeline configuration,
controller, reference trajectory and simulator. It supplies a finite native
worker to public host `Jobs`; the existing run owner retains evidence before
disposing resources. No Agilicious dependency is required to start the common
host, document tools or MCP server.

The consumer pins its installed upstream revision and records the actual
configuration, input trajectory, process outcome and timestamped state/control
observations. Its qualified evaluator checks trajectory error, completion,
deadline behavior and cleanup from those retained inputs. Native logs remain
native artifacts; ROS graph facts are required only by a selected ROS recipe.
This requires the planned neutral acceptance contracts before a canonical
Agilicious JSON/JUnit result can be produced.

The first qualification covers native simulation, finite termination and
independent cleanup verification. Real aircraft and the serial/Betaflight
bridges require separate authorization and hardware qualification.

## Distribution and qualification

Before obtaining or running upstream software, the operator confirms rights
for the intended use and distribution. The operator supplies an installation
obtained under the applicable upstream license. The published academic license
restricts use to internal academic,
non-commercial work and restricts redistribution of software and improvements.
The runtime repositories do not bundle Agilicious code, binaries or images.

A runnable consumer must retain its exact licensed installation identity and
pass public-interface, deadline, failed-worker and cleanup tests. Until those
checks exist, Agilicious support remains planned; there is no released recipe
or native compatibility claim.

- [Upstream architecture and access](https://github.com/uzh-rpg/agilicious#whats-in-it-for-you)
- [Official academic license](https://rpg.ifi.uzh.ch/docs/Agilicious_LICENSE_AGREEMENT_ACADEMIC_USE.pdf)
- [Native API boundaries](architecture.md)
