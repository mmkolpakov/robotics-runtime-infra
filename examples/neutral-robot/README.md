# Neutral robot foundation fixture

Run the existing foundation source import, validation and image build, then:

```sh
bash examples/neutral-robot/verify-foundation.sh
```

The same job first rejects a wrong manifest digest before producers or the
observer start. It then admits the ready URDF, launches the native ROS nodes,
requires Gazebo creation acknowledgement and observes Clock, JointState and TF
before starting the existing recorder and acceptance observer.

The authored source and description are the same canonical file under
`ros_ws/src/robotics_runtime_infra/description/neutral_robot.urdf`. The manifest
uses its exact raw SHA-256 and has no meshes. The two uniform solid boxes have a
total mass of 1.25 kg and zero-pose center of mass at (0.04, 0, 0) m.

JointStatePublisher publishes the zero joint position; RobotStatePublisher
publishes the movable joint's transform. This qualifies native software state
publication. Physical joint motion remains the separate controller test. This
native fixture requires the world-origin pose and accepts no extension-schema
inputs; generic file admission validates the public extension registry.

Only admitted files are copied into the read-only launch snapshot. Qualification
retains the manifest, package.xml and every declared source, description and mesh
file at its original relative path. After the producer snapshot is removed, native verification and
filesystem readmission use the portable subjects alone. The trusted CI consumer
repeats this with the published contracts and harness versions in the foundation
lock.
