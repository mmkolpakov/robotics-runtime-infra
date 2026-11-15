# Run the AAS PX4 takeoff and landing example

Run one `x500` in headless Aerial Autonomy Stack SITL. The example starts the stock aircraft and
simulation images with a loopback MAVProxy heartbeat, sends the upstream ROS 2 Takeoff and Land
actions, and captures the native flight state, MCAP and ULog.

## Install from source

Use Node and npm from [`host/package.json`](../../../host/package.json), Compose 5.3.1, and the Unix
socket of a dedicated, admitted rootless Engine. The two stock AAS actors run privileged inside that
boundary. MAVProxy uses the installed `arduuser` account in the simulation image. Obtain the host
TGZ from the [host rc1
release](https://github.com/mmkolpakov/robotics-runtime/releases/tag/host-v0.1.0-rc.1) and verify
its release checksum. The infra host package is built from this checkout.

```sh
install -D "$HOST_TGZ" host/.tools/core-703e74ed1d9626eda4fdcba29540204d3b4f36e1.tgz
npm ci --prefix host --ignore-scripts --no-audit --no-fund
npm run --prefix host build
npm pack ./host --pack-destination "$BUILD"
install -d -m 700 "$EXAMPLE"
for file in compose.yaml profile.yml provider.mjs run.mjs; do
  install -m 444 "examples/aerial-autonomy-stack/native/$file" "$EXAMPLE/$file"
done
npm install --prefix "$EXAMPLE" --no-save --package-lock=false --ignore-scripts \
  "$HOST_TGZ" "$BUILD/robotics-runtime-infra-host-0.1.0-rc.1.tgz"
```

## Choose the inputs

Admit and stage the two OCI images before starting. Select a free private `/16` on the chosen Engine
and reserve that subnet slot with a lock. Initialize the values below from the admitted image and
file identities. Replace the example paths and hashes with those supplied by your profile.

```json
{
  "runId": "4b4a2a38-3f12-4352-9b99-bd08b7ead902",
  "compose": "/opt/tools/docker-compose",
  "socket": "/run/user/1000/engine.sock",
  "output": "/srv/robotics/runs/aas-px4-001",
  "subnetPrefix": "10.43",
  "images": {
    "simulation": {"reference": "registry.example/aas/simulation@sha256:<manifest>", "id": "sha256:<config>"},
    "aircraft": {"reference": "registry.example/aas/aircraft@sha256:<manifest>", "id": "sha256:<config>"}
  },
  "admissionRefs": [
    {"uri": "file:///srv/robotics/admitted/aas.json", "sha256": "<sha256>", "size_bytes": 1234}
  ]
}
```

Give each attempt a new UUID and output path with an existing parent directory. Make the input JSON
and every file in `admissionRefs` read-only before starting. Use the same UUID as the input and the
lock for the selected Engine and subnet.

```sh
systemd-run --user --wait --pipe --unit "rr-attempt-$RUN_ID" \
  -p Type=exec -p KillMode=control-group -p RuntimeMaxSec=300 -p TimeoutStopSec=30 \
  flock --no-fork --nonblock "$SLOT_LOCK" node "$EXAMPLE/run.mjs" "$INPUT"
```

## Read the result

`completion.json` records the attempt, any flight error and the run owner’s completion. Native
snapshots capture ascent and touchdown. `closed-files.json` records file identities and the finite
copy request used before Compose cleanup. The output includes `metadata.yaml`, `flight_0.mcap`, and
`px4.ulg` after a complete export.

Inspect the MCAP with stock `ros2 bag info "$OUTPUT"` and the ULog with `ulog_info
"$OUTPUT/px4.ulg"`. Decode the four action channels with the exact ROS types from the admitted
aircraft image. The [Gym archive example](../README.md) covers the separate step benchmark.

## Cancel or inspect a retained attempt

Send SIGINT to the coordinator for an orderly run interruption.

```sh
systemctl --user kill --kill-whom=main --signal=SIGINT "rr-attempt-$RUN_ID.service"
```

This stops the measurement and lets the coordinator settle the recorders. The result remains
interrupted. A ROS action may continue inside the simulation until the owned project stops.
A unit-wide stop or runtime limit can leave the project retained.

To inspect a retained attempt, wait for the coordinator to exit and acquire the same slot lock.
Set the Compose executable, input variables and Unix socket from the admitted inputs. Select the
recorded `projectName` from `attempt.json`. Inspect each actor, network and volume for that Compose
project and its `org.robotics.runtime.run-id` label. Verify the GCS container's namespace against
`namespace-parent.json` when that record exists.

```bash
export DOCKER_HOST="unix://$SOCKET" DOCKER_CONFIG=/nonexistent
compose=( "$COMPOSE" --project-name "$PROJECT" --file "$EXAMPLE/compose.yaml" )
"${compose[@]}" ps --all
"${compose[@]}" logs --no-color > "$OUTPUT/retained-compose.log"
```

After confirming ownership, stop the project and copy the available evidence to a fresh directory.

```bash
"${compose[@]}" stop --timeout 5
"${compose[@]}" cp aircraft:/evidence/flight "$RECOVERED/flight"
"${compose[@]}" cp simulation:/aas/github_apps/PX4-Autopilot/build/px4_sitl_default/rootfs/0/log \
  "$RECOVERED/ulog"
```

Verify readability and the SHA-256 values in `closed-files.json` when it exists. Keep incomplete
recordings as diagnostics. After the evidence copy is verified and the ownership check still
matches, remove the retained project with `compose down` through the same client.

```bash
"${compose[@]}" down --timeout 5 --volumes --remove-orphans
```
