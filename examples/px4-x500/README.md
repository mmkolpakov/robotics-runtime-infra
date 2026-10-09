# External stock x500 flight consumer

This source example uses the published host RC0 `Jobs` and generated `Mavsdk`
clients against an already owned stock PX4 1.17/Gazebo Jetty x500 producer.
It imports no private PX4 provider or source worker helper. The immutable
worker in `input-pins.json` is a local source image, not a published OCI release.

Install with `npm ci --ignore-scripts`. `npm test` runs portable consumer policy
controls; they do not qualify flight, hardware or producer cleanup.

The trusted operator supplies an absolute `operator.json` with
`curlExecutable` (`/usr/bin/curl`), the selected absolute Unix `engineSocket`
and producer-observed `engineApiVersion` (API 1.24–1.53), exact `px4Id` and
`serverId`, `ownerId`, the actual
`rr-px4-<24 hex>` Compose project, an unprivileged loopback `grpcPort` and the
retained named `runVolume`.
The producer must use the stock Compose profile, source image and labels.
The operator JSON is captured from an unchanged regular file bounded to 4 MiB;
symlinks, FIFOs and files changed during capture are refused.
Fixed read-only GET routes use the producer-selected Engine API through finite
public `Jobs`; curl config, redirects and arbitrary request URLs are not used.
Inspection verifies actual running IDs, image/digest, issued labels,
MAVSDK namespace parent, stock simulation command, full image environment with
only the issued PX4 partition override and checked native identity fields,
named retained volume, sized tmpfs and loopback port before any flight command.
Final reinspection refuses a
mid-case actor restart. The JSON is local operator configuration, not a remote
authorization mechanism.

Run one fresh producer per case, starting grounded and unarmed:

```sh
timeout --signal=TERM --kill-after=10s 240s node src/run.mjs \
  land /absolute/operator.json /absolute/new-case-output
```

Other cases are `unarmed-refusal` and `application-deadline`. The latter reaches
real takeoff, then a two-second application deadline requests `Action.land`;
it does not prove a native deadlock timeout. Every successful flight settlement
requires actual grounded and disarmed telemetry; command success alone is
insufficient. Both paths use the same takeoff guard, which checks actual armed
telemetry before dispatch. The positive path waits for armed telemetry after ARM.
The unarmed case receives that guard's caller precondition refusal: it dispatches
no takeoff or arm RPC and observes grounded/disarmed telemetry and no ascent.
It does not claim firmware command denial; a takeoff mode ACK is not evidence
of ascent. No force-arm or kill is used.

Unary action cancellation waits for the native callback before independent
landing. SDK child disposal does not prove remote telemetry-stream quiescence.
The script owns only its published SDK child handles and finite native read
jobs. It does not start, remove, pause or claim cleanup of the supplied producer.
The stock producer owner must close measurement, drain the PX4 logger while
simulation advances, retain ULog/native observations, then clean up and verify
actual actors/listener. On controller error retain diagnostics and settle
the flight before that cleanup. The external `timeout` is the process bound;
missing/partial evidence never becomes a successful producer lifecycle.

Output JSON retains original action responses and telemetry observations.
`controller-result` is not a C19 conformance document, H20 evaluator result,
JUnit verdict, measured cross-clock synchronization or hardware safety claim.
Public C19.0/H20.1 integration must use a separately qualified evaluator wheel,
verified receipt and real retained producer evidence. JSON/JUnit portable
closure and producer crash/hang retention are outside this controller's scope.
