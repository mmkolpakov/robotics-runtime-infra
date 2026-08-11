# Qualification bundles

Qualification bundles provide a portable, independently verifiable record of
one acceptance run. The producer creates an in-toto Statement v1. Signing and
certificate verification remain delegated to Cosign.

## Prerequisites

- Bash 5 or newer
- Cosign 3.1.2
- jq 1.6 or newer
- robotics-runtime-contracts 0.15.4 or newer (Python 3.12+ for local installs)

`ROBOTICS_CONTRACTS_CLI` may point to an executable from an isolated
installation. Otherwise, the scripts resolve `robotics-contracts` from `PATH`
or from the imported foundation environment.

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
  --evidence raw_mcap:control-0.mcap=artifacts/recording-control-0.mcap \
  --output artifacts/qualification.statement.json
```

Labels for runtime manifests, results, and evidence indexes must equal domain
identifiers from the acceptance run. Every domain must have exactly one of each.
MCAP summaries and retained `raw_mcap` files must exactly match the segments
referenced by the evidence indexes. Additional retained evidence can be
included with `--evidence KIND:LABEL=PATH`; supported kinds are printed by
`create-statement --help`.

Sign the complete in-toto Statement with the GitHub Actions identity:

```bash
cosign attest-blob \
  --statement artifacts/qualification.statement.json \
  --bundle artifacts/qualification.sigstore.json \
  --yes
```

The generated statement is deterministic for unchanged inputs. Its
`generated_at` value comes from the supplied `acceptance-aggregate.v4`; the
producer does not insert its own wall-clock timestamp. When cross-domain
causality is evaluated, `--transport-qualification` supplies the exact
`transport-qualification-result.v1` document referenced by the aggregate. The
document becomes a signed subject. An evaluated multi-domain package must also
include every domain's runtime, result, and evidence index, plus the exact
causal-chain contract, channel contract, and channel observation referenced by
the transport result:

```bash
--transport-qualification artifacts/transport-qualification.json \
--evidence causal_chain_contract:control-worker.json=artifacts/control-worker.json \
--evidence channel_contract:commands.json=artifacts/commands.json \
--evidence channel_observation:commands.json=artifacts/commands-observation.json
```

Omit all four arguments when the aggregate marks cross-domain evaluation as
`unevaluated`.

The foundation acceptance path also records
`config/fastdds/udp-only.xml` as `other_evidence`. The same file is mounted into
every ROS participant through `compose.foundation.yaml`, and
`runtime-manifest.json` must contain its SHA-256 digest. The signed statement
therefore binds the acceptance result to both the runtime manifest and the DDS
profile bytes that the runtime loaded.

## Independent policy

The verifier receives `qualification-policy.v2` separately from the signed
bundle. The policy defines:

- accepted GitHub Actions certificate identities;
- the GitHub Actions OIDC issuer;
- the SHA-256 digest of the pinned Sigstore trusted root;
- the required artifact classifications.

The repository pins the official Sigstore root in
`trust/qualification.trusted-root.json` and the exact official workflow
identity in `trust/qualification-policy.json`. Review and distribute these
files independently from a produced bundle. Copies uploaded beside a CI
artifact are transport copies, not new trust anchors.

Direct runs of `foundation-integration.yml` on the canonical `main` branch
produce a Rekor-backed keyless bundle. The job requires GitHub OIDC,
`id-token: write`, the exact issuer
`https://token.actions.githubusercontent.com`, and the exact identity:

```text
https://github.com/mmkolpakov/robotics-runtime-infra/.github/workflows/foundation-integration.yml@refs/heads/main
```

Pull requests and reusable foundation gates do not claim this trusted identity.
They use a temporary Cosign key, an offline signing configuration, and the real
Cosign verifier to test DSSE generation, signature verification, aggregate
digest binding, and tamper rejection. The temporary private key is deleted
before artifacts are uploaded. This key-backed bundle is integration evidence,
not a trusted release qualification. Its explicit-key verification uses
`--insecure-ignore-tlog` because the offline test deliberately does not publish
ephemeral PR attestations to the public transparency log; signature, key,
predicate type, aggregate digest, and complete statement equality are still
verified.

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
  --mcap-summary control-0=artifacts/mcap-summary-control-0.json \
  --evidence raw_mcap:control-0.mcap=artifacts/recording-control-0.mcap
```

Verification is ordered deliberately:

1. validate the independent policy and its trusted-root digest;
2. validate every supplied contract document through the
   `robotics-contracts` CLI, then reconstruct and validate the expected
   qualification Statement; a runtime-declared Fast DDS profile digest must
   match retained `other_evidence` bytes;
3. run `cosign verify-blob-attestation` for an identity allowed by the policy;
4. decode the authenticated DSSE payload from the Sigstore bundle;
5. require exact equality of subject names, local SHA-256 digests, artifact
   classifications, run identity, and generation timestamp.

The identity-policy path never uses `--insecure-ignore-tlog`. Its bundle must
carry the verification material required by the pinned trusted root.

An offline key-backed integration bundle is verified with an explicitly trusted
public key instead of an identity policy:

```bash
scripts/qualification/verify-bundle \
  --bundle artifacts/qualification.sigstore.json \
  --key artifacts/qualification.pub \
  --scenario artifacts/scenario.json \
  --runtime-manifest control=artifacts/runtime-control.json \
  --acceptance-run artifacts/acceptance-run.json \
  --result control=artifacts/result-control.json \
  --aggregate artifacts/acceptance-aggregate.json \
  --evidence-index control=artifacts/evidence-index-control.json \
  --mcap-summary control-0=artifacts/mcap-summary-control-0.json \
  --evidence raw_mcap:control-0.mcap=artifacts/recording-control-0.mcap
```

`--key` is mutually exclusive with `--trusted-root` and `--policy`; it cannot
be used to claim a GitHub Actions identity or public transparency-log
inclusion.

## Tests

Run the qualification contract and shell tests from Linux or WSL:

```bash
shellcheck scripts/qualification/* test/qualification/*.sh
bats test/qualification/qualification.bats
ROBOTICS_CONTRACTS_CLI=/path/to/robotics-contracts \
  bash test/qualification/real-cosign.sh
```

The Bats tests use a Cosign command double to exercise policy argument routing
without requesting an OIDC certificate. `real-cosign.sh` generates two real
Cosign key pairs and proves successful verification, wrong-key rejection, and
aggregate-digest tamper rejection. The foundation workflow additionally tests
the keyless path on canonical `main`.

These checks qualify the software foundation and its evidence chain. They do
not claim GPU, flight-controller, sensor, HIL, or other physical-hardware
qualification; those require the corresponding hardware workflow and retained
device evidence.

## Trusted-root maintenance

Update the root only in a reviewed change using the Cosign version pinned by
the repository:

```bash
cosign trusted-root create \
  --with-default-services \
  --out trust/qualification.trusted-root.json
sha256sum trust/qualification.trusted-root.json
```

Put the resulting digest into
`trust/qualification-policy.json`. Contract validation, the foundation Bats
tests, and the keyless job all fail closed when the two files differ. Root
rotation does not change the accepted issuer or workflow identity.

Domain extension schemas are supplied explicitly and digest-checked by the
contracts package:

```bash
scripts/qualification/create-statement \
  ... \
  --extension-schema \
  https://example.org/contracts/sorting.v1.schema.json=contracts/sorting.v1.schema.json
```
