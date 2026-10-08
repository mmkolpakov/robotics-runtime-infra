# Qualification reference

Qualification binds exact package, image, caller, tooling, workload and
platform identities. Installation, source integration and image publication
establish different claims.

## Published profile

[`v0.11.0-rc2`](https://github.com/mmkolpakov/robotics-runtime-infra/releases/tag/v0.11.0-rc2)
contains contracts 0.19.0 and harness 0.20.0 from workspace
`efeac712ea512b19523ce41be40752f703fa782b`.
Its image-source commit is `51cd10baaa82745ec1ff59b12ad3f77c4e507e38`;
the unchanged release lock has SHA-256
`d92dd0db44400db321d7dc28c1c4e1f26681a6b3c2c55aad4202173e21b8c427`.
The release inventory and each target's declared platforms define the published
asset set. Provenance and platform verification do not qualify device execution.

[Released qualification 37740199071](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/37740199071)
uses caller ref `v0.11.0-rc2` and exact tooling
`95cbb8e21e4132f07252e2d8dc1c2c421a472c25` on Ubuntu 24.04 AMD64 with Docker.
It verifies the neutral robot's native entity presence, missing-file rejection,
Clock, JointState and TF, live acceptance and a signed retained package.
A separate consumer installs the published package pair, verifies the original
bytes and readmits the robot without the producer snapshot.

The same run verifies natural EOF of the stock rosbag2 player with a single
Int32 MCAP bag. Native process exit, observed time, retained input bytes and
cleanup are distinct checks. The dataset contract supports ordered bag members;
this single-bag result does not qualify every message type, large multi-member
live playback, another middleware or another backend.

Rootless Podman, native GPU providers, physical hardware, HIL and AWS/EKS
execution require their own environment and operation evidence. A source
Docker success does not establish these scopes.

## Input identity and trust

The caller owns its scenario and workload. Its ref selects the workflow
declaration. `tooling_ref` selects a full reviewed infra implementation checkout
and the consumer action. These identities may differ from each other and from
the image-source commit. The immutable tag and canonical `release.env` bind
image digests and their source attestations independently.

Released admission verifies release assets and image provenance before starting
services. It rejects source-image fallbacks, wrong digests and substituted
inputs. Retained subjects include the original robot description, runtime and
acceptance documents, recording metadata, ordered MCAP references and native
observations. Verification after producer removal uses those retained bytes.

An included ephemeral signing key proves integrity under that key. Trusted
producer identity requires an independently selected signing policy and root.
Neither image provenance nor a package signature is safety certification.
Failed or incomplete attempts retain their original diagnostics and are never
relabelled successful by a later passing run.

## Selecting a profile

Choose the release tag, exact tooling commit, scenario and declared environment
through `qualify-released-runtime`. Admission, native execution, retained export
and independent consumption must all pass for the same attempt. Unsupported
capabilities and missing evidence are errors, not inferred defaults.

[Image locks](runtime-lock.md) describes source/released selection;
[qualification](qualification.md) defines package production and verification.
