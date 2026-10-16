# Local attempt recovery

This optional Linux/systemd profile retains control identities and finalized bytes
when a coordinator is lost. It uses systemd's user manager, the existing bounded
Jobs service, Dockerode metadata and Compose. It does not start a workload again,
issue a native cancellation or establish a robot's final state.

## Record before effects

Run a coordinator in a separate user transient service with `Type=exec`,
`RuntimeMaxSec` at most 300 seconds, `TimeoutStopSec` at most 30 seconds,
`KillMode=control-group`, `SendSIGKILL=yes` and `Restart=no`. Use a unique
`rr-attempt-<UUID>.service` name. The consumer calls
[createLocalAttempt](../src/local-attempt.ts) before creating native resources.
It supplies the actual unit name/InvocationID and admitted local input byte
references. The function checks the active unit's typed D-Bus properties and
writes a private, immutable, fsynced record. Persist its returned ArtifactRef.

The record contains attempt/run/project identities, software or simulation
scope, coordinator identity and input references. It contains no environment,
credentials or worker command. Control inputs are canonical local files,
limited to 32 references of at most 64 MiB each. Native payloads remain outside
this control record.

A coordinator's cgroup owns its process tree. It does not own every container
in the Engine. `RuntimeMaxSec` and the bounded stop policy can settle hung
processes independently of JavaScript; resource cleanup still needs native
Engine ownership checks. A missing or collected unit is unknown, not a successful
exit. Keep failed units available until their recovery has been inspected.

## Recover explicitly

The operator supplies a fresh trusted
[LocalRecoveryPlan](../src/local-recovery.ts), including the original attempt
reference, Compose options, service requirements, export command, expected retained
file references, export receipt path and deadline. Every Compose input file must
match an original admission reference. The operator plan is control input,
not a document received through MCP or a stored workload log.

Execute the CLI under a bounded user service and a ready OS lock:

```sh
systemd-run --user --unit="rr-recovery-<UUID>" \
  --property=Type=exec --property=RuntimeMaxSec=120 \
  --property=TimeoutStopSec=2 --property=KillMode=control-group \
  --property=Restart=no \
  /usr/bin/flock --nonblock --conflict-exit-code 75 /private/recovery.lock \
  /absolute/node /absolute/infra/host/tools/recover-local-attempt.mjs \
  /private/attempt-reference.json /private/operator-plan.json
```

The operator must use the same lock for one attempt. JSON output and the service
journal retain the observed outcome. Exit 0 means the admitted resources were
released; exit 2 means retained/refused, and lock contention exits 75. These are
resource/control outcomes, not acceptance verdicts.

Recovery checks the exact quiescent invocation and current input hashes. It
observes every project resource and freshly admitted service requirement before
export or cleanup. Foreign, unbound or mismatched resources refuse effects.
It runs a bounded export through existing Jobs and verifies every expected
retained byte before invoking Compose stop/down. Control and retained files must
live outside Engine volumes that cleanup can remove. Ownership and coordinator
identity are checked again before destructive cleanup; actual empty inventories
and retained bytes are checked afterward.

The export receipt is committed before cleanup. An interrupted or failed export
blocks cleanup and reuse of that receipt; an explicit new export attempt needs
new control/output paths. A completed receipt is reverified and reused without
running its exporter again. Recovery never calls Compose up, a simulator reset
or a robot action.

The per-call deadline constrains metadata and subprocesses. Regular-file reads
and hashing can stall independently; the bounded systemd recovery service limits
the whole invocation outside JavaScript.

Cancellation, native final state and robot stop are reported as unknown. Releasing
containers does not establish any of them. Caller-specific lease, drain/flush and
hardware-stop obligations remain the native consumer's responsibility.

## Check the profile

After preparing the project's locked source assets, `npm test` exercises admission
and typed systemd checks. On a Linux user manager with project-scoped Podman API
access and the pinned Node/Compose executables:

```sh
host/.tools/node host/tools/qualify-local-recovery.mjs /private/recovery-report
```

The finite control fixture uses its own transient units and containers. It checks
coordinator loss, a hanging process/exporter, foreign ownership, failed export,
repeated recovery, the actual CLI/lock and byte preservation. It removes its owned
resources and retains reports separately. It does not qualify a simulator SDK,
physical operation, a cloud deployment or a production composition.
