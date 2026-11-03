# Stock PX4/Gazebo workers

Both source recipes use unmodified PX4 v1.17.0 commit
`d6f12ad1c4f70ad3230afd7d86e971421e02fef4` and the X500/default world from its
exact Gazebo-models gitlink. PX4 owns Gazebo startup, sensors and physics.
The upstream build selects Jetty; the firmware retains its stock Micro-XRCE client.

## Source recipes

Build dependencies with `docker/px4-sitl-deps.Dockerfile`. The existing
`host/tools/build-px4-stock.sh` prepares the exact clean source and SITL gitlinks,
then compiles `px4_sitl_default` inside the dependency image. Keep its immutable
dependency image ID for the final recipe.

`host/tools/prepare-px4-image.py` generates a fresh context under `host/.tools`
and invokes Podman build. Each context records source revisions, the dependency
image and payload/worker hashes. An existing context is not overwritten.

The default `legacy` recipe requires the pinned MAVSDK server 4.0.3 binary:

```sh
python3 host/tools/prepare-px4-image.py \
  --mavsdk-server /absolute/verified-mavsdk-server \
  --deps-image sha256:OBSERVED_DEPENDENCY_IMAGE
```

Its separate server shares the PX4 network namespace; only gRPC is published on
loopback. Generated clients come from the public host package. Its declared
inputs are in [source-lock.json](source-lock.json).

The `native-python` recipe uses the official hash-locked MAVSDK 4.1 wheel:

```sh
python3 host/tools/prepare-px4-image.py --controller native-python \
  --deps-image sha256:OBSERVED_DEPENDENCY_IMAGE
```

It uses `docker/px4-sitl-native.Dockerfile` and
`docker/python/px4-native-sdk.lock`. Stock uv installs the wheel into
`/opt/px4-native-venv`; the final image contains no separate MAVSDK server or uv
installer. The explicit worker allowlist contains the native controller, the
same private listener grammar shipped in the evaluator, the Gz probe and the
existing opaque exporter. Build hashes describe those exact files, not an
admitted image or a hardware qualification.

## Native control and finalization

[The external consumer](../../../examples/px4-x500/README.md) owns case policy.
`compose.px4-sdk.yaml` runs one owned PX4 actor with explicit instance `0`.
The provider observes actual Engine/image/user/mount/isolation and process facts;
Compose declarations alone are insufficient.

The controller uses synchronous native Action/Telemetry calls. Stock listener
snapshots establish the initial source-clock window; the original ULog supplies
sampled measurements. `probe.py` uses Gz Transport Scene, Pose_V and
WorldStatistics for readiness, and WorldControl for the final pause. It does not
implement flight control, physics or a frame decoder.

The existing public run owner controls finalization. Verified worker settlement
precedes logger closure; the logger stops while simulation advances. Closed
ULog bytes and original custody records are retained before owned-resource
removal. Interrupted waiting or an unresolved producer cannot establish cleanup
authority. The native CLI refuses before imports or Engine effects.

These profiles concern the selected stock simulation. They do not qualify a
different airframe, hardware, missions, cameras, RTSP or rendering.
