# Installed ROS engine profiles

prepare.py accepts --engine podman|docker; Podman remains the default.
The generated identity records the selected engine and exact native
HostConfig.UsernsMode expectation: private for the existing Podman profile,
and the observed default empty string for Docker. The Docker profile makes
no user remapping or rootless claim.

The launcher and installed bootstrap require native version metadata to
identify the selected engine. Container admission still checks exact images,
users, writable and read-only volume mounts, ownership, and acquired namespace
parents. The neutral Compose files serve Docker; the selected Podman overlays
restore the existing keep-id configuration. Health checks remain automatic
and unchanged.

Prepare the consumer in a fresh directory outside the source repository using
the exact two TGZ archives, deployment commit, Compose binary and observed
helper RepoDigests. The immutable installed profile includes application files,
identity, package files and deployment inputs. Run launch.mjs from that
installed directory against the selected Unix socket and full Node RepoDigest.
The launcher requires a native 404 before using new volume names; Docker volume
operations use that explicit socket.

A successful fixture retains the original live result, verifies cleanup,
removes the owned source volume, then checks every retained SHA-256 and size
before public aggregate, package, signing and portable verification. The positive route
qualifies installed ROS. The separate negative-lifecycle route checks
interruption and foreign cleanup refusal with retained diagnostic evidence;
it cannot publish a successful measurement or aggregate. Corrupted retained
payload acceptance remains a separate required gate.

Configuration checks use the existing pinned tools without native workloads:

    ROBOTICS_COMPOSE=/absolute/path/to/pinned/docker-compose python3 -m unittest discover -s host/test/fixtures/installed-legacy -p test_prepare.py -v
    node --test host/tools/qualify-legacy-live.test.mjs

The existing foundation job calls scripts/ci/host/run-installed-legacy.sh.
Its --check-config route is also used by static analysis and performs no image
build or native workload. The full route builds ordinary package assets and
the existing helper Dockerfiles, then resolves exact observed RepoDigests
through an ephemeral official registry bound only to runner loopback.

Docker overlays add the group measured from the actual Unix socket. Both
installed processes verify the socket stat GID and native HostConfig.GroupAdd
array. The socket mode is not changed; default namespace metadata remains
the exact empty string, without a remapping or rootless claim.

Prepare with --negative-lifecycle and run negative-launch.mjs with the final
argument startup-cancel, foreign-cleanup, cancel or timeout. Startup
cancellation interrupts the exact native application-start command after
simulation acquisition. The foreign case preserves an exact test-owned
container with another run label while the provider refuses project teardown.

The cancel and timeout cases first observe READY, open measurement, and bind
the actual running source and observer. They interrupt the existing public
closeMeasurement producer after two seconds using cancellation or an explicit
native producer deadline signal. The RunOwner profile deadline remains
240 seconds; this case does not claim that profile deadline expired.
The interrupted producer settles before native last-state capture, writer
drain, diagnostic export and cleanup. Completion must remain an error.
Every case removes only its owned source volume and then verifies retained
hashes through an installed process with only the retained volume mounted.
