# AAS Gym benchmark archive

Import an already closed single-quad AAS Gym CPU speed benchmark as a new
V2 software run. The built-in Harness method checks the number of
rendered steps, the displayed 0.02-second increments and 250-second span,
and the consistency of the four rounded summary lines. The result covers
the recorded benchmark text for PX4 or ArduPilot. Flight, sensor and
physical clock quality require their own observations.

## Inputs

The importer accepts a closed capture handoff with these files. The
[synthetic test fixture](test_archive.py) shows the JSON fields and the
stock output format.

- `worker.out` is the original stdout in the capture directory. Preserve
  carriage returns and summary spacing.
- `RUN-RESULT.json` in the same directory records `autopilot`, `argv`,
  `source_commit`, `images`, `started_utc`, `completed_utc`, and
  `benchmark_summary`. The summary stores the original duration, speedup
  and throughput lines. Its `scope_binding_sha256` and
  `operator_binding_sha256` bind the configuration and authorization.
- The result's `state` is `benchmark-completed-and-owned-inventory-empty`.
  It records zero `worker_exit` and `api_exit`, an empty `cleanup_errors`
  list, and an empty `evidence_errors` list if supplied. These are the
  original owner's closure observations.
- The operator authorization repeats `autopilot`, `argv`, `source_commit`,
  and `images`, and carries the configuration's `binding_sha256`.
  Supply the original configuration and authorization bytes. The
  configuration repeats `source_commit` and `images` and records
  the selected command in `cases[autopilot].argv`. Each image role,
  `aircraft` and `simulation`, supplies `config` and `manifest`
  digests in `sha256:<digest>` form.
- The retained review contains `stdout_sha256` and `result_sha256`.
  Supply the review's expected digest from the capture handoff. The
  importer verifies these pins before creating the output directory.

The accepted benchmark command uses one invocation of `speedup` with
one quad, camera and lidar disabled, and CPU execution.

## Run the importer

Use Python 3.12 with published Contracts 0.22.0 and Harness 0.24.0.

```sh
python3.12 -m venv .venv
.venv/bin/python -m pip install --require-hashes --only-binary=:all: -r requirements.lock
.venv/bin/python -I archive.py \
  --capture /path/to/closed-capture \
  --binding /path/to/configuration-binding.json \
  --authorization /path/to/operator-authorization.json \
  --review /path/to/benchmark-review.json \
  --review-sha256 "$EXPECTED_REVIEW_SHA256" \
  --output /path/to/new-assessment
```

The command prints the result and evidence index paths. It writes a fresh
run context, scenario, runtime manifest, observation, exact captured byte
copies, OTLP gauges and the Harness JSON and JUnit result. Exit 0 means the
declared checks passed. Exit 1 indicates a completed assessment whose
criteria were unmet. Exit 2 indicates invalid inputs or an incomplete import.

The metrics and measurement window use the import host's UTC. The
original UTC interval stays in the imported evidence. Simulated time in
the display remains a recorded value. The summary check intersects the
wall-duration intervals implied by the printed values at their respective
precisions.

Harness re-evaluation checks the indexed digests and the retained gauges
against the scenario thresholds. Run the importer again to recompute the
gauges from the original bytes. For Harness 0.24 re-evaluation, keep the
indexed files available at their recorded URI paths and write the result
to a separate directory.

Run the offline controls with the same installed SDK.

```sh
.venv/bin/python -I -m unittest discover -s . -p 'test_archive.py' -v
```
