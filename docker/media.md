# Finite native media worker

`media.Dockerfile` builds an independent Ubuntu 24.04 Python/GI worker. The
Ubuntu base, bootstrap CA source and 20260930 APT snapshot are pinned. Only the
CA bundle is copied from the bootstrap stage; the final package closure has
no ROS or simulator packages. The complete observed APT closure is committed
as `apt/media-closure.lock` and every build compares its installed inventory
before accepting the image.

The source candidate observes GStreamer 1.24.2 and GI's Gst 1.0 API. It uses
`Gst.parse_launch`, `set_state`, `get_state` and native GstBus EOS/ERROR. The
finite `host/workers/media/probe.py` proves an actual two-buffer videotest EOS,
a native missing-file ERROR, and NULL cleanup for both pipelines. This accepts
CPU media API/lifecycle only; it is not sensor rendering, RTSP, camera hardware
or Isaac/GPU qualification. `gst-launch` is diagnostic tooling, not this worker's
production API.

The final worker is UID/GID 1000. `compose.media.yaml` gives it readonly inputs,
run-owned named output storage and a private temporary Gst cache. The
application's admitted immutable worker/pipeline is supplied by the host asset
and invoked through the single Compose/Jobs route. The `media-worker` Bake
target remains outside the release group until C21 gates assign its released
identity. A source image ID does not substitute for a released image digest.
