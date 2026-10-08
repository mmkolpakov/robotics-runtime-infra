# Stock PX4/Gazebo source profile

This worker uses unmodified PX4 v1.17.0 commit `d6f12ad1c4f70ad3230afd7d86e971421e02fef4`,
the stock x500 model and default world from its exact Gazebo-models gitlink.
The tagged upstream CMake selects native Jetty target names; the project target probe and
`px4_sitl_default` build verify that path. No bridge, firmware or physics patch is applied.
`source-lock.json`, the complete APT closure and hash-locked upstream Python requirements
describe these source inputs. The final image asserts payload/worker hashes and contains no ROS
packages. The stock default firmware still includes its upstream Micro-XRCE client.

PX4 owns stock Gazebo startup and sensors. A separate native MAVSDK server 4.0.3 shares the
PX4 container network namespace, so UDP14540 discovery remains inside the owned simulator.
Only its gRPC port is published on loopback. Native generated clients are imported from the
installed public host asset. Transport readiness, Core connected state, vehicle Health,
Action result and physical effect remain separate observations. Consumer policy calls the
native Action API directly; the provider does not define flight-controller methods.

`probe.py` is a finite native Gz Transport client. It records Scene, Pose_V and WorldStatistics,
and uses WorldControl for the final pause followed by observed quiescent native time. It does
not parse custom frames or implement physics. Nanosecond times remain strings. Pose/telemetry
ascent qualifies only the CPU stock x500 source simulation, never hardware, an application-specific
airframe, a complete flight mission, cameras, RTSP or rendering.

Build dependencies in `docker/px4-sitl-deps.Dockerfile`; download the immutable stock tag with
filtered Git and initialize only the exact SITL gitlinks declared in
`host/tools/prepare-px4-image.py`. Run the unmodified `make -j4 px4_sitl_default` inside that
project container, with the source mounted at `/opt/px4`. Then run
`prepare-px4-image.py --mavsdk-server <verified-binary> --deps-image sha256:<observed-id>`.
A new image context name is required for another build attempt; prior build facts are preserved.

The provider validates finite configuration before launch. Its native lifecycle starts
Compose, observes exact Engine/image/user/mount/Init/network facts, and requires native Core
discovery plus actual stock model presence. The consumer assembles an immutable root-array
Include profile with PX4 and MAVSDK services, pins the compiled closure, and invokes public
Admission/RunOwner. Measurement calls native generated Action/Telemetry clients.

`qualify-px4-stock.mjs` accepts an immutable `PX4_WORKER_IMAGE` and the actual
`PX4_VOLUME_ROOT` of the named `PX4_RUN_VOLUME`. The caller supplies absolute
`PX4_COMPOSE_EXECUTABLE` and `PX4_ENGINE_SOCKET` paths, plus an optional unprivileged
`PX4_GRPC_PORT` (default `50113`). Its project Unix Engine API uses
stock OCI init; the probe records actual PID1 binary identity. The consumer stops and drains the
stock logger while the native clock still advances, then
WorldControl pauses the world. Its retained drain callback reports the completed native command.
Run close/capture/export hooks retain observations, ULog bytes and worker logs in the external
volume before Compose stops the source.
The public owner verifies native disposal and actual container/network absence afterward.
A failed source attempt exports diagnostics before explicit retry cleanup and keeps its
historical error; cleanup recovery does not create a PASS.

This profile is a source candidate. Coordinated assets, published profile admission and the
strict released-consumer gate remain separate.
