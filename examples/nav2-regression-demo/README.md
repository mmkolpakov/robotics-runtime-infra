# Nav2 acceptance regression demo

## What you get

One command, on released infra `v0.11.0-rc2`, shows the difference between *"the
navigation action succeeded"* (what a green CI gate checks) and *"the run actually
met its acceptance criteria"* (what the qualification verdict checks). It assesses
a recorded Nav2 `NavigateToPose` run twice - baseline and a broken-commit parameter
change - and prints a readable verdict report with the evidence. The broken commit
stays **green in CI** but flips the acceptance verdict to **FAILED**.

That gap is the durable differentiator: verdict semantics (`passed` / `failed` /
`error` / `incomplete` kept separate), evidence bound to original bytes, and a
native Nav2 evaluator - not a synthetic pass/fail.

## 10-minute experience

Requirements: Linux, rootless podman (or docker), Python 3.12, `uv` (or `pip`),
`curl`, and network access to github.com / ghcr.io / pypi.org.

```sh
cd examples/nav2-regression-demo
./run-demo.sh
```

That single command:

1. downloads `release.env` from the `v0.11.0-rc2` release (released mode,
   digest-pinned, **no snapshot mirror**);
2. pulls the released rc2 simulation image from GHCR;
3. installs the published acceptance SDK (harness 0.23.1 / contracts 0.22.0)
   with `--require-hashes` and builds the native Nav2 evaluator 0.3.0;
4. issues real `acceptance-scenario.v2` documents (`robotics-acceptance explain`
   + `create-run`), validates them (`robotics-contracts validate`), finalizes the
   evidence, and assesses the recorded run twice;
5. prints `work/report.txt`.

Expected tail:

```
BASELINE (accepted parameters)        verdict: PASSED
BROKEN COMMIT (tightened tolerance)   verdict: FAILED
Regression demonstrated: baseline=passed, broken=failed.
```

Fast re-run (skip the image pull, reuse the venv): `./run-demo.sh --skip-pull`.
Change the broken tolerance: `./run-demo.sh --broken-tolerance 0.15`.

## What the regression is

The recorded run reaches its goal with a final-pose error of ~0.19 m and reports
`NavigateToPose` **SUCCEEDED**. The baseline accepts arrival within 0.35 m ->
**PASSED**. The broken commit tightens the arrival tolerance to 0.10 m. The robot
still reports SUCCEEDED (CI green), but 0.19 m > 0.10 m, so the acceptance verdict
is **FAILED**. The physical capture is identical and unmodified; only the declared
acceptance parameter changes. Action success cannot override a violated physical
postcondition.

## How it stays real

- **Released mode**: images come from the published `v0.11.0-rc2` `release.env`,
  pinned by digest, pulled from GHCR. No `snapshot.ubuntu.com`, no source build.
- **Published SDK**: harness 0.23.1 / contracts 0.22.0 from PyPI with
  `--require-hashes`.
- **Native evaluator**: `nav2_turtlebot3_evaluator` 0.3.0 (the Nav2 consumer
  engine) computes the verdict from captured odom/TF/AMCL facts and the original
  GetResult CDR.
- **Real CLI**: document issuance calls `robotics-acceptance explain` +
  `create-run`; each scenario is validated with `robotics-contracts validate`.
- **Evidence binding**: every assertion is bound to the SHA-256 of the original
  captured bytes.

## Boundaries (read this)

- The Nav2 evidence is a **recorded capture**, not a fresh live Gazebo run. The
  demo exercises the real verdict/evidence pipeline over recorded observations;
  it does not launch physics.
- Evaluator admission uses **document-control bindings**. Cosign-admitted native
  launch (the full `robotics-acceptance evaluate` path) and live Gazebo+Nav2
  execution inside the released image are the gated next step; cosign is not
  required for this demo.
- The released simulation image is the domain-neutral infra base; the Nav2
  consumer brings its own stack. Live Nav2 execution requires the admitted
  composition (see `../nav2-turtlebot3/README.md`).
- Verdict scope: configured action outcome + fresh odometry/TF/AMCL pose facts.
  It does not establish physics/localization accuracy, Gazebo ground truth, or
  complete recovery.

## Files

- `run-demo.sh` - one-command orchestration.
- `regression_driver.py` - prepares documents, validates, finalizes evidence, runs
  the native evaluator twice, writes the report.
- `compose.demo.yaml` - released-mode simulation service (compose-capable hosts).
- `../nav2-turtlebot3/` - the Nav2 consumer engine: evaluator 0.3.0, recorded
  fixtures, document writers. This branch carries the engine update (PR #94)
  pinned to the published contracts 0.22.0 / harness 0.23.1 cohort; the earlier
  0.2.1 on `main` predates that SDK and is not compatible with it.

## Troubleshooting

- **`gh` absent**: `run-demo.sh` falls back to the release asset download URL,
  which is independent of the GitHub REST API quota.
- **No compose provider**: `run-demo.sh` pulls with podman/docker directly.
- **Image pull slow/unavailable**: the verdict demo still runs and the report
  notes the pull status. Use `--skip-pull` to skip it.
- **GitHub API rate-limited**: release asset downloads are unaffected.
