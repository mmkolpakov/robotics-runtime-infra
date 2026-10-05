# Stock x500 source profile

The immutable worker and source inputs are recorded in `source-inputs.json`.
The source qualification tool assembles a read-only root-array Include closure:
PX4 is the required backend binding; the native MAVSDK handle service is isolated and its
transport/Core discovery observations are consumed by PX4 readiness. Health and Action
results remain consumer checks.

Invoke `host/tools/qualify-px4-stock.mjs` with `PX4_WORKER_IMAGE` from these inputs and the
actual `PX4_VOLUME_ROOT` observed for the named retained volume. The program uses the project
Unix Engine endpoint, native Compose 5.3.1, and the installed public core/infra package exports.
It requires real stock physics ascent, recorder stop while native time still advances, final
WorldControl pause/quiescence, byte export before teardown, actual DISPOSED, and native cleanup.

This source profile is not an admitted published H release profile.
