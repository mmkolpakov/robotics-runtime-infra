# Attached acceptance observation

`compose.edge-attach.yaml` connects an observer to an existing Docker network.
It does not start a simulator or control a target. Set `ROBOTICS_ATTACH_NETWORK`
to that network and `ROS_DOMAIN_ID` to the target's ROS domain. The observer uses
the repository's Fast DDS UDP-only profile. `hil` and `real-observation` also
require the existing permit preflight, runtime materialization and SROS2 files.

An orchestration process owns this lifecycle:

1. Prepare the scenario in `ROBOTICS_RUN_INPUT_DIR/scenario.yaml`. Create its
   acceptance run with `robotics-acceptance create-run` before producing the
   runtime manifest and evidence. Save `acceptance-run.json` beside the scenario,
   export the returned `ROBOTICS_RUN_ID`, and set `ROBOTICS_DOMAIN_ID` to the
   declared acceptance domain. This identifier is distinct from `ROS_DOMAIN_ID`.
2. Produce the matching runtime manifest. Edge attach reads
   `ROBOTICS_RUN_INPUT_DIR/runtime-manifest.json`; physical profiles read the
   manifest materialized in `ROBOTICS_AUTHORIZATION_OUTPUT_DIR` after preflight.
   The physical permit must bind the exact scenario file bytes used by verify.
3. Create writable `ROBOTICS_RESULTS_DIR` and the evidence directory before
   starting the observer. For edge recordings, also create
   `ROBOTICS_EVIDENCE_DIR/recordings` before mounting the read-only evidence
   directory, and set `ROBOTICS_BAG_DIR` to the recorder's bag directory. Retain
   the same run identity in all producers. Use a fresh result directory per run.
4. Start the profile with its default command. The observer loads
   `/input/acceptance-run.json` and measures the live graph. Edge attach consumes
   `/evidence/metrics.otlp.jsonl`; physical profiles consume
   `/evidence/hardware-time.otlp.json`. Their evidence index lives at
   `/evidence/evidence-index.json` and must bind those actual metric bytes.
5. Wait for `ROBOTICS_RESULTS_DIR/measurement-complete`, also monitoring observer
   failure. Only then stop/flush the measurement producers and finalize the
   evidence index. The observer waits for finalized evidence before returning
   its verdict. Do not create the marker from the orchestration process.
6. Require exit 0, `acceptance-result.json` with `evaluation_mode: live` and
   `status: passed`, and the JUnit output. Exit 1 is a failed/incomplete verdict;
   exit 2 is an input or execution error, recorded in `diagnostic.json`.

`scripts/ci/foundation/run-edge-attach.sh` exercises this lifecycle against the
same real Gazebo, recorder and Collector used by the foundation acceptance path.
It uses a separate Compose project joined to the simulator's existing network,
executes the service's default `verify` command without replacing it with a
probe, and verifies the resulting aggregate and signed qualification bundle.
Cleanup checks cover both Compose projects.

The physical authorization fixture separately checks synthetic device evidence
and SROS2 access restrictions. It does not yet implement this complete lifecycle
with contemporaneous hardware metrics and a permit bound to its acceptance
scenario. Full physical qualification remains an E2E-3 gate.
