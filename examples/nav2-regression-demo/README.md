# Nav2 qualification demo

## What you get

One command turns a recorded Nav2 `NavigateToPose` run into a readable
**qualification verdict report** that separates *"the navigation action
succeeded"* from *"the run met its acceptance criteria"*. All five cases below
report `NavigateToPose` **SUCCEEDED**, yet only the baseline passes qualification.
That gap — action success cannot override a violated postcondition, missing
evidence, or missing coverage — is the durable value: verdict semantics kept
separate (`passed` / `failed` / `error` / `incomplete`), evidence bound to the
original captured bytes, and a native Nav2 evaluator admitted through the public
SDK path.

| Case | Custody state | Verdict |
| --- | --- | --- |
| baseline | accepted criterion, full observations | **PASSED** |
| criterion-sensitivity | tightened acceptance tolerance, same capture | **FAILED** |
| insufficient-observation | postcondition observation not retained | **INCOMPLETE** |
| evidence-refusal | tampered evidence copy, custody refused | **ERROR** |
| missing-coverage | required original result omitted | **INCOMPLETE** |

The report shows, per case: the native action status and decoded GetResult CDR
fields, the measured value against its limit, the decisive assertion, the
recording timestamps and frames, evidence validity, and the
required/covered/unevaluated scope. Canonical `acceptance-result.v2` JSON and
JUnit are written by the public CLI for every evaluated case; the evidence-refusal
control intentionally has no result. A synthetic `qualification-verdict` JUnit gate fails for
any non-passed verdict so a CI gate cannot go green on action success alone.

## Export with your own key

For the external-user path, follow [Export and independently verify](EXPORT.md).
It generates a signed qualification bundle with your own publisher key and an
external operator profile, packages the complete retained evidence, and verifies
the export using your pinned public key. The default export is the baseline;
failed and incomplete assessments can also be exported without changing their
verdicts.

## Quick start

