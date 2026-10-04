# Stock ROS source cohort

The source cohort installs signed Debian ros_gz_sim 1.0.24 and
simulation_interfaces 1.5.1 on Jazzy / Ubuntu Noble / Gazebo Harmonic.
It extends the installed contracts 0.18.2 / harness 0.19.1 source coordinator.
R10 and the retained 1.0.22 images remain unchanged; no upstream source overlay is used.

## Identity and build

The fixed ROS snapshot is 2026-09-11; Ubuntu is 20260930T000000Z.
The existing locked key verifies the InRelease signature and package index.
All six ros_gz packages, interfaces and the exact 85-package installation delta
are pinned in the source lock and APT lists. The runtime checks the complete
1622-package inventory, stock binary ownership, prefix and installed SDK versions.

[The lock](../config/ros-cohort-source.lock.json) contains versions, archive hashes,
snapshot key and source tags. The tagged plugin registers native entity, features,
state and stepping services; runtime results use imported interface constants.
[Source evidence](proofs/ros-cohort-stock-source.json) retains the signed index
and tagged API file hashes.

Build the project-only runtime stage of docker/ros-cohort-source.Dockerfile
with the fixed source revision and the native Podman Docker image format.
System packages, registry settings and the shared snapshot helper are unchanged.

## Native observation scope

Native Jobs/Compose/Engine API 1.41 observed ros_gz_sim 1.0.24, interfaces 1.5.1,
Gazebo 8.11.0 and public SDK 0.18.2 / harness 0.19.1.
Package versions, ownership and dpkg file checks passed; the probe exited zero
and guarded project cleanup was empty.
[Runtime evidence](proofs/ros-cohort-runtime.json) binds the image and raw facts.

Stock B3 must separately prove canonical initialization before the sole Clock
owner, entity presence, exact stepping, fresh JointState/TF, original LIVE
evaluation, recording drain, durable export, guarded cleanup and portable verification.
Installed-package proof does not qualify a released caller.

The full neutral SOURCE B3 run on the stock cohort passed. Independent review
after source storage removal verified 361 completion/resource references.
Separate fresh-scene requests proved supported full reset and unsupported partial
reset. Full reset starts a new Clock epoch and removes dynamically spawned models;
retained evidence must precede that operation. Explicit pause is a separate call.
[The review](ros-cohort-independent-review.md) links the exact native evidence.
These accepted source gates do not qualify released R10 or the full legacy CLI.
