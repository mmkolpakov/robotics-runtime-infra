# Infra execution adapters

This source candidate supplies Compose execution and observed Engine metadata.
The Cordis host owns the single finite Jobs/Execa route; `ComposeExecution`
receives that service and delegates argv, cancellation, limits, stdout and exit
results. It fixes the project/files/Unix endpoint and rejects arguments that
replace them. Simulator SDKs and Python rules do not enter this package.

Dockerode 5.0.1 first reads the same socket's unversioned `/version`. The adapter
selects the explicit intersection of the configured client API range and the
observed server range, then creates a versioned client. This is not automatic
Dockerode negotiation. Compose 5.3.1 performs its own native negotiation.
`EngineMetadata.inspect` retains raw container, image and network answers and
checks owner labels, native IDs/digest, user, state/exit, named mounts and every
used HostConfig field. Required missing or mismatched facts produce
`incomplete`; resolved Compose declarations never supply an observed fact.
A native `NetworkMode: none` is recorded as no network attachment, including
Podman's `none` pseudo-network; it is not an inspectable network resource.

`compose.host-storage.yaml` is a finite Node OCI storage fixture, distinct from
Python worker qualification. The host is UID/GID 1000; the fixture worker is
UID 10001 / GID 1000. A root container initializes only the acquired named
volumes. Both use `/run/robotics`; a second named volume at
`/run/robotics/input` is read-only for the worker. Actual native UID/GID,
read-only `EROFS`, an integer larger than JavaScript's exact Number range, raw
bytes/hash, native metadata and cleanup inventories are checked. Payload bytes
and logs are exported before the volumes are removed.

HOME runs rootless Podman 4.9.3 under UID/GID 1001. Its Docker-compatible
HostConfig projects `UsernsMode: private`, an expanded CapDrop list and
normalized SecurityOpt. That projection does not express the keep-id mapping.
The preflight reads the child's native `/proc/self/uid_map` and `gid_map`,
which are relative to its parent namespace, then reads the actual rootless
parent ID maps through the same socket's versioned native Podman info API.
The observed chain maps container 1000 to parent 0 to HOME 1001. The host image
also proves access to the original mode-0600 project socket through Compose.
No supplemental group or socket permission change is required. The owned
profile list persists for `down`; actual inventory exposed a profiled service
left behind by a teardown that omitted that list, and that diagnostic is
retained. Cleanup now requires empty native owner inventories.

A failed diagnostic incorrectly compared a child's parent-relative ID to the
HOME ID directly. Its failure is retained; it does not prove that Compose
ignored keep-id. [Linux user namespace semantics](https://man7.org/linux/man-pages/man7/user_namespaces.7.html)
explain why both mapping levels are required. Compose declarations never fill
that native evidence. Required missing maps and mismatched fields fail closed.
Both containers' native capability sets must be empty.

The mapping does not assert that all worker images use UID 10001: the retained
simulation/observer use Ubuntu's UID 1000, permit-preflight uses 10002, and
evidence-sink uses 10001. Their own entrypoints, cache needs, native identity
and writable outputs must be qualified separately. Shared/system sockets and
host network configuration are unchanged.

Build and run the source checks with the pinned Node 24.21.0 / npm 11.19.0:

```sh
cd host
npm ci --ignore-scripts --no-audit --no-fund
npm test
```

A project-scoped Unix Podman API service and verified Compose executable can
be prepared under `.tools` without changing the machine. The finite preflight
requires the compiled core host's public `Context/Jobs` exports:

```sh
node host/tools/qualify-storage.mjs \
  /absolute/infra /absolute/core-host/dist/src/index.js \
  /absolute/project-engine.sock /absolute/retained-output \
  compose.host-storage.podman.yaml <optional-source-host-image-id>
```

For Docker CI, omit the final Podman overlay argument. The same Compose/Jobs
route and metadata checks apply. Docker CI has not yet run for this candidate.
The checked HOME source results cover Engine metadata, the Node OCI storage
fixture and a compiled source host image accessing its mode-0600 socket through
Compose; they do not qualify installed Python worker entrypoints, full B3,
released host assets or the complete C08 acceptance surface.

`docker/host.Dockerfile` consumes a compiled npm-pack asset as the separate
`host-asset` build context with required SHA-256. `docker-bake.hcl` exposes the
`cordis-host` target outside the release group. The image keeps the official
Node/Debian 13 runtime, compiled adapters and native `cordis` CLI, plus a
checksum-pinned standalone Compose 5.3.1 executable. It includes no Python or
ROS. `compose.host.yaml` mounts only the actual host Engine socket as a bind;
worker inputs/results use external named volumes. A container's private path
is not an Engine host bind source. The released H asset and its shrinkwrap,
provenance and immutable identity remain C20/C21 gates, independent of Python P.
