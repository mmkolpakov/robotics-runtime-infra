# Qualification bundles

Qualification bundles provide a portable, independently verifiable record of
one acceptance run. The producer creates an in-toto Statement v1. Signing and
certificate verification remain delegated to Cosign.

## Prerequisites

- Bash 5 or newer
- Cosign 3.1.3
- jq 1.6 or newer
- The exact contracts workspace revision in `foundation.repos` (Python 3.12+)

This integration branch uses the v1 generation and the contracts statement writer
and matcher. Install its pinned workspace; the earlier 0.15.4 / 0.17.1 foundation
pair cannot read these artifacts. The full foundation migration and release gates
remain part of the [coordinated migration](compatibility.md#foundation-generations).

`ROBOTICS_CONTRACTS_CLI` may point to an executable from an isolated
installation. Otherwise, the scripts resolve `robotics-contracts` from `PATH`
or from the imported foundation environment.

Cosign 3.1.3 is the minimum security baseline for
[GHSA-fx35-mq7g-6g98](https://github.com/sigstore/cosign/security/advisories/GHSA-fx35-mq7g-6g98),
which affects legacy JSON bundle verification through 3.1.2. The
[current upstream release](https://github.com/sigstore/cosign/releases/tag/v3.1.3)
was checked on 2026-09-07. CI pins the CLI version; `docker-bake.hcl` pins the
multi-platform Chainguard image digest and the same version. Update both
together: the preflight image build checks the embedded binary version.

## Produce and sign

Create a deterministic statement through `robotics-contracts qualification statement`:

```bash
scripts/qualification/create-statement \
  --scenario artifacts/scenario.json \
  --runtime-manifest control=artifacts/runtime-control.json \
  --acceptance-run artifacts/acceptance-run.json \
  --result control=artifacts/result-control.json \
  --aggregate artifacts/acceptance-aggregate.json \
  --evidence-index control=artifacts/evidence-index-control.json \
  --recording-summary control-0=artifacts/recording-summary-control-0.json \
  --evidence recording:control-0.mcap=artifacts/recording-control-0.mcap \
  --output artifacts/qualification.statement.json
```

Labels for runtime manifests, results, and evidence indexes must equal domain
identifiers from the acceptance run. Every domain must have exactly one of each.
Recording summaries and retained `recording` files must exactly match the artifacts
referenced by the evidence indexes. Additional retained evidence can be
included with `--evidence KIND:LABEL=PATH`. Native contracts arguments
`--artifact KIND:SUBJECT=PATH` preserve arbitrary canonical subject labels and
may replace or supplement the named options. The example above illustrates
labels; supply the complete inventory required by your run, including every
provider profile, configuration, conformance result, clock relation and receipt
dependency. Contracts rejects missing or duplicate subjects and broken links.

Sign the complete in-toto Statement with the GitHub Actions identity:

```bash
cosign attest-blob \
  --statement artifacts/qualification.statement.json \
  --bundle artifacts/qualification.sigstore.json \
  --yes
```

The generated statement is deterministic for unchanged inputs. Its
`generated_at` value comes from the supplied `acceptance-aggregate.v1`; the
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
--evidence channel_observation:commands-observation.json=artifacts/commands-observation.json \
--evidence clock_relation:control-worker-clock.json=artifacts/control-worker-clock.json
```

Omit these transport arguments when the aggregate marks cross-domain evaluation as
`unevaluated`.

The foundation acceptance path also records
`config/fastdds/udp-only.xml` as `other_evidence`. The same file is mounted into
every ROS participant through `compose.foundation.yaml`, and
`runtime-manifest.json` must contain its SHA-256 digest. The signed statement
therefore binds the acceptance result to both the runtime manifest and the DDS
profile bytes that the runtime loaded.

## Independent policy

The verifier receives `qualification-policy.v1` separately from the signed
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
  --recording-summary control-0=artifacts/recording-summary-control-0.json \
  --evidence recording:control-0.mcap=artifacts/recording-control-0.mcap
```

Verification is ordered deliberately:

1. take private copies of the bundle, independent policy and trusted root (or
   explicit public key); validate the policy and its trusted-root digest;
2. validate every supplied contract document through the
   `robotics-contracts` CLI, then reconstruct and validate the expected
   qualification Statement; a runtime-declared Fast DDS profile digest must
   match retained `other_evidence` bytes;
3. run `cosign verify-blob-attestation` for an identity allowed by the policy;
4. decode the authenticated DSSE payload from the same private bundle copy;
5. use `robotics-contracts validate-qualification --statement` to revalidate the
   local artifact set and match names, byte digests, classifications, run identity
   and generation timestamp. This uses the contracts JSON profile; whitespace
   and object-key order do not matter, and signed bytes are never rewritten.

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
  --recording-summary control-0=artifacts/recording-summary-control-0.json \
  --evidence recording:control-0.mcap=artifacts/recording-control-0.mcap
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

The adapter tests in `test/ci/qualification-v1.bats` use complete v1 inventories
from the pinned contracts workspace and an explicitly labelled verifier double.
`test/qualification/real-cosign.sh` exercises actual offline Cosign signing,
verification, foreign-key rejection and changed aggregate bytes against infra's
own v1 transport inventory. These checks do not claim live ROS/provider/S3
qualification; infra-produced v1 fixtures and foundation E2E are separate gates.
