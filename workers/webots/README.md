# Native Webots worker

This provider targets Linux amd64 with Webots R2025a. The official Debian artifact is pinned by
SHA-256 from [Cyberbotics Packages](https://cyberbotics.com/debian/binary-amd64/Packages), separately
from the [release tag commit](https://github.com/cyberbotics/webots/tree/c6793d8f7230a311c4bc2a3101d9f1a8bc0aa01b).
GitHub's historical asset metadata has no digest; `upstream.json` records both identities and the
different release `target_commitish`. The worker uses Ubuntu 24.04, a frozen September 2026 archive,
the complete installed package inventory and SHA-256 of actual Webots/controller binaries.
The distribution's original notices are retained.

The owned WBT/PROTO fixture has one external native Python Supervisor, seed 1,
`synchronization TRUE` and one optimal physics thread. Its only step writer calls
Robot/Supervisor `step` in integer milliseconds, positive multiples of the observed
`getBasicTimeStep`. Time remains native float seconds. A falling body's observed position
demonstrates physics advance; the test does not qualify equal trajectories or exact tick counts
across engines.

The [upstream external controller launcher](https://cyberbotics.com/doc/guide/running-extern-robot-controllers)
uses local IPC. Readiness records the actual world path/title, source bytes, robot/model, native
clock and deterministic settings before the first measurement step. A finite measurement producer
opens a local lifecycle marker through the same owned volume. This marker is not a simulator
step/control API. The worker's controller remains the only native step writer.

Physics-only explicitly disables the camera and reports its observed sampling period zero.
Offscreen-camera enables it before stepping, retains BGRA bytes and uses native `saveImage` for PNG.
The capture timestamp is the controller's `getTime` observation after the step; no independent
Camera timestamp API is asserted. See [native camera semantics](https://cyberbotics.com/doc/reference/camera).
`--no-rendering` disables the main view; it does not disable camera computation. OpenGL is provided
by the declared container Xvfb/Mesa environment. Software rendering warnings and renderer identity
are retained. Native desktop/display and hardware GPU qualification require separate qualification.

Measurement state and camera payloads are fsynced/exported before native reset/quit and process
cleanup. Reset records request, native step result and observed clock regression in a new epoch.
Cancellation exports observed state/diagnostics and terminates each registered controller,
Webots and Xvfb process group, including groups whose root PID already exited. Bounded cleanup
observes disappearance with `killpg(pgid, 0)`; direct PID exit alone is insufficient. The worker
requires the C08 stock catatonit asset as actual PID 1 and retains its observed executable hash.
Compose requests `init: true` and Engine readiness requires observed `HostConfig.Init: true`.
Foreign owner markers are refused. ROS, PX4, simulation_interfaces and RTSP capabilities
are not declared.

Build in a project container context after downloading and verifying the named artifact:

```bash
podman build --platform linux/amd64 --ignorefile workers/webots/container.ignore \
  -f docker/webots.Dockerfile -t robotics-webots:candidate .
python3 workers/webots/qualify_native.py --image robotics-webots@sha256:MANIFEST \
  --init-path /absolute/project/host/.tools/oci-init/catatonit \
  --output /absolute/new-qualification-directory
```

The build fetches the official artifact and verifies its pinned SHA before extraction.
The image's root filesystem is read-only at
run time; temporary display/cache files use a bounded tmpfs. Production Compose uses worker UID
10001/GID 1000 and the host-owned external shared volume at the same `/run/robotics` path.
`compose.webots.podman.yaml` declares HOME's qualified parent namespace mapping separately.

The Cordis plugin in `host/src/plugins/webots-provider/` uses the existing Jobs and RunResources
services. Compose 5.3.1 invokes the workers; EngineMetadata observes the actual image/container,
owner labels, mounts, user, memory/rootfs/network state. Missing or mismatched facts refuse
readiness. Its measurement method opens the finite producer; evidence remains in the volume
after the owned Compose project is removed. Cleanup probes filter the observed project and
never delete the host-owned external volume.

Run `host/tools/qualify-webots.mjs` in the pinned Node environment with an installed native host
asset and shared volume. It checks real worker/Compose/Engine behavior, exports evidence, then
disposes the provider and verifies acquired resource cleanup. This is a source CPU/Mesa fixture
qualification, separate from released consumer or hardware/rendering acceptance.
