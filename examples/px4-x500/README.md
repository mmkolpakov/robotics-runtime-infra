# Stock X500 consumer

This example keeps flight policy outside the runtime core. It uses public host
ownership interfaces, native MAVSDK control, stock PX4 listener/logger commands,
and a separate ULog evaluator. Public contracts describe the inputs and evidence;
the acceptance CLI produces JSON and JUnit.

## Control and evidence

The native path uses one owned PX4/Gazebo container. The worker calls synchronous
MAVSDK Action methods once per application intent; the SDK owns its protocol
retries. Cached Telemetry supplies readiness and control hints. It does not supply
the altitude measurements used by the evaluator.

Before dispatch, the worker checks valid local/global/home position health and
reads stock listener snapshots. Publication timestamps and printed ages bound the
native print clock; successive intervals must be ordered and disjoint in the same
PX4 process. Original listener output is retained and independently parsed using
the pinned PX4 v1.17 grammar.

The worker persists each action intent before calling the SDK. Application
invocation IDs identify those intents, not PX4 transactions. The parent retains
the original container/process identities and Engine exec records. A closed
journal alone does not establish successful SDK teardown or process settlement.

After verified worker settlement, the owner stops the logger while simulation
time advances, verifies closure, pauses Gazebo and exports the original ULog.
Only then may it remove owned resources. Stream cancellation, a timeout, an SDK
error or a missing closure record cannot authorize cleanup. The remote worker
uses stock GNU `timeout`; it is not a general guarantee about detached daemons.

Keep these directories with the completed archive:

- `inputs/`: immutable configuration, scenario, runtime and issued run.
- `parent-facts/`: original owner, process, logger and exec observations.
- `source-records/`: bounded frozen journal JSON written during completion.
- `capture/`: the worker's journal and closed controller manifest.
- `capture/retained-native-logs/`: original bytes from the existing opaque exporter.

The parent writes a separate `native-evidence.json` after journal closure.
Completion registers the original native artifact URIs, sizes and hashes; it
does not relocate them or append to the worker's journal. Missing original
records remain missing. Artifact URIs bind their locations; copying the archive
does not rebind them.

## Cases and measurement

The physical method `px4-valid-home-sampled-v0.2` uses stock pyulog and NumPy to
evaluate sampled PX4 estimates:

- `land`: start grounded and unarmed, observe home-relative estimated
  altitude of at least 1.2 m after received takeoff and before received land, then observe
  grounded and disarmed state after land.
- `unarmed-refusal`: dispatch neither arm nor takeoff and capture four distinct
  estimator samples within 0.2 m of the initial relative altitude. This checks a
  caller precondition, not firmware command denial or continuous absence of motion.
- `application-deadline`: observe ascent, record a two-second application interval
  and independently request landing. This does not simulate a native deadlock.

Controller and evaluator 0.3.0 distinguish publication time from the bounded
native print clock. Publication timestamps select the original ULog phase; clock
intervals do not trim its events or calibrate the native clock to controller UTC.

ULog received commands and ACKs bind the admitted sender/target tuple. Attributable
SDK retries and late ACKs are allowed; ambiguous ownership or application phases
remain incomplete. Estimated altitude follows PX4's float32 subtraction,
float32 millimetre conversion and integer truncation. Invalid home, an in-phase
home/reset change, stale samples, corruption, dropouts or insufficient coverage
prevent an unsupported positive result.

The method requests a 64 MiB raw ULog budget. The document-control lock uses
harness 0.23.1, which honors that explicit raw-evidence budget: the original
ULog is read with `read_local(max_raw_evidence_bytes=ULOG_LIMIT)`. The 8 MiB
capture ceiling applies only to structured documents. That lock is not a
native install set. Native SDK/image composition admission is separate.
The source-built MAVSDK 4.2 composition uses `compose.px4-sdk.yaml`; rootless
Podman also uses `compose.px4-sdk.podman.yaml` for the owned UID mapping. Select
and admit the complete worker image and init binary before a native attempt.

These assertions concern the selected simulated X500 estimates. They do not
establish hardware behavior, camera/media performance, model-load provenance,
cross-clock synchronization or physical safety. JSON and JUnit expose the same
assertions. Missing facts yield `incomplete`; observed unmet conditions yield
`failed`; malformed input can yield `error`. SDK timeout alone is not firmware
rejection.

## Install the document controls

Use Python 3.12 and uv 0.11.28. Node controls use Node 24.21.0.
[input-pins.json](input-pins.json) fixes contracts 0.22.0 and harness 0.23.1;
[requirements.lock](requirements.lock) fixes their dependency closure and the
method's pyulog/NumPy dependencies. From this directory:

```sh
uv venv --python 3.12 .venv
.venv/bin/python -I -m ensurepip --upgrade
.venv/bin/python -I -m pip download --index-url https://pypi.org/simple \
  --require-hashes --only-binary=:all: --no-deps --dest sdk-wheels -r requirements.lock
python3 check-sdk-wheels.py sdk-wheels
.venv/bin/python -I -m pip install --no-index --find-links=sdk-wheels \
  --require-hashes --only-binary=:all: -r requirements.lock
.venv/bin/python -I -m pip check
uv build --wheel --out-dir dist evaluator
```

Authenticate the method wheel before installing it or importing the producer.
The acceptance CLI requires an operator trust policy outside the evidence archive.
A receipt or verification JSON alone does not establish publisher authentication.
See the SDK's [operator trust profile](https://github.com/mmkolpakov/robotics-runtime/blob/harness-v0.23.1/packages/harness/docs/evaluator-trust.md).

[test_admission_fixture.py](test_admission_fixture.py) provides a disposable local
publisher for software controls. Supply an approved Cosign tool profile containing
`executable`, `executable_sha256` and its exact vendor `version`:

```sh
.venv/bin/python -I test_admission_fixture.py \
  --wheel dist/px4_x500_evaluator-0.3.0-py3-none-any.whl \
  --tool-profile /absolute/approved-cosign-tool.json --output results/authenticated
.venv/bin/python -I -m pip install --no-index --no-deps \
  results/authenticated/px4_x500_evaluator-0.3.0-py3-none-any.whl
.venv/bin/python -I -m pip check
PX4_SDK_WHEELS="$PWD/sdk-wheels" \
  PX4_EVALUATOR_BINDING="$PWD/results/authenticated/binding.json" \
  PX4_ADMISSION="$PWD/results/authenticated" \
  .venv/bin/python -I -m unittest discover -s . -p 'test_*.py'
npm ci --ignore-scripts --no-fund
npm test
```

The fixture's random key is not a production publisher policy. These controls
exercise software boundaries without importing MAVSDK or launching a simulator.

## Prepare, complete and evaluate

Prepare inputs before execution with the authenticated method binding:

```sh
.venv/bin/python producer.py prepare --profile native-profile.json --case land \
  --evaluator-binding /absolute/admitted-binding.json --output case/inputs
```

The issued configuration and run identity remain immutable. After the owner has
retained original capture and custody files, complete the archive:

```sh
.venv/bin/python producer.py complete --prepared case/inputs --capture case/capture \
  > case/evaluate-inputs.json
```

Completion writes `observation.json` and `evidence-index.json`. Its output supplies
the exact run/domain and receiver-window arguments for the public evaluator:

```sh
.venv/bin/robotics-acceptance evaluate \
  --scenario case/inputs/scenario.json --runtime case/inputs/runtime.json \
  --run-context case/inputs/run.json --run-id RUN_FROM_INPUTS --domain-id px4 \
  --evidence-index case/evidence-index.json \
  --window-start-ns CAPTURED_START_NS --window-end-ns CAPTURED_END_NS \
  --evaluator-trust-profile /absolute/operator-profile.json \
  --evaluator-receipt /absolute/receipt.json \
  --evaluator-verification /absolute/verification.json \
  --evaluator-receipt-dependency /absolute/statement.json \
  --evaluator-receipt-dependency /absolute/publisher.json \
  --evaluator-receipt-dependency /absolute/verified-report.txt --output case/assessment
```

Exit codes are 0 for `passed`, 1 for a completed non-passing assessment and 2 for
input/admission refusal. A late cleanup observation cannot turn missing native
measurements into a pass.

## Native owner bootstrap

```sh
npm run flight-native -- land /absolute/operator.json /absolute/case/inputs/pre-run-inputs.json
```

The operator JSON supplies `archiveRoot`, `sdkIds`, absolute `producerPython`,
`producerPath` and `harnessExecutable`, the evaluator trust paths, and an existing
host `TrustedProfile` in `profile`. Keep the operator and evaluator trust profile
outside the evidence archive, in a canonical directory without group or other
write permission. Their files must also exclude group and other write access.

The host profile is a read-only JSON Include document with one `px4` entry using
`native-sdk-v2`. Its config binds `archiveRoot`, `initSha256`, the immutable
`workerImage`, selected Engine and Compose paths, retained volume and output
root. `profile.requiredBindings` is `[{"entryId":"px4","service":"px4"}]`, and
`profile.isolatedServices` may be empty: the host isolates required services.
Include the profile, provider module
and its dependency files, and every Compose file in `profile.files` with their
SHA-256 values. The public Admission service checks this closure before startup.
The bootstrap does not infer trust from files inside the completed archive.

The provider checks the expanded Compose environment before launch and compares
the observed actor environment with the admitted image before SDK execution.
The run-specific Gazebo partition and verified Engine identity fields are the
only additions; environment values are not retained as evidence. Context disposal
is awaited on errors. An unresolved worker still cannot authorize resource
cleanup or a successful assessment.