Requirements: Linux, Python 3.12, `uv` (or `pip`), `curl`, network access to
github.com / pypi.org, and an operator [Cosign](https://github.com/sigstore/cosign)
executable for key-only evaluator admission (on `PATH`, or pinned via
`ROBOTICS_COSIGN_PROFILE` / `--cosign-profile`).

```sh
cd examples/nav2-regression-demo
./run-demo.sh
```

The command installs the published acceptance SDK cohort from
[`../nav2-turtlebot3/requirements.lock`](../nav2-turtlebot3/requirements.lock),
builds and installs the native Nav2 evaluator, admits it with an ephemeral
Cosign key-only profile, and assesses the recorded capture through the five
custody cases via `robotics-acceptance evaluate`. The exact SDK and evaluator
versions are read from the lock and the evaluator `pyproject.toml`, never
hardcoded. It does **not** pull the simulation image and does not run physics.

Options: `--reinstall`, `--sensitivity-tolerance M`, `--cosign-profile PATH`,
`--operator-profile PATH`, `--skip-release-env`, `--prepare-only`.

Without `--operator-profile`, this command creates and deletes an ephemeral
private key for its smoke-test admission. That key is not an external trust root.
Use the export guide to establish your own trust configuration.

### Expected output (tail)

```text
CASE VERDICTS (all actions SUCCEEDED; only baseline passes)
------------------------------------------------------------------------
  baseline                   PASSED
  criterion-sensitivity      FAILED
  insufficient-observation   INCOMPLETE
  evidence-refusal           ERROR
  missing-coverage           INCOMPLETE
...
Qualification demonstrated: baseline=passed; criterion-sensitivity=failed;
insufficient-observation=incomplete; evidence-refusal=error; missing-coverage=incomplete.
```

The report is deterministic: timestamps come from the recorded observation
clocks, and the measured pose error is `0.1925 m` against the baseline limit
`0.35 m`. Run-specific digests and pins are written to `work/provenance.json`,
not to the report.

## What each case shows

- **baseline** — the recorded run reaches its goal with a final-pose error of
  `0.1925 m`; the accepted arrival tolerance is `0.35 m`, so qualification passes.
- **criterion-sensitivity** — the *same* capture is assessed with the arrival
  tolerance tightened to `0.10 m`. The robot still reports SUCCEEDED, but
  `0.1925 m > 0.10 m`, so the `action-success` assertion fails. This is labelled
  **criterion sensitivity**: only the declared acceptance tolerance changed; the
  robot configuration and the physical capture are unchanged. It is not a
  configuration regression.
- **insufficient-observation** — the original bytes are reused, but the
  postcondition observation is not retained in custody. The required observation
  is unevaluated (`$.observations.condition`), so qualification cannot pass.
- **evidence-refusal** — a copy of the captured GetResult CDR is truncated after
  finalization. Evidence verification refuses the mismatched bytes
  (`EvidenceValidationError`); the verdict is **ERROR**, not a robot FAILED.
- **missing-coverage** — the required original GetResult coverage is omitted, so
  the `action-success` outcome is skipped and uncovered
  (`$.assertions.…action-success`); qualification is **INCOMPLETE**. The
  unselected scenarios `cancel`, `timeout`, `server-failure` are explicitly
  outside scope.

Cases 3–5 reuse the real recorded bytes in a different custody state; no physical
fact is synthesized.

## How it stays real

- **Public evaluation path**: every case runs the installed
  `robotics-acceptance evaluate` CLI, which exercises the canonical core, the
  evidence-policy assertions, and the admitted product evaluator — not a direct
  aggregation.
- **Real evaluator admission**: the evaluator wheel is authenticated with an
  operator Cosign key-only profile; the scenario binding carries the real wheel
  SHA-256 and receipt SHA-256 produced by `qualify-evaluator.py`.
- **Evidence binding**: each assertion is bound to the SHA-256 of the original
  captured bytes; the GetResult CDR is decoded (encapsulation, `status` int8,
  result payload), not only hashed.
- **Recording identity**: the original capture's run identity, poses, clocks,
  goal UUID and CDR bytes are preserved; the custody run identifier is the issued
  run context binding required by the evaluator.

## Live capture through the native consumer

`run-live.sh` invokes the existing `native-check.mjs` attempt owner. Supply an
already admitted Nav2 consumer image, its evaluator requirements, and the
installed SDK interpreter described in
[`../nav2-turtlebot3/`](../nav2-turtlebot3/README.md). The native entry point
also requires the consumer's admitted Node environment and installed host package;
this wrapper does not install or update that environment:

```sh
./run-live.sh --image "$ADMITTED_CONSUMER_IMAGE" \
  --requirements "$PWD/nav2-requirements.json" \
  --python "$PWD/../nav2-turtlebot3/.venv/bin/python" \
  --output "$PWD/work/native-success" --case success
```

All input paths must be absolute and the output directory must be new. The
owner checks the selected image and inputs, records one fresh attempt, settles
the worker and recorder, and removes only its acquired container. It retains
`evaluation-inputs.json` for the public assessment command. The supported native
cases are `success`, `cancel`, `timeout` and `server-failure`; the recorded
five-case verdict demonstration remains available through `run-demo.sh`.

The selected image must contain the matching consumer and SDK environment,
including `/opt/consumer/bin/python`. The generic released simulation image is
not a substitute for this admitted consumer image. The entry point accepts no
remote shell environment and does not select an image from a release tag.

To download an already selected immutable repository digest without starting an
attempt:

```sh
./run-live.sh --pull-only --image "$ADMITTED_CONSUMER_IMAGE"
```

The headline A/B pair requires two fresh native captures under one frozen
acceptance criterion and an actual goal-checker configuration change. A single
capture does not establish that comparison. Image admission includes approval
of the owner's isolated preflight execution before the native attempt; neither
an image digest nor this wrapper grants that approval.

## Boundaries

The native wheel evaluator runs **in-process** in the harness Python process.
Admission and installed-wheel RECORD-hash guards authenticate its code; they do
not provide a resource, filesystem, or network sandbox. Use the runtime's OCI
evaluator executor for the contained execution path.

The demo reconstructs the run context and runtime manifest for the retained
recording, assigning their logical timestamps from its recorded start time.
Assessment and signing timestamps are current. A new signature authenticates
the exported bytes; it does not prove that the reconstructed scenario or context
existed before the original capture.

The offline verdict demo evaluates a recorded capture, not a fresh live Gazebo run. Cosign key-only
admission verifies the selected key's signature and subject/predicate binding; it
does not prove OIDC identity, transparency time, or build provenance. The verdict
covers the configured action outcome and fresh odometry/TF/AMCL pose facts; it
does not establish physics/localization accuracy, Gazebo ground truth, or complete
recovery.

## Provenance

`work/provenance.json` records the commit, release tag, simulation image digest,
SDK lock hashes, evaluator wheel and receipt SHA-256, per-case capture/workload/
scenario SHA-256, the original recording run identity and observation clocks, the
Cosign tool version and executable hash, and the tool versions. The released
image lock comes from the
[`v0.11.0-rc2`](https://github.com/mmkolpakov/robotics-runtime-infra/releases/tag/v0.11.0-rc2)
release; the SDK cohort is pinned by
[`requirements.lock`](../nav2-turtlebot3/requirements.lock) and
[`inputs.lock.json`](../nav2-turtlebot3/inputs.lock.json).

The source-foundation cohort in
[`config/foundation-lock.json`](../../config/foundation-lock.json) remains
contracts **0.21.1** / harness **0.22.2** at its pinned workspace revision.
The published-example cohort used by this demo is contracts **0.22.0** /
harness **0.23.1**, as pinned in the Nav2 `requirements.lock`. These are
separate compositions; running this demo does not upgrade the source foundation.

## Compliance

This demo produces qualification evidence that can support machinery and
cyber-resilience documentation — Machinery Regulation (EU) 2023/1230 (applicable
20 January 2027) and Cyber Resilience Act (EU) 2024/2847 reporting obligations
(from 11 September 2026) — and makes no claim of conformity.

## Files

- `run-demo.sh` — offline one-command verdict orchestration.
- `run-export.sh` / `export_bundle.py` — own-key signed export and verification.
- `EXPORT.md` — external operator bootstrap and independent verification.
- `test_export.py` — real-signature round trip and refusal tests.
- `run-live.sh` — finite native capture with an explicitly admitted consumer image.
- `regression_driver.py` — five-case assessment through the public CLI.
- `test_demo.py` — self-test demonstrating the failed robot qualification.
- `compose.demo.yaml` — retained generic released-simulation fixture; not used by the native entry point.

## Self-test

```sh
.venv/bin/python -m unittest test_demo -v
```

The self-test runs the five cases and asserts the verdict taxonomy, the failed
qualification while the action SUCCEEDED, the evidence-refusal ERROR, the
synthetic qualification-verdict JUnit gate, and real provenance digests.
