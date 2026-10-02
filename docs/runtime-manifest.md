# Runtime manifest production

`emit-runtime-manifest` collects runtime facts and delegates validation and JSON
serialization to `robotics-contracts runtime-manifest init`. The CLI comes from the
pinned workspace wheels in `/opt/contracts`; inference environments remain separate.
The manifest records the same workspace revision for contracts and harness.
The default lock is `/usr/share/robotics-runtime/foundation-lock.json` from the image;
standalone source deployments can supply the checked lock through `ROBOTICS_FOUNDATION_LOCK`.

The caller supplies `ROBOTICS_RUNTIME_ID`, `ROBOTICS_OCI_REFERENCE`,
`ROBOTICS_OCI_DIGEST`, `ROBOTICS_INFRA_REVISION`, and these JSON inputs:

- `ROBOTICS_HOST_PLATFORM_FILE`: one object describing the host's actual OS,
  OS version, architecture and kernel. The foundation runner captures it on the host.
- `ROBOTICS_PROVIDER_BINDINGS_FILE`: one nonempty array of provider bindings, with
  the provider identity, capabilities and digests of retained qualification profiles
  and conformance results. The producer does not fabricate these observations.
- `ROBOTICS_EVALUATOR_BINDINGS_FILE`: an optional array for product evaluators.
  Without this file, the manifest has no product evaluator bindings.

Compose defaults the first two paths to `/run/robotics/configuration/host-platform.json`
and `/run/robotics/provider-bindings.json`, inside the mounted run directory. Qualification
must retain and validate the profile/result bytes named by the bindings; successful
manifest serialization alone does not establish provider conformance.

The container's platform comes from its own `/etc/os-release` and `uname`. The active
RMW version comes from `ros2 pkg xml <rmw> --tag version`, which respects the configured
ament search path and overlays. ROS domain IDs are decimal, including values with
leading zeros, and must satisfy the contracts range. Simulator-specific identity and
version belong in the provider binding, replacing the old fixed Gazebo fields.

Output is a validated `runtime-manifest.v1` document. Its execution subject uses an
OCI locator; middleware configuration is recorded under
`data_plane.middleware_configuration_sha256`. Temporary inputs and output are removed
on failure. A successful file is set to mode 0444 before atomic publication, so readers
never observe the writer's intermediate private file. Existing output survives validation
failure. Digests remain SHA-256 of the final file bytes.

The producer regression tests use the actual installed contracts CLI. They substitute
only OS and ROS package observations, and do not qualify live ROS or container images.
Full foundation qualification remains the integration gate for the migration branch.

The ROS command is provided by
[ros2pkg's XML verb](https://github.com/ros2/ros2cli/blob/jazzy/ros2pkg/ros2pkg/verb/xml.py).
