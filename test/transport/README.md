# Cross-domain transport qualification

Build the three local images, then run the same qualification on both transports:

```bash
docker buildx bake simulation acceptance-observer evidence-sink --load
test/transport/run
test/zenoh/run
```

The default path uses `compose.transport.yaml`, Fast DDS and `ros2/domain_bridge`.
The Zenoh wrapper adds the frozen `test/compose/compose.zenoh.yaml` overlay and
uses Cyclone DDS only in its two probes. Both runs create independent directories
under `artifacts/transport/`; set `ROBOTICS_TRANSPORT_REPORT_ROOT` to change this.
The report retains the Compose model, bridge version, exact configuration files,
probe observations, OTLP traces, evidence index and transport verdict.

Each run publishes 20 messages by default. `ROBOTICS_MESSAGE_COUNT` controls this
count for both paths. The publisher waits for the bridge subscription and the
destination's discovered bridge publisher. This barrier carries the run identity,
topic and type hash and is written atomically inside the new run directory.

Successful transport qualification requires every message and trace relationship
to pass the shared contracts. These checks cover transport; they do not execute
the full simulation or qualify its physics provider. See
[ADR 0006](../../docs/decisions/0006-qualify-native-domain-bridging-before-replacing-zenoh.md).
