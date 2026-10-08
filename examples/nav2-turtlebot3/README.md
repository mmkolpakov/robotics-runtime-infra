# Nav2 TurtleBot3 consumer

This headless example runs the official Nav2 Jazzy TurtleBot3 Waffle simulation with Gazebo
Harmonic, the supplied map/world/model, and AMCL. It uses the published runtime host package for
bounded native commands, published contracts 0.19.0 and acceptance harness 0.20.1 for evaluation,
and the upstream ROS APIs for navigation and recording.

The scenario seed is consumer metadata; this recipe does not qualify Gazebo or AMCL engine-seed
determinism.

The selected ROS cohort is Nav2 1.3.13, minimal TurtleBot3 simulation 1.0.1, Gazebo Sim 8.15.0,
rclpy 7.1.12, and rosbag2 0.26.11 on Ubuntu 24.04. Direct package pins are in inputs.lock.json and
the Dockerfile; retained image identities and the installed package inventory identify each
execution. These direct pins do not make future APT rebuilds byte reproducible. The ROS image uses
producer-requirements.lock; requirements.lock adds the published MCAP reader extra for the separate
offline processor.

## Run a case

Use Node 24.21.0, npm 11.19.0, Python 3.12, uv, OpenSSL with Ed25519 support, and rootless Podman.
Install the public Python inputs and build the consumer evaluator from this directory:

    npm ci
    python3 -m venv .venv
    .venv/bin/python -m pip install --require-hashes -r requirements.lock
    uv build --wheel --out-dir dist evaluator
    .venv/bin/python -m pip install --no-deps dist/nav2_turtlebot3_evaluator-0.1.0-py3-none-any.whl
    .venv/bin/python qualify-evaluator.py --wheel dist/nav2_turtlebot3_evaluator-0.1.0-py3-none-any.whl --tests test_evaluator.py --native-cases evaluator/tests/fixtures --python "$PWD/.venv/bin/python" --contracts "$PWD/.venv/bin/robotics-contracts" --output results/evaluator

The bundled observation fixtures are consumer predicate test inputs, not fresh execution receipts.
Generate the requirements and issue a canonical run context through the public harness before
starting the world:

    .venv/bin/python make-scenario.py --case success --evaluator-receipt results/evaluator/receipt.json --middleware-profile fastdds.xml --schema nav2.schema.json --output results/scenario.json
    .venv/bin/robotics-acceptance create-run --scenario results/scenario.json --output results/run-context.json --domain nav2=simulation --time-authority sim_clock --time-source gazebo-harmonic-clock --extension-schema "urn:nav2-turtlebot3:scenario:v1=$PWD/nav2.schema.json"
    podman build --tag nav2-turtlebot3-consumer .
    image=$(podman image inspect --format 'sha256:{{.Id}}' nav2-turtlebot3-consumer)
    node native-check.mjs "$PWD/results/success" "$PWD" "$image" success "$PWD/results/run-context.json" "$PWD/results/scenario.json" "$PWD/.venv/bin/robotics-contracts"

Use a new output directory for each invocation. Select cancel, timeout, or server-failure in both
the scenario and driver, and issue a new context for each case. The driver admits the exact
container identity and SIGINT behavior before starting it, retains the worker and recorder results,
and verifies their absence before orderly native shutdown and removal. An unsettled producer or
ambiguous native state retains the owned container for diagnosis; a stopped command client alone
does not authorize cleanup.

The cases check:

- success: a real accepted NavigateToPose goal, SUCCEEDED result, odometry displacement, map-frame
  arrival, fresh required TF edges, and a new AMCL pose after the public no-motion-update service.
- cancel: an explicit cancel acknowledged for the same goal and a CANCELED result.
- timeout: a two-second consumer application deadline followed by cancellation. This is not a hard
  process timeout.
- server-failure: controlled lifecycle shutdown and an unavailable action server. This does not
  demonstrate a crash or deadlock.

## Evidence and evaluation

Each run retains the original JSON observations, serialized client GetResult response, native
process facts, and a rosbag2 MCAP recording. The recorder waits for actual subscriptions to all
seven explicit topics, including hidden action feedback and status, and closes through the public
Recorder API.

In the checked rosbag2 0.26.11 cohort, action channels contain original CDR but empty message
definitions. Sensor, TF, AMCL, and Clock definitions are self-contained; action CDR needs the
matching installed ROS message types. GetResult is a separately labelled client observation, not a
service response recorded by the topic bag. No message definitions are synthesized and no CDR codec
is supplied.

derive-otlp.py projects immutable callback metadata into standard OTLP for offline evaluation. It
requires the selected original SHA and preserves native integer publication sequences. Message age
uses RMW reception minus source timestamps; ROS simulation time is never subtracted from wall time.
Sequence gaps are measured only between observed single-publisher samples. Derived metrics are
labelled offline and cannot establish live collector behavior.

The consumer evaluator is installed from its built wheel and bound through a typed artifact receipt.
qualify-evaluator.py checks installed wheel bytes, runs the consumer controls, and creates local-key
provenance through actual Ed25519 signing and verification. This explicit local trust policy is
separate from vendor or keyless provenance. Public robotics-acceptance evaluate produces JSON and
JUnit for retained evidence. Its offline result explicitly leaves native Clock timing, graph, and
shutdown unevaluated; numeric placeholders are not measurements. Native graph and cleanup facts are
retained separately. Expected application negatives cannot override an ERROR or FAILED core ROS
policy result.

Full action/service-event recording through native introspection requires a separately qualified
maintained ROS cohort migration. This example does not claim that profile, hardware qualification,
or complete runtime lifecycle coverage.
