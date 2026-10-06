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
before public aggregate, package, signing and portable verification. This is a
positive installed ROS qualification fixture. Cancellation, deadline, foreign
cleanup and corrupted retained payload scenarios require their own installed
ROS gates; this profile change does not close the full consumer acceptance.

Configuration checks use the existing pinned tools without native workloads:

    ROBOTICS_COMPOSE=/absolute/path/to/pinned/docker-compose python3 -m unittest discover -s host/test/fixtures/installed-legacy -p test_prepare.py -v
    node --test host/tools/qualify-legacy-live.test.mjs
