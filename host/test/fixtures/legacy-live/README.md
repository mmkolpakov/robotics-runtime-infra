# Live neutral source fixture

This fixture runs the existing neutral scenario through the native Gazebo provider
and retained finalization service. It uses the public contracts 0.19.0 and harness
0.20.0 CLI. The installed package versions are checked against the foundation lock
before runtime-manifest creation. The identity sidecar keeps the declared workspace
source pin and observed installed versions separate: matching versions alone do not
prove a source commit.

The trusted Node bootstrap is `host/tools/qualify-legacy-live.mjs`. Its positional
arguments are the repository root, private Engine socket, Compose executable,
canonical `run-<uuid4>` ID, Host source volume, Host retained volume, exact simulation
image ID, simulation repository digest, finalizer repository digest, evidence
worker repository digest, retained startup directory and source revision.
Use the project Node image and existing private project tooling. The Host source
and retained volumes must already exist with
`org.robotics.runtime.storage-owner=host` and no run ownership label. The bootstrap
retains their native labels, its actual mounts/image/user and filesystem permissions
before admission starts any producer. The acquired input volume belongs to the run;
the Node Host does not mount it.

The live roles are the simulation, one periodic stepper, neutral robot, sequence
publisher, runtime metrics, Collector, MCAP recorder, original live observer and
evidence sink. Admission retains the unchanged robot-description product and
scenario. Native simulation conformance runs before the periodic stepper and is
followed by entity and canonical-state checks. Measurement opens after native
Clock, JointState and TF readiness. It does not restart the established clock owner.

The simulator health probe calls native GetSimulatorFeatures through the shared
compose.simulation-health.yaml fragment used by the public stepped and conformance
profiles. It keeps the native command, six-second timeout and startup grace
(15 seconds here, 20 seconds publicly), with a two-second startup interval and
30-second steady interval. Three consecutive failures give a configured steady
detection budget of at most 108 seconds: 3 × (30 + 6), previously
15 × (2 + 6) = 120. The simulation image's existing Clock probe uses the same
cadence and timeout with its unchanged 30-second grace; its budget remains
108 seconds, previously 6 × (10 + 8). These are probe scheduling budgets, excluding
daemon or host scheduling delays. Auxiliary probes retain their existing policies.

[Docker healthcheck scheduling](https://docs.docker.com/reference/dockerfile/#healthcheck)
requires Docker Engine 25 or later for the startup interval; the
[Engine API](https://docs.docker.com/reference/api/engine/version-history/)
introduced HealthConfig.StartInterval in API 1.44. Native admission checks the
actual Engine identity, version and selected API before producer acquisition, then
checks the acquired container's Config.Healthcheck command and timing fields.
Podman startup scheduling is unqualified for this policy and is refused before
producer launch. Generic metadata reads and other provider profiles keep their
existing API range.

Completion waits for the actual measurement marker while the source remains
running. It stops the metrics and sequence writers, stops the periodic stepper,
then captures native PAUSED state, quiescent Clock and GetEntities without reset.
Collector and recorder must report clean native exit. Existing evidence helpers
register metrics and finalize the index before the original live observer exits.
Recordings and spool live under `/run/robotics/evidence/bags`, beneath the same
evidence directory used by the observer.

A finite export role mounts source and admitted input read-only, with a separate
writable retained volume. It copies exact payload bytes and verifies their hashes;
the Node Host independently checks every retained size and SHA before cleanup.
Export errors retain the source and incomplete output. The recovery tool
`host/tools/cleanup-joint-startup-failure.mjs` preserves raw diagnostics, drains
writers and exports to a new attempt directory before any physical teardown.
Private sink state is read with its producer UID; its modes are unchanged.

After independently observed source cleanup, separate retained-only workers call
the existing public aggregate CLI and unchanged package, statement, signing and
portable verification helpers. They preserve the original live result. They do
not evaluate a finalized playback. Worker cleanup uses a fresh bounded signal on
success, failure or cancellation. The shared read-only project ownership API
checks all native project resources before orphan teardown; foreign ownership
refuses cleanup and retains diagnostics. Retained payloads survive worker cleanup.

This is a source qualification fixture. The old neutral runner remains the
equivalence baseline, and released readiness remains a separate gate.
