# Nav2 TurtleBot3 consumer

This source consumer separates immutable inputs, completed native observations, and offline
assessment. The evaluator 0.3.0 uses public contracts v2, the verified evidence reader, and the
external evaluator admission profile. Its minimum SDK versions are contracts 0.21.0 and
acceptance harness 0.22.0. These are release targets; the source test cohort is the exact runtime
revision and wheel SHA-256 values in [inputs.lock.json](inputs.lock.json), installed through
[requirements.lock](requirements.lock). This source lock does not claim a published package or
an admitted native composition.

The retained native client code uses stock Nav2 Commander, ROS actions/services, rosbag2,
and Gazebo APIs. It does not supply a robot controller or a new transport abstraction.
`native-check.mjs` and the worker bootstrap refuse launch until a matching v2 SDK/image
composition has actual execution admission. The document recipe below does not start a world.

## Install the source test cohort

Build contracts and harness wheels from the exact runtime Git revision in `inputs.lock.json`.
Their filenames and SHA-256 values must match that file before installation. Use Python 3.12
and the ordinary pip installer for the evaluator:

```sh
python3 -m venv .venv
.venv/bin/python -m pip install --require-hashes --find-links sdk-wheels -r requirements.lock
uv build --wheel --out-dir dist evaluator
```

The self-contained purelib admission profile supports pip's documented installation transforms.
An installer adding other distribution metadata, such as `uv_cache.json`, is outside that profile.
Use an explicit cohort wheel directory; a version number alone cannot substitute for its hash.

## Admit the evaluator

