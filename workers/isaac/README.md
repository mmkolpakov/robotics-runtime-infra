# Isaac native worker

The selected runtime is Isaac Sim 6.1.0 / Kit 110.3.0. [runtime.json](runtime.json)
pins the tagged source, official Linux image and independently verified Windows
standalone archive. The owned USD fixture does not redistribute NVIDIA assets
or the vendor runtime.

`native-observe.py` uses native application, stage, physics and rendering APIs.
It observes world loading, native rigid-body poses, physics time and paused state.
Physics seconds stay floating-point seconds. Optional camera capture uses the
native Replicator RGB annotator and retains RGBA/PNG before renderer cleanup.
Render requests and process exit zero do not establish RTSP consumer qualification.
SDK shutdown receives the workload/cleanup exit code so fast shutdown cannot hide errors.

The OCI deployment selects native Ubuntu 24.04, the NVIDIA container runtime and
successful vendor Compatibility Checker evidence. WSL CUDA discovery does not
qualify that deployment. The Windows deployment selects Windows 11 amd64 and
the pinned standalone archive; it requires its own Compatibility Checker and
native workload evidence. Neither deployment authorizes host driver, network
or operating-system changes.

Run the same bootstrap with the official SDK's `python.sh` or `python.bat`:

```text
python.bat native-observe.py --scene fixture.usda --expected-scene-sha256 SCENE_SHA256
```

The caller supplies absolute worker/scene paths and the admitted scene digest.
It retains stdout, exit status and logs. A source compile or version check does
not establish GPU execution or a successful qualification.

Native RTSP uses `isaacsim.streaming.rtsp.RTSPStreamWriter` and the existing
GStreamer consumer. Actual RTX frames, RTSP and cancellation/cleanup require
separate native evidence. A headless stream does not qualify a desktop GUI.

The bootstrap checks the native RTSP server factory before attaching the writer;
the upstream writer can log a server error and suppress later frames.

The Windows 6.1.0 archive runs CUDA physics and Vulkan offscreen capture on the
tested RTX 5070 Ti. Its bundled GStreamer DLLs import VCRUNTIME140D.dll and
ucrtbased.dll; these debug libraries are absent from that archive and the tested
lookup paths. The native RTSP plugin therefore failed to load. Windows RTSP remains
unqualified; SDK files and system libraries are unchanged. This Windows observation
does not qualify the Linux OCI deployment or a desktop GUI.

The source Cordis modules are in `host/src/plugins/isaac-provider`.
The root program installs `IsaacInputs`, issues an immutable owner-bound plan,
then supplies its token to the `IsaacNative` Loader entry. The plan binds retained
source references, an explicit successful source checker outcome with retained
byte references, finite episode counts, the absolute Compose executable
and Unix Engine socket, and distinct external input/result volumes. Its output
directory maps to `output/isaac/<scope>` in the result volume. The Node host creates
it with shared GID 1000; the SDK worker receives that supplementary group. The
runtime core remains the installed peer package. The package export is integrated
by the root project. The checker outcome is the trusted root's verification; opaque
vendor byte references alone do not establish that the checker passed.

The Node process distribution is diagnostic only; C08 uses a Debian Trixie client
container. Before any launch job, the provider reads Dockerode `/info` on the same
selected Unix Engine socket. Actual `OperatingSystem`, `KernelVersion`,
`Architecture` and `Runtimes.nvidia.path` must match this native Ubuntu 24.04/NVIDIA
profile. Missing fields remain incomplete. The local kernel still provides an
early WSL refusal; declarations and the client distribution never replace Engine
deployment facts.

`compose.isaac-provider.yaml` runs the same bootstrap in its optional private
phase mode. After native stage/physics initialization the application stays alive
and PAUSED. `ready(signal)` requires changing native paused observations, matching
source/scene bytes and a current native Engine observation. `measure(signal)`
opens the one finite episode; its native result/capture is retained while the
application remains PAUSED. `exportEvidence(signal)` returns byte references
before cleanup releases the application. Cleanup keeps graceful-close errors,
attempts bounded scoped teardown after fresh ownership checks, and independently
observes remaining physical resources. Startup failure diagnostics use
`diagnosticEvidence(signal)`; they do not establish readiness.

The private start/release/cancel files only connect these phases. Their token is a
correlation nonce printed in SDK argv, not an authentication or security boundary.
They implement no general simulator command protocol. `cancel()` requests early
episode closure; native step cancellation uses the SDK's step callback. No
persistent control/reset capability or completed-episode readiness is advertised.

Source compilation, installed Cordis Admission/Include refusal in the recorded WSL profile and
private marker tests are separate from positive SDK execution. The new PAUSED
provider phase and native Linux OCI execution still require C17 evidence. The
existing Windows batch workload observations do not qualify this provider phase.

Vendor references:
[workstation installation](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/installation/install_workstation.html),
[requirements](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/installation/requirements.html),
[RTSP](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/digital_twin/rtsp_camera_streaming.html).
