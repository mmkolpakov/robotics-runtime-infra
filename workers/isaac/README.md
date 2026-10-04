# Isaac native worker

The selected runtime is Isaac Sim 6.1.0 / Kit 110.3.0. [runtime.json](runtime.json)
pins the tagged source, official Linux image and independently verified Windows
standalone archive. The owned USD fixture does not redistribute NVIDIA assets
or the vendor runtime.

`native-observe.py` uses native application, stage, physics and rendering APIs.
It retains raw diagnostics before closing the application. Physics seconds stay
floating-point seconds. Render requests do not establish captured frames or RTSP.

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

Vendor references:
[workstation installation](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/installation/install_workstation.html),
[requirements](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/installation/requirements.html),
[RTSP](https://docs.isaacsim.omniverse.nvidia.com/6.1.0/digital_twin/rtsp_camera_streaming.html).