Use the public SDK's external GitHub or explicit Cosign key-only verifier profile. The
[runtime evaluator guide](https://github.com/mmkolpakov/robotics-runtime/blob/main/packages/harness/docs/evaluator-trust.md)
defines those policies, wheel guards, and process boundaries. The operator profile and its
approved verifier/key/root pins belong outside the evidence archive.

The local publisher can sign its private wheel with stock Cosign without uploading code to
GitHub. For the explicitly selected no-log policy, an empty signing configuration/root disables
remote signing services:

```sh
cosign signing-config create --out offline-signing.json
cosign trusted-root create --out offline-root.json
cosign attest-blob --yes --key publisher.key --signing-config offline-signing.json \
  --trusted-root offline-root.json --type urn:nav2-turtlebot3:consumer-evaluator-qualification:v1 \
  --predicate predicate.json --bundle wheel.sigstore.json \
  dist/nav2_turtlebot3_evaluator-0.3.0-py3-none-any.whl
```

The external operator chooses `kind="cosign_key_no_tlog"`, the exact approved executable,
public-key/root hashes, wheel subject hash, predicate type, and `trust_mode="key_only_no_tlog"`.
This verifies the selected key's signature and subject/predicate binding. It does not prove
OIDC identity, transparency time, or build provenance. Private keys remain with the publisher;
they are never copied into an evidence archive or container image.

Authenticate and validate the complete wheel before installing it. The consumer helper captures
the verified installer input and writes the structural receipt/evaluator requirement:

```sh
.venv/bin/python qualify-evaluator.py --trust-profile /operator/nav2-trust.json \
  --output evaluator-inputs --preinstall
.venv/bin/python -m pip install --no-index --no-deps \
  evaluator-inputs/nav2_turtlebot3_evaluator-0.3.0-py3-none-any.whl
.venv/bin/python -m pip check
```

The preinstall phase invokes the public authentication and wheel-shape guard. Installed verification
also uses the public installation binder and captured original entry points. Both select the exact
Nav2 wheel. Its receipt is an audit document; the later CLI independently authenticates the
wheel through the operator profile. JSON receipt fields cannot admit executable code.

## Write inputs before execution

Supply a native profile from the admitted composition, with exact original ROS types/type support,
backend, wire envelope, encoding, recorder transformation, executor implementation/version, clock,
and observation requirements. `make-scenario.py` binds the supplied executor to the consumer
configuration; it does not infer those facts from a package name.

The requirements JSON contains exactly `evaluator_requirement` (the helper's `binding.json`),
`case`, and `configuration`. Configuration follows [nav2.schema.json](nav2.schema.json), including
the same case, goal, budgets, pose/freshness thresholds, odometry frame, and required TF edges.
The extension's v1 schema names its consumer configuration format; the execution documents are v2.

```sh
.venv/bin/python make-scenario.py --profile native-profile.json \
  --requirements nav2-requirements.json --output archive/inputs
```

This writes scenario/runtime v2, the issued run context, and captured configuration/profile/schema
bytes. `pre-execution-inputs.json` records their exact hashes. There are no completed observations
in the runtime manifest. Use a fresh archive for every admitted action.

## Retain completed observations

Only after producers have settled, place their closed files under `archive/capture`.
The completed-facts JSON contains exactly:

- `started_at`, `finished_at`, and `observations` in the public observation v2 format.
- `artifacts`: source paths relative to capture, each with `artifact_id`, `kind`, and `media_type`.
- `policy_observation`: actual recorder/storage facts for the evidence index.
- Optional `measurement_window` and `native_model` only when actually captured.

Keep command acceptance, native final state, independent postcondition, and cleanup separate.
An acknowledged cancel is not a terminal action result. A finished client is not proof that the
robot stopped or that its recorder/container disappeared. Missing required QoS, clock, cleanup,
or loaded-model facts remain unobserved; the producer does not synthesize them.

```sh
.venv/bin/python finalize.py --prepared archive/inputs --capture archive/capture \
  > archive/evaluation-inputs.json
```

The producer rejects altered pre-execution inputs, escaped/duplicate capture paths, and the
declared artifact/archive byte budgets. It writes a separate observation v2 and finalized index
through public writers. Recorder peak/upload fields describe producer observations; these
document checks do not enforce a live filesystem quota.

The evaluator reads indexed `workload.json` and original `get-result-response.cdr` once each
through `VerifiedEvidence.read_local`, with a one-MiB capture budget, then assesses those immutable
snapshots. MCAP remains native retained recording data; this evaluator does not decode its action
CDR or invent an unavailable ROS message definition.

## Assess and inspect the public result

Use the values emitted in `archive/evaluation-inputs.json` for run/domain/input paths, the actual
captured assessment window, and the externally supplied evaluator receipts/profile:

```sh
.venv/bin/robotics-acceptance evaluate --scenario archive/inputs/scenario.json \
  --runtime archive/inputs/runtime.json --run-context archive/inputs/run.json \
  --run-id RUN_ID --domain-id nav2 --evidence-index archive/evidence-index.json \
  --window-start-ns START_NS --window-end-ns END_NS --output assessment \
  --extension-schema urn:nav2-turtlebot3:scenario:v1=archive/inputs/nav2.schema.json \
  --evaluator-trust-profile /operator/nav2-trust.json \
  --evaluator-receipt evaluator-inputs/receipt.json \
  --evaluator-verification evaluator-inputs/verification.json \
  --evaluator-receipt-dependency evaluator-inputs/statement.json \
  --evaluator-receipt-dependency evaluator-inputs/publisher.json \
  --evaluator-receipt-dependency evaluator-inputs/verified-report.txt
```

The output is public `acceptance-result.v2` JSON and JUnit. A matched action cannot override
missing required evidence or an error. The source controls exercise passed, failed, and incomplete
projections plus receipt-only/wrong-key refusal through the installed CLI; their generated records
are synthetic controls, not observed robot performance.

This method checks the configured action outcome and fresh odometry/TF/AMCL pose facts.
It does not establish a planned-to-loaded native model chain, Gazebo ground truth,
physics/localization accuracy, cross-clock offset,
delivery quality, camera behavior, or complete recovery. Selected calibration is unsupported by
this method. Those claims require their own captured inputs and native composition witnesses.
