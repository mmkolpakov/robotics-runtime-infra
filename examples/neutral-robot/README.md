# Neutral robot foundation fixture

The selected target is architecture C. This fixture is the retained ROS v1
qualification profile; [the baseline](../../docs/qualification-baseline.md)
records its separate source, caller, tooling and published-image identities.
The released B3 run `37157837270` failed: native entity checks passed, Clock
overshot by 107 ms, and qualifying JointState readiness reached its 90-second
deadline. TF and the independent consumer did not run. These gates remain open.

Run the existing foundation source import, validation and image build, then:

```sh
bash examples/neutral-robot/verify-foundation.sh
```

The same job first rejects a wrong manifest digest before producers or the
observer start. It then admits the ready URDF, launches the native ROS nodes,
checks that the model is absent, rejects an acknowledged request for a missing
file, and requires the created model through native `GetEntities`. It then
observes Clock, JointState and TF before the recorder and acceptance observer.

The authored source and description are the same canonical file under
`ros_ws/src/robotics_runtime_infra/description/neutral_robot.urdf`. The manifest
uses its exact raw SHA-256 and has no meshes. The two uniform solid boxes have a
total mass of 1.25 kg and zero-pose center of mass at (0.04, 0, 0) m.

JointStatePublisher publishes the zero joint position; RobotStatePublisher
publishes the movable joint's transform. This qualifies native software state
publication. Physical joint motion remains the separate controller test. This
native fixture requires the world-origin pose and accepts no extension-schema
inputs; generic file admission validates the public extension registry.

Only admitted files are copied into the read-only snapshot shared by the ROS
client and Gazebo server. Qualification
retains the manifest, package.xml and every declared source, description and mesh
file at its original relative path. After the producer snapshot is removed, native verification and
filesystem readmission use the portable subjects alone. The trusted CI consumer
repeats this with the published contracts and harness versions in the foundation
lock.

The released workflow uses the same fixture with `v0.10.0-rc.1` images, pinned
by the unchanged release lock. It verifies the release and selected image
provenance before execution; it does not build images. Run it from this repository:

```sh
gh workflow run qualify-released.yml --repo mmkolpakov/robotics-runtime-infra --ref main
```

A successful workflow retains the qualification package and a separate consumer
report. Failed readiness retains diagnostics and raw observations; it does not
produce a signed success. The workflow below is a strict candidate entrypoint,
not a claim that R10 or the current caller passed B3.
That consumer installs contracts 0.18.2 and harness 0.19.1 from PyPI, verifies
the retained bytes under the included ephemeral key and readmits the robot
without a producer snapshot. Image provenance and package integrity are
separate checks; this fixture does not qualify physical joint motion or hardware.
