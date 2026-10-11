# External stock X500 consumer

This consumer uses public host `Jobs` and stock generated `Mavsdk` clients.
Its Python producer writes public v2 scenario/runtime/run inputs before execution,
then an observation and evidence index from retained decoded SDK records. The
separate `px4-x500-evaluator` method reads each registered payload once through
`VerifiedEvidence.read_local`; the public acceptance CLI writes JSON and JUnit.

The Python document path uses the exact **source SDK cohort** in
[input-pins.json](input-pins.json): contracts 0.21.0/harness 0.22.0 built from
revision `00735515f71e53bbea9f8761f76db81dcea73299`. These are source-candidate
wheels. [requirements.lock](requirements.lock) pins their actual hashes and
dependency closure. A storage directory does not replace that committed policy.

Native launch currently refuses before host imports or Engine/flight effects:
this document profile does not admit a new SDK/image composition. The pinned
PX4/Gazebo/MAVSDK and host inputs remain declarations requiring composition
admission and native qualification. Installed synthetic controls verify the
document and authentication boundaries; they do not qualify flight or hardware.

## Install the source document path

Use a POSIX shell, Python 3.12, uv 0.11.28 and Node 24.21.0 for the portable Node
controls. The Python prepare/complete/evaluate commands do not require Node.
From this example directory, check out the exact SDK revision and build wheels:

```sh
git clone https://github.com/mmkolpakov/robotics-runtime.git sdk-source
git -C sdk-source checkout --detach 00735515f71e53bbea9f8761f76db81dcea73299
uv build --wheel --out-dir sdk-wheels sdk-source/packages/contracts
uv build --wheel --out-dir sdk-wheels sdk-source/packages/harness
python3 check-sdk-wheels.py sdk-wheels
uv venv --python 3.12 .venv
uv pip install --python .venv/bin/python --require-hashes \
  --find-links=sdk-wheels -r requirements.lock
.venv/bin/python -I -m ensurepip --upgrade
uv build --wheel --out-dir dist evaluator
```

The producer and its shared facts are operator-owned consumer application code.
Authenticate and review the consumer's method wheel before installing it or
importing the producer. The independent acceptance CLI also authenticates that
wheel against an operator policy outside the evidence archive. A receipt or
verification JSON cannot establish publisher authentication.

