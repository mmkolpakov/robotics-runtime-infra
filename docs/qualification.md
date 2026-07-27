# Qualification bundles

Qualification bundles provide a portable, independently verifiable record of
one acceptance run. The producer creates an in-toto Statement v1. Signing and
certificate verification remain delegated to Cosign.

## Prerequisites

- Bash 5 or newer
- Cosign 3.1.1
- jq 1.6 or newer
- yq 4.53 or newer
- check-jsonschema 0.37 or newer
- robotics-runtime-contracts 0.8.0

`ROBOTICS_CONTRACT_SCHEMA_DIR` may point to an unpacked contracts schema
directory. Otherwise, the scripts resolve schemas from the installed
`robotics-runtime-contracts` package.

## Produce and sign

Create the canonical statement:

```bash
scripts/qualification/create-statement \
  --scenario artifacts/scenario.json \
  --runtime-manifest control=artifacts/runtime-control.json \
  --acceptance-run artifacts/acceptance-run.json \
  --result control=artifacts/result-control.json \
  --aggregate artifacts/acceptance-aggregate.json \
  --evidence-index control=artifacts/evidence-index-control.json \
  --mcap-summary control-0=artifacts/mcap-summary-control-0.json \
  --output artifacts/qualification.statement.json
```

Labels for runtime manifests, results, and evidence indexes must equal domain
identifiers from the acceptance run. Every domain must have exactly one of each.
MCAP summaries must exactly match the summaries referenced by the evidence
indexes. Additional retained evidence can be included with
`--evidence KIND:LABEL=PATH`.

Sign the complete in-toto Statement with the GitHub Actions identity:

```bash
cosign attest-blob \
  --statement artifacts/qualification.statement.json \
  --bundle artifacts/qualification.sigstore.json \
  --yes
```

The generated statement is deterministic for unchanged inputs. Its
`generated_at` value comes from `acceptance-aggregate.v2`; the producer does not
insert its own wall-clock timestamp.

## Independent policy

The verifier receives `qualification-policy.v1` separately from the signed
bundle. The policy defines:

- accepted GitHub Actions certificate identities;
- the GitHub Actions OIDC issuer;
- the SHA-256 digest of the pinned Sigstore trusted root;
- the required artifact classifications.

Do not distribute the policy from the workflow that produces the qualification
bundle. Store and review it with the verifier configuration.

The production verifier requires a Rekor-backed keyless bundle and never
disables transparency-log verification. The `authorize-offline-test` path uses
a local key pair and `--insecure-ignore-tlog` only for the isolated CI
cryptography and tamper-rejection test; its signing configuration explicitly
disables Rekor, and its output cannot satisfy the production authorization
path.

## Verify

The external verifier uses the same local artifact arguments as the producer:

```bash
scripts/qualification/verify-bundle \
  --bundle artifacts/qualification.sigstore.json \
  --trusted-root trust/qualification.trusted-root.json \
  --policy trust/qualification-policy.json \
  --scenario artifacts/scenario.json \
  --runtime-manifest control=artifacts/runtime-control.json \
  --acceptance-run artifacts/acceptance-run.json \
  --result control=artifacts/result-control.json \
  --aggregate artifacts/acceptance-aggregate.json \
  --evidence-index control=artifacts/evidence-index-control.json \
  --mcap-summary control-0=artifacts/mcap-summary-control-0.json
```

Verification is ordered deliberately:

1. validate the independent policy and its trusted-root digest;
2. reconstruct and validate the expected qualification Statement;
3. run `cosign verify-blob-attestation` for an identity allowed by the policy;
4. decode the authenticated DSSE payload from the Sigstore bundle;
5. require exact equality of subject names, local SHA-256 digests, artifact
   classifications, run identity, and generation timestamp.

The verifier never uses `--insecure-ignore-tlog`. A bundle must carry the
verification material required by the pinned trusted root.

## Tests

Run the qualification contract and shell tests from Linux or WSL:

```bash
shellcheck scripts/qualification/* test/qualification/qualification.bats
bats test/qualification/qualification.bats
```

The Bats tests use a Cosign command double to exercise policy argument routing
without requesting an OIDC certificate. Production verification always invokes
the real `cosign verify-blob-attestation`; cryptographic positive testing
requires a genuine keyless bundle and trusted root.
