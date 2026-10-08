# Neutral robot foundation fixture

This fixture exercises the retained ROS profile with native entity, Clock,
JointState and TF observations, followed by live evaluation and independent
consumption. The [qualification reference](../../docs/qualification-baseline.md)
defines accepted image, package and environment scopes.

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

For released execution, choose the canonical tag and exact tooling commit:

```sh
gh workflow run qualify-released.yml --repo mmkolpakov/robotics-runtime-infra --ref v0.11.0-rc2 \
  -f release_tag=v0.11.0-rc2 \
  -f tooling_ref=95cbb8e21e4132f07252e2d8dc1c2c421a472c25
```

The workflow verifies the unchanged release lock and selected image provenance
before execution and does not build images. A successful attempt retains its
qualification package and a separate published-consumer report. Failed readiness
retains diagnostics; it does not produce a signed success.

The consumer installs the exact contracts/harness pair in the foundation lock,
verifies retained bytes and readmits the robot without a producer snapshot.
Image provenance and package integrity remain separate checks. This fixture
does not qualify physical joint motion or hardware.
