# Qualification regression inputs

These synthetic observations exercise schema validation, cross-document links
and the qualification adapter. They are not records of live ROS, provider or
transport qualification. Provider conformance messages and the example image
identity explicitly mark their fixture status.

`single-artifacts.json` and `transport-artifacts.json` list the complete local
inventories with contracts `kind`, `subject_name` and relative `file` values.
The first has one domain; the second has two distinct ROS domain identities,
channel and clock observations, and retained bridge configuration. Both include
the provider profile, configuration, conformance result and middleware profile.
Changing one input requires updating every dependent raw-byte digest.
Fixture JSON uses a terminating newline for repository text checks; digests
include that byte. Runtime producers retain their own documented JSON profile.

`recording-0.mcap` preserves the repository's golden playback recording bytes.
`recording-summary.json` comes from the public contracts MCAP reader, including
CRC and actual-record checks. The small OTLP files and claimed graph/verdict
values are regression data; the fixture validator does not independently
recompute telemetry or execute a simulator.

Run `bats test/qualification/qualification.bats` with the pinned
`ROBOTICS_CONTRACTS_CLI` to check valid inventories and specific rejection paths.
`test/qualification/real-cosign.sh` additionally uses actual ephemeral keys to
sign and verify the transport inventory. Main-branch foundation runs produce
their own measured artifacts and use the independently pinned identity policy.
