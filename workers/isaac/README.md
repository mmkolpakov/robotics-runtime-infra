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

This source bootstrap is a finite SDK episode. A complete Cordis provider and live
backend admission are still required. A completed episode does not implement a
persistent backend's ready(), control or reset capabilities.

Vendor references:
[workstation installation](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/installation/install_workstation.html),
[requirements](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/installation/requirements.html),
[RTSP](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/digital_twin/rtsp_camera_streaming.html).
