# Minimal Runtime Consumer

This source example qualifies a stepped simulation and a declared UInt64 topic,
retaining original ROS recordings, telemetry, logs, JSON/JUnit results and a signed
qualification statement. The caller's standalone Compose file contains only
caller-owned services; foundation services remain in pinned tooling.

Add this job to the consumer's workflow. Replace both placeholders with the same
full 40-character infra commit. This reusable workflow runs source mode.

```yaml
jobs:
  qualify:
    uses: mmkolpakov/robotics-runtime-infra/.github/workflows/reusable-qualify.yml@<infra-commit>
    with:
      tooling_ref: <infra-commit>
      scenario: examples/minimal-consumer/scenario.yaml
      compose_project: examples/minimal-consumer/compose.yaml
      artifact_arguments_file: examples/minimal-consumer/artifact-arguments.txt
```

The UInt64 topic `/example/sequence` is configured in `scenario.yaml`: its expected graph and
evidence topic references must agree. Publisher, metrics subscriber and recorder
use this same snapshot.
The recorder selects exactly `evidence_policy.topics`. The stock profile supports
one declared UInt64 topic; older caller scenarios without one retain the stock probe.

`artifact_arguments_file` is optional and defaults to an empty string. The format
is one argument per line: `--artifact` followed by `KIND:SUBJECT=PATH`, or
`--extension-schema` followed by `URI=PATH`. Paths resolve relative to the caller
repository and must stay inside it, including symlink targets. Other flags and
missing values are rejected. The public contracts tool validates roles, links,
digests and duplicate subjects. This example binds its README as original evidence.

Trigger the caller workflow, then download its artifact into a new directory:

```bash
gh workflow run qualify.yml --ref <consumer-ref>
gh run download <run-id> --repo <consumer-owner/repository> \
  --name qualification-<consumer-commit> --dir downloaded
```

Use the same pinned tooling checkout and installed contracts CLI to verify the
copied package. The argument file supplies paths for this new directory; do not
rewrite any JSON, recording, statement or Sigstore bundle.

```bash
tooling="$(realpath path/to/pinned/robotics-runtime-infra)"
export ROBOTICS_CONTRACTS_CLI="${tooling}/dependencies/robotics-runtime/.venv/bin/robotics-contracts"
cd downloaded/qualification
mapfile -t arguments < qualification-arguments.txt
"${tooling}/scripts/qualification/verify-bundle" \
  "${arguments[@]}" \
  --bundle qualification.sigstore.json --key qualification.pub
```

Source smoke uses an ephemeral key. The included key establishes integrity under
that key; it does not establish trusted producer identity. Trusted verification
supplies an independently selected public key, or a pinned qualification policy
and Sigstore trusted root, after the portable arguments. Bundle and trust flags
come last so the downloaded argument file cannot select them. The canonical
main-branch keyless gate remains a separate trust boundary. Cleanup diagnostics
are separate from signed log snapshots.

Released image-lock execution is pending N03. This example currently builds and
qualifies the exact source tooling revision.
