# Native legacy Gazebo/ROS startup

The source provider uses native Cordis Admission/RunOwner and the installed
ROS/Gazebo APIs. It does not replace the published acceptance runner or qualify
R11. The failed R10/B3 baseline remains unchanged.

## Inputs and startup

The trusted bootstrap validates the robot description through the public Python
admission helper, issues a frozen LegacyInputs snapshot and supplies a separate
immutable native Include profile. Operator documents are not Loader profiles.
Every Compose invocation uses the public Jobs interface; Node imports no ROS or
Gazebo SDK.

Startup establishes native input checks, the missing-file/actual-absence negative
case, fresh create acknowledgement and clean exit, observed entity and canonical
initialization. Fixed preClockReadyJobs then run before the sole periodic owner.
The provider rechecks entity/canonical facts before starting that owner. Auxiliary
services may start after the manifest exists; the acceptance observer starts in
the combined measurement phase.

Readiness requires fresh Clock, exact slider_joint position zero and the
base_link→slider_link transform: translation [0.2, 0, 0], identity rotation.
Every stamp must exceed the preceding native Clock cursor. Nanoseconds cross the
Node boundary as decimal strings. The native stepper must remain Running.
The description stays read-only after ownership begins.

## Ownership and completion

Native metadata binds exact image/container IDs, user, mounts, resource fields
and run/project labels. A shared namespace requires the actual acquired parent
container ID, its owner labels and inspected network/IPC facts. Missing fields
remain incomplete; Compose declarations do not supply them.

The readonly startup snapshot retains those IDs, roots and evidence references
for finalization. The narrow startup proof acquires no application recorder.
Completion freezes the periodic writer, observes native PAUSED state and
quiescent Clock/entity facts without reset, retains evidence, disposes the native
Fiber and verifies physical cleanup. Full live observation, MCAP/OTel, signing,
portable verification and released B3 belong to the combined pipeline.

## Source evidence

The compact retained summary is
[legacy-startup-source.json](proofs/legacy-startup-source.json).
The source simulation uses native ros_gz_sim 1.0.22 / simulation_interfaces 1.5.1.
The separate pinned 1.0.24 cohort and full B3 remain open.

The coordinator's actual public packages are contracts 0.18.2 / harness 0.19.1.
Its installed versions are distinct from its older embedded source lock.
The retained simulation image supplies native ROS APIs; its older Python
environment is not used for public admission/evaluation.

Raw source proofs under artifacts/c09 retain startup, strict freshness,
five-step conformance before clock ownership, completion and cleanup. Earlier
failures remain failures. These records do not close
[the released qualification gate](qualification-baseline.md).

Run the source fixture with absolute owned paths and immutable image identities:

```sh
node host/tools/qualify-gazebo-startup.mjs \
  /absolute/infra-root /absolute/owned-engine.sock /absolute/proof-output \
  sha256:59e092393a655e736b56c928acd51b921411fa4810cb030591e00138b2fc5ed4 \
  sha256:1c227795630eb5d3a5069774031321f7aa48a47179af8345432bf1a0be6c7c60
```

## Bounded metadata

Engine discovery and container/image/network/namespace/inventory reads have
finite deadlines and propagate caller cancellation to the native SDK request.
Endpoint and requirements are copied before asynchronous work. Cancellation
remains an error and cannot advance startup. The startup snapshot is available
only after completed native readiness.

Focused transport checks cover held Unix HTTP responses, request closure,
caller mutation and foreign ownership. Raw native facts are retained under
artifacts/c09/metadata-bounds-native; this read-only check is not full B3.

## Owned orphan cleanup

Completed one-off observers keep their simulation network namespace until removed.
Teardown uses the standard down --volumes --remove-orphans on the unique admitted
project. Before teardown, projectOwnership reads all same-project containers,
volumes and networks, verifies each run/project binding and each actual shared
namespace parent. Missing or foreign bindings refuse destructive cleanup.
Native project and run inventories must then be empty.

The native fixture covers an exited child and namespace parent, a foreign run
label inside the same project, a wrong parent ID and a separate running project.
Raw facts are retained under artifacts/c09/cleanup-ownership-native-2.
