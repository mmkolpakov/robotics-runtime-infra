# Compatibility Policy

## Supported Basis

The runtime basis is Ubuntu 24.04, ROS 2 Jazzy, and Gazebo Harmonic. Exact APT
snapshots, Python locks, base-image digests, and imported repository revisions
are build inputs. `release.env` is the OCI execution lock.

Support applies to a source revision, an image digest, a named Compose profile,
and a declared target. A successful image build does not qualify hardware.

## Public Surfaces

The public surfaces are:

- published OCI image names and entry points;
- Compose service, profile, environment, volume, and network names documented
  in `README.md`;
- files under `/usr/share/robotics-runtime/`;
- ROS packages installed by the simulation and edge images;
- the `/simulator` ROS 2 `simulation_interfaces` service boundary and `/clock`;
- reusable workflows documented in `README.md`, when called by exact commit SHA;
- machine-readable documents defined by `robotics-runtime-contracts`.

Files under `test/`, implementation stages in `Dockerfile`, and local image
tags are not stable APIs.

## Change Rules

- Patch releases may fix implementation and security defects without changing
  a public document or Compose contract.
- Minor releases may add optional profiles, services, document versions, and
  image targets. Existing released profiles continue to resolve.
- Removing or changing a documented service, environment variable, ROS
  interface, or artifact meaning requires a major release.
- A runtime-contract schema is immutable after release. A semantic change
  receives a new schema version and an explicit migration path.
- The Jazzy/Harmonic basis remains fixed for this major line. A ROS
  distribution or simulator family change starts a new major compatibility
  line and repeats qualification.

## Consumers

Consumers inherit released images by digest, retain
`/usr/share/robotics-runtime/foundation.repos`, and keep product code in their
own image and Compose overlay. Consumer CI validates its scenario and runtime
manifest against the exact contracts revision recorded in the image.

Accelerator, HIL, and real-observation support remains
qualification-gated until the named host produces retained evidence.
