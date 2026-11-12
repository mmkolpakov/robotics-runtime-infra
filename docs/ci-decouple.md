# CI decoupling: domain gate, supply-chain gate, published-image security gate

Status: proposal. The workflow split in this change is complete; branch protection and the
merge queue are owner actions and are deliberately not applied here.

## Problem

The single required `ci` check coupled every merge to a full image rebuild. A Canonical
snapshot-mirror outage (5xx from `snapshot.ubuntu.com`) therefore blocked unrelated domain
pull requests, and the only escape was a manual rebase against a moving `main`.

## Gate architecture

| Workflow | Triggers | Required | apt | Failure semantics |
| --- | --- | --- | --- | --- |
| `ci-domain` | PR, push to main, merge queue, manual, reusable | yes | no | any job red → gate red |
| `ci-supply-chain` | PR, push to main, merge queue, manual, reusable | yes | image builds only | fail-closed; mirror 5xx → exit 75 |
| `security-gate` | nightly, push to main, manual | no | no | red → SLA issue |
| `release-images` | tag `v*` | n/a | image builds only | requires fresh green gates |

`ci-domain` runs static analysis, consumer examples, Compose validation, Terraform, Helm and
Ansible checks. The Helm and Ansible tooling images build from the published
`ros:jazzy-ros-base` digest (Ubuntu 24.04, python3 and ca-certificates included) instead of
apt-installing from the snapshot mirror, so the domain gate never touches apt. The policy
engine builds from scratch plus the pinned OPA and Go builder digests.

`ci-supply-chain` runs the full image build and Trivy scan with the reviewed OpenVEX policy
only when image inputs are affected.

## Conditional supply-chain execution

The `changes` job classifies the diff against `config/ci/image-inputs.txt`. The manifest is
derived, not hand-maintained:

```bash
scripts/ci/supply-chain/image-inputs.sh list > config/ci/image-inputs.txt
scripts/ci/supply-chain/image-inputs.sh check
```

Derivation reads `docker-bake.hcl`: every named bake context (local paths such as
`host/.tools/host-asset`; remote git pins are covered by watching the bake file itself) and
every COPY/ADD build-context source of each referenced Dockerfile. Fixed inputs add
`docker/*`, `security/*`, `.trivyignore`, `trivy.yaml`, `.dockerignore` and the supplier pins
`config/foundation-lock.json`, `config/ros-cohort-source.lock.json`, `foundation.repos`,
`host/source-lock.json`. `test/ci/supply-chain-decouple.bats` regenerates the list and fails
when the committed manifest drifts, so a new COPY source cannot silently escape the gate.

Decision rules:

- Not affected → every image job is skipped and the aggregate reports a deterministic
  `not affected` success.
- Affected → full build and scan; every image job must succeed.
- Diff unavailable, new branch push, or `force` input → full build (fail-closed).
- A failed `changes` job fails the aggregate; a skip is accepted only when
  `affected == "false"`.

Build and scan steps run through `scripts/ci/supply-chain/run-guarded.sh`. When a failing
step shows the Ubuntu or ROS snapshot mirror returning 5xx, the wrapper exits 75
(`EX_TEMPFAIL`) and records `upstream unavailable` in the step summary. 75 is a failure
classification for diagnostics, never a success; rerun once the mirror recovers.

## Security gate outside pull requests

`security-gate` runs nightly (03:17 UTC), after every merge to `main`, and on demand. It
downloads the latest published release lock (`release.env` plus the digest records) and
scans every published digest with Trivy and the reviewed OpenVEX statements. It never
rebuilds an image and never accepts a mutable tag.

A red gate opens (or comments on) one tracking issue. Proposed SLA, for owner confirmation:
triage within one business day; for HIGH/CRITICAL findings publish replacement digests or a
reviewed VEX statement within seven calendar days; the issue stays open until the gate is
green again. Reporting stays consistent with `SECURITY.md` (no exploit details in public
issues).

## Release

`release-image.yml` now calls `ci-domain` and `ci-supply-chain` with `force: true`, so a tag
always requires a fresh green build and scan regardless of changed paths. Candidate build,
scan, attestation and immutable promotion are unchanged.

## Branch-protection proposal (owner action)

Replace the legacy `ci` context with the two aggregate job names and enable the merge queue
instead of strict up-to-date branches plus manual rebases. The queue builds each entry
against the latest `main`; both workflows carry the `merge_group` trigger, and the queue
merge commit diff (`HEAD~1..HEAD`) feeds the same classification.

Recommended payload (reconcile with the existing review policy before applying):

```json
{
  "required_status_checks": {
    "strict": false,
    "checks": [
      {"context": "ci-domain"},
      {"context": "ci-supply-chain"}
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {
    "required_approving_review_count": 1,
    "require_code_owner_reviews": true
  },
  "restrictions": null,
  "required_linear_history": false,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "required_conversation_resolution": true
}
```

```bash
gh api -X PUT repos/mmkolpakov/robotics-runtime-infra/branches/main/protection \
  --input protection.json
```

Merge queue (repository settings → Pull Requests → enable merge queue, or a ruleset with a
`merge_queue` rule): proposed parameters `max_entries_to_build: 5`,
`max_entries_to_merge: 5`, `min_entries_to_merge: 1`,
`min_entries_to_merge_wait_minutes: 5`, `check_response_timeout_minutes: 60`, merging
strategy `MERGE` to preserve the current history convention.

Migration order:

1. Merge this branch; wait for `ci-domain` and `ci-supply-chain` to run on `main`.
2. Apply the protection payload (removes the legacy `ci` context).
3. Enable the merge queue; keep `strict: false`.
4. Verify the first queue entry produces both required checks and merges without a manual
   rebase.

## Risks

- Path-filter gap: a new COPY source makes the manifest stale; the bats freshness test turns
  that into a red domain gate until the manifest is regenerated (fail-closed). Inputs outside
  bake contexts (runner tools, domain fixtures, examples) are always exercised by the
  always-required domain gate. The generated host asset is watched through
  `host/source-lock.json`; `.dockerignore` is watched explicitly.
- Fail-open temptation: skipped image jobs count as success only when `affected == "false"`;
  exit 75 is a failure; releases force the full gate; the security gate opens an issue instead
  of waiving findings. Do not add `continue-on-error` or broaden the skip condition.
- Published-scan platforms come from the current bake release group; the release gate itself
  verifies every candidate platform at publication time.
