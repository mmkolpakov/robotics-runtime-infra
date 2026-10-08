# Legacy finalization workers

The Node plugin owns finite jobs and lifecycle facts. Native ROS state, public Python
contract semantics, recording parsing and signatures run in the installed workers.
The retained legacy runner remains available until source and released equivalence
and the live readiness gate pass.

The extracted boundary is the legacy runner's measurement close, last native state,
recorder/Collector drain and evidence export, followed by public aggregation and the
existing qualification helpers. Startup/admission and physical resource cleanup remain
separate owners. The entire legacy shell body is never passed to one job.

Before opening measurement, the root program supplies the provider's actual readiness
references, exact source container ID, admitted Compose model and per-service native
requirements through `LegacyFinalizationInputs`. This issuer is an internal root service;
operator data is never deserialized as Loader configuration. `beginMeasurement` starts
the existing instrument/recorder services and the observer's existing default verify
command. It retains the acquired observer ID and refuses early observer/source exit.

Use the public RunOwner completion callbacks in their declared order:

1. Close measurement on the public observer's marker; stop instruments and inspect
   actual container state.
2. Freeze the periodic stepper, then invoke the native last-state worker. That worker
   pauses through the installed simulation interfaces, observes quiescent Clock and
   GetEntities success using the native Result constant. Clock nanoseconds remain strings;
   the raw stdout is retained without reserializing it.
3. Stop Collector and recorders through their declared graceful stop configuration.
   Require observed non-running state and clean exit, invoke the existing evidence-sink
   metrics registration/finalize commands, then require the original observer's clean exit.
4. Collect the finite inventory and copy exact bytes into independent retained storage.
   Only successful complete export returns the payload references that permit teardown.

The acquired overlay mounts run-data and run-input read-only in the coordinator.
All phase artifacts/logs must use lifetime-independent host storage too. The acquired overlay
also exposes that volume read-only at `/run/robotics/source-evidence` for inventory bindings.
Inventory/argument control files belong in the writable external retained volume,
outside the new raw-export directory. The byte exporter acquires a new directory,
checks all sources, streams each copy, compares source identity before/after, rereads
retained bytes for SHA/size and writes the completion manifest last. It rejects symlinks,
path escape, duplicate paths, source/destination overlap, size bound and existing output.
A failed copy preserves source bytes and partial output with an incomplete diagnostic.
The plugin has no destructive `finally`; public RunOwner retains the run on export failure.
Use the root issuer's `issueExportAttempt` to obtain an immutable owner-bound token with new
control/output paths. Pass `signal => finalizer.exportAttempt(token, signal)` to public
`run.retryExport`; the retained run/fiber stays alive. Partial attempts are never overwritten.
The historical error remains in RunOwner completion, so retry cleanup does not create a PASS.

The inventory retains the legacy core documents, raw metrics/JUnit, middleware and
resource/capture configuration, provider profile/conformance/source/observations/logs,
native MCAP metadata/segments/summaries, and admitted product/readiness/release inputs.
Summary/MCAP counts must match. Playback preserves every distinct input, allows only
the original SHA/size/kind deduplication and refuses reusing source MCAP bytes as a new
observation. Contract payloads and signed documents stay opaque; only control metadata
and manifests are decoded by Node. Raw recordings are hashed with bounded streaming IO.

After RunOwner confirms export and independent physical cleanup, invoke
`qualifyAfterCleanup`. Its separate Compose project contains only a finite coordinator
and external retained storage. It cannot recreate the acquired run volumes. It invokes
public `robotics-acceptance aggregate`, then directly invokes the existing unchanged
`package-artifacts`, `create-statement`, `sign-ephemeral-qualification.sh` and
`verify-bundle` helpers. The portable package is independently verified before returning
signature/aggregate references.
Helper jobs use the installed GNU timeout in addition to
the host job deadline. Observer evidence is read by exact observed container ID through the
same Engine endpoint with owner, tail, byte and deadline checks. Native multiplex bytes are
retained separately; only the pinned Dockerode decoder produces the declared text view. A local
ephemeral key fixture is not a publisher identity
or live acceptance claim.

Build the worker with the admitted immutable coordinator image containing contracts
0.19.0 and harness 0.20.0. `docker/legacy-finalizer.Dockerfile` checks both versions
against the foundation lock.
Cosign uses the existing publisher-pinned image digest and checks its actual
`v3.1.3+dirty` metadata/commit; it does not claim a pristine upstream build.
Supply the official v3.1.3 source checkout at commit
`11926fa5bbbbde47e88fc006b625a17769b743b2` as the `cosign-license` context.
The Apache license SHA is checked separately.

`host/tools/qualify-finalization-workers.py` tests exact byte retention and failures,
the finite inventory, and real public aggregation/package/sign/portable verification
using repository fixtures after producer deletion. It also requires tampered MCAP
rejection. These tests do not substitute for a live observer/Collector/recorder proof.