Use the SDK's
[operator trust profile](https://github.com/mmkolpakov/robotics-runtime/blob/00735515f71e53bbea9f8761f76db81dcea73299/packages/harness/docs/evaluator-trust.md)
with an approved publisher/key, exact wheel and verifier identities, and limits.
The explicit Cosign key-only mode can support a private publisher without sending
its code to GitHub. It proves the pinned key's signature and subject/predicate;
it does not prove OIDC identity, transparency time or build provenance.

[test_admission_fixture.py](test_admission_fixture.py) is a disposable local
publisher control. It uses stock Cosign, authenticates the original wheel and
validates its purelib shape before ordinary pip installation. It generates
temporary test keys, retains only public material, and supplies an external test
policy. Its random test key is not a production publisher policy.

For portable controls, supply an operator-approved Cosign tool profile with
`executable`, `executable_sha256` and the exact `version`, then run:

```sh
.venv/bin/python -I test_admission_fixture.py \
  --wheel dist/px4_x500_evaluator-0.1.0-py3-none-any.whl \
  --tool-profile /absolute/approved-cosign-tool.json --output results/authenticated
.venv/bin/python -I -m pip install --no-index --no-deps \
  results/authenticated/px4_x500_evaluator-0.1.0-py3-none-any.whl
.venv/bin/python -I -m pip check
PX4_EVALUATOR_BINDING="$PWD/results/authenticated/binding.json" \
  PX4_ADMISSION="$PWD/results/authenticated" .venv/bin/python test_producer.py
npm ci --ignore-scripts --no-fund
npm test
```

The fixture requires the executable approved by the CI tool pin, including its
exact vendor version. It does not approve a different executable from a version
probe alone. Controls cover observed failure, incomplete/unknown inputs, malformed
enum values, read-once byte binding, and bounded FIFO/symlink/tamper refusal.

## Pre-run inputs and completed observations

Prepare a fresh archive using the declared SDK types in
[native-profile.json](native-profile.json) and the exact authenticated binding:

```sh
.venv/bin/python producer.py prepare --profile native-profile.json --case land \
  --evaluator-binding /absolute/admitted-binding.json --output case/inputs
```

This creates `scenario.json`, `runtime.json`, `run.json`,
`configuration.json`, `native-profile.json` and `pre-run-inputs.json`.
The configuration contains the selected case and issued run/domain; its original
URI, SHA-256 and size remain bound in the scenario and completed index.
These files are captured before execution and are not rewritten by completion.

The controller's journal retains original decoded SDK responses with issued
run/domain, receiver sequence, receiver UTC nanoseconds and monotonic milliseconds.
Its UTC source has millisecond resolution; it does not measure sender time or
cross-clock synchronization. A closed `controller-manifest.json` binds every
record's name, SHA-256 and size, count/byte totals, and receiver window. The producer
requires ordered receiver times within that window.

Place the controller capture under the same original archive, then complete:

```sh
.venv/bin/python producer.py complete --prepared case/inputs --capture case/capture \
  > case/evaluate-inputs.json
```

Completion first captures bounded regular native files with the public SDK,
checks their manifest hashes, and freezes their bytes in private
`source-records`. Streaming writers receive those owned snapshots. The original
prepared configuration remains registered at its admitted pre-run URI.
FIFO, symlink, oversized, foreign-owner and altered input records fail before
artifact registration. Each record is limited to 1 MiB, the journal to 2048
records/8 MiB, and the final index is checked against the scenario's per-artifact
and aggregate byte policy.

Completion writes `observation.json` and `evidence-index.json`; the printed JSON
contains the exact run/domain, input paths and receiver window arguments for:

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

The method evaluates completion, command acceptance, terminal grounded/disarmed
state, the case's captured position postcondition, and native owner cleanup.
Missing required facts and unknown/transport outcomes yield skipped assertions
and `incomplete`; malformed known SDK data yields `error`; observed unmet
conditions yield `failed`. Captured independent facts remain visible when the
controller summary is missing or interrupted. Exit codes are 0 for `passed`,
1 for a completed non-passing result (including `error`), and 2 for input or
admission refusal before evaluation. JSON and JUnit express the same
assertions. There is no synthesized OTLP stream from these SDK JSON records.

## Native SDK semantics and launch boundary

The retained stock flight policy starts genuinely grounded and unarmed. It uses
ordinary ARM/takeoff/land calls, observes armed state, and requires at least 1.2 m
relative ascent. `unarmed-refusal` dispatches neither ARM nor takeoff and checks
four captured positions within 0.2 m of the initial relative altitude: this is a
caller precondition refusal, not firmware command denial.
`application-deadline` applies a two-second application deadline after ascent
and independently requests landing; it is not a native deadlock verdict.

The pinned
[MAVSDK ActionResult and Takeoff/Land interfaces](https://github.com/mavlink/MAVSDK-Proto/blob/5c81ecfeb6110cf74ba75ae50b78a1b265c05670/protos/action/action.proto)
report command responses. The method validates their closed enum and keeps
unknown/transport outcomes separate from observed rejection.
[Telemetry types](https://github.com/mavlink/MAVSDK-Proto/blob/5c81ecfeb6110cf74ba75ae50b78a1b265c05670/protos/telemetry/telemetry.proto)
supply relative altitude, landed state and armed state. A command ACK does not
prove physical effect: terminal telemetry must follow the corresponding issued
land phase in captured receiver order, and ascent samples must follow issued
takeoff. Telemetry between issuance and ACK remains valid.

The trusted operator's bounded regular `operator.json` supplies the fixed curl
executable, Engine Unix socket/API, exact actor IDs, owner/project, loopback gRPC
port and retained volume. Read-only stock Engine inspection checks actual image,
labels, namespace, command/environment, volume, tmpfs and loopback endpoint before
commands and refuses a mid-case actor restart. The controller owns SDK handles
and finite read jobs; it does not own producer actor removal.

The producer owner must independently close measurement, drain the PX4 logger
while simulation advances, retain the original ULog/native observations, and
verify cleanup. Only its actual owner-bound Engine cleanup observation can prove
empty actor/network inventory. Process exit, SDK disposal, image names and a
planned model do not prove cleanup or loaded-model identity. This method does not
consume ULog, model/SDF load provenance, native crash/hang proof, or selected
calibration or independently measured application-deadline duration; those
unsupported boundaries remain outside its verdict.
