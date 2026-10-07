# Qualification baseline for architecture C

Architecture C is the selected target: public Python contracts and harness,
a Cordis host, and separate simulator providers. These are implementation
requirements, not a qualification of the combined stack. The retained ROS v1
provider remains Ubuntu 24.04 / ROS 2 Jazzy / Gazebo Harmonic. A native provider
has its own environment and capability gates; it does not create a ROS graph to
satisfy this legacy profile.

## Distinct identities and claims

The current source line pins published contracts 0.19.0 and harness 0.20.0;
`config/foundation-lock.json` records the exact runtime workspace and package
trees. Its images use source-built wheels from those released package trees.
The package payloads and distribution metadata match the published wheels;
the contracts wheel archive has a different reproducible ZIP timestamp.
The current dataset role is `dataset-manifest.v2`: one complete native bag
with retained metadata and ordered MCAP/summary references, for one or more
members. Full live playback qualification requires a passing attempt for this
cohort.

The published R9 release,
`v0.9.0-rc.1`, passed its stock UInt64 simulation and independent consumer gates
with contracts 0.18.1 / harness 0.19.0. This result is scoped to that profile.

R10, `v0.10.0-rc.1`, was published from image-source commit
`d6dc8a1c6b976faacab7b371821e9af54b9883c2` using contracts 0.18.2 / harness
0.19.1. The unchanged release lock has SHA-256
`21a0e760cdbb3d0ede362b96ad5a79b58ea44bbe201aeb1d47a3fe66204b129f`.
Successful publication and provenance checks do not qualify a later caller.

The retained B3 released attempt is [run
37157837270](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/37157837270),
attempt 1, on caller commit `63c33dd4a3cb1091876fbe38b0310c7bd942a5c9`.
Its reusable workflow and tooling checkout both use
`9944f0cc6ffd7fe16e14192f85887a06be59435a`. Its images retain the R10
source and lock above. These caller, tooling and image-source identities are
separate inputs.

## Open B3 gates

This attempt **failed**. The native entity gates passed: model absent before
creation, acknowledged missing-file request rejected by actual server state,
and positive model observed through native `GetEntities`. An acknowledgement
alone does not satisfy any entity gate.

The retained stepper diagnostic reports Clock `16133000000` ns where
`16026000000` ns was required, an overshoot of `107000000` ns. The foreground
JointState readiness command then reached its shared 90-second outer deadline
with exit 124 and an empty qualifying output. TF observation was not reached.
A nonzero Clock sample of 16.133 s establishes a sample, not continuing clock
advancement or correct time ownership.

Observer evaluation, live acceptance JUnit, signed qualification production,
portable readmission and the independent published consumer did not complete;
the independent consumer job was skipped. The historical grouped log alone does not establish exact
wall ordering.
A subsequent [bounded native diagnostic](b3-startup-cause.md) reproduces the
initialization/clock-owner race and passes the ordered counterpart; full B3
acceptance and the published consumer remain open.
The earlier apparently green run 37152524765 lacks the required entity proof
and is not a substitute for B3 acceptance.

## Retained raw evidence and trust

The failed run's native artifact `qualification-63c33dd4a3cb1091876fbe38b0310c7bd942a5c9`
contains 35 regular files. Its ZIP is 60,898 bytes with SHA-256
`e69b1aa92927c3cbd4aafe8ceecac74a2aa5aa65e641689976eacdb687d03179`.
The retained raw closure manifest has SHA-256
`4627e6bdf20bde3a62bb24a02da091477702ada0abbd77c8a2c5feb8580936665`.
The files and archive remain unchanged in the review evidence store; a new
attempt must have a new identity and must preserve these failed observations.

Source checks, image attestations, exact package-byte verification and live
qualification answer different questions. An included ephemeral signing key
proves package integrity under that key, not trusted producer identity. R10
provenance does not imply B3 passed. No Clock, JointState, TF, wrong-digest,
JUnit or portable-consumer gate is waived by the C migration.

## Selecting a new released attempt

Dispatch `qualify-released-runtime` at the caller commit with an explicit
`release_tag`. The reusable workflow comes from that same caller commit.
`tooling_ref` accepts a full commit SHA and defaults to the dispatch commit;
the qualification and independent consumer jobs check out that exact tooling
identity. The independent job uses the consumer action from that tooling
checkout and installs the published pair declared by its foundation lock.

The wrapper downloads the selected tag's canonical `release.env` into a new
directory within the caller checkout. Existing external callers may still
supply their own canonical lock path to `reusable-qualify.yml`. The release
and asset verification, image digests and source attestations are checked
before image references are admitted. A new dispatch preserves the old B3
failure and records a new artifact under its caller SHA.

Image publication remains scoped to the complete target set in
`config/ci/release-environment.json` and each target's declared platforms.
A passing reusable qualification run establishes the selected neutral robot
scenario on its Ubuntu 24.04 AMD64 runner. Other providers, hardware and
platforms require
their own retained qualification; publishing an image does not establish
those results.
