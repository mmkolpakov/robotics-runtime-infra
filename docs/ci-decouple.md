# CI decoupling: domain gate, supply-chain gate, published-image security gate

Status: adopted. The workflow split and the foundation-qualification fold are complete. The
branch-protection switch below is the owner action applied together with this change.

## Problem

The single required `ci` check coupled every merge to a full image rebuild. A Canonical
snapshot-mirror outage (5xx from `snapshot.ubuntu.com`) therefore blocked unrelated domain
pull requests, and the only escape was a manual rebase against a moving `main`.

## Gate architecture

| Workflow | Triggers | Required | apt | Failure semantics |
| --- | --- | --- | --- | --- |
| `ci-domain` | PR, push to main, merge_group, manual, reusable | yes | no | any job red → gate red |
| `ci-supply-chain` | PR, push to main, merge_group, manual, reusable | yes | image builds only | fail-closed; mirror 5xx → exit 75 |
| `security-gate` | nightly, push to main, manual | no | no | red → SLA issue |
| `release-images` | tag `v*` | n/a | image builds only | requires fresh green gates |

`ci-domain` runs static analysis, consumer examples, Compose validation, Terraform, Helm and
Ansible checks. The Helm and Ansible tooling images build from the published
`ros:jazzy-ros-base` digest (Ubuntu 24.04, python3 and ca-certificates included) instead of
apt-installing from the snapshot mirror, so the domain gate never touches apt. The policy
engine builds from scratch plus the pinned OPA and Go builder digests.

`ci-supply-chain` runs the full image build and Trivy scan with the reviewed OpenVEX policy
only when image inputs are affected.

The foundation qualification suite runs inside `ci-supply-chain` as the conditional
`foundation` job: pinned-source import, contract validation, image-lock verification, the
installed-host consumer, versioned S3 evidence, the real-ROS-graph scenario, acceptance
isolation, edge attach and the neutral-robot digest rejection. `foundation-integration.yml`
keeps its push-to-main, weekly schedule and `workflow_call` triggers for the post-merge
keyless qualification chain and the release foundation gate, and no longer runs on pull
requests. Folding the suite into the conditional gate preserves its coverage for image
changes without re-coupling domain pull requests to the mirror.

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
`docker/*`, `security/*`, `.trivyignore`, `trivy.yaml`, `.dockerignore`, the supplier pins
`config/foundation-lock.json`, `config/ros-cohort-source.lock.json`, `foundation.repos`,
`host/source-lock.json`, and the consumer projects the foundation qualification runs against
(`examples/minimal-consumer/*`, `examples/neutral-robot/*`).
`test/ci/supply-chain-decouple.bats` regenerates the list and fails when the committed
manifest drifts, so a new COPY source cannot silently escape the gate.

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

## Branch protection (owner action)

Replace the legacy `ci` and `foundation` contexts with the two aggregate job names, pinned to
the GitHub Actions app so only that app can report them. Keep `strict: true` so the
image-input classification always runs against the current `main`.

This repository lives on a personal account, so a merge queue is not available; branches are
kept up to date by hand (rebase or update-branch) instead. Both workflows still carry the
`merge_group` trigger so a queue can be enabled later if the repository moves to an
organization.

There is a single owner, who cannot approve their own pull request, so the review count is
zero while the pull-request requirement, conversation resolution and `enforce_admins` stay
on. Add a second reviewer before treating this as a production gate.

```json
{
  "required_status_checks": {
    "strict": true,
    "checks": [
      {"context": "ci-domain", "app_id": 15368},
      {"context": "ci-supply-chain", "app_id": 15368}
    ]
  },
  "enforce_admins": true,
  "required_pull_request_reviews": {"required_approving_review_count": 0},
  "required_conversation_resolution": true,
  "allow_force_pushes": false,
  "allow_deletions": false,
  "restrictions": null
}
```

```bash
gh api -X PUT repos/mmkolpakov/robotics-runtime-infra/branches/main/protection \
  --input protection.json
```

Migration order:

1. Confirm `ci-domain` and `ci-supply-chain` are green on this pull request.
2. Apply the protection payload. The legacy `ci` and `foundation` contexts no longer report
   on this pull request (`ci.yml` is removed and `foundation-integration.yml` no longer
   triggers on pull requests), so the switch must precede the merge.
3. Merge this branch; both required checks then run on `main`.
4. Rebase the open pull requests onto `main` so they pick up the new workflows.

Deferred hardening, not blockers: enable `required_signatures` once branch commits are
signed, and add a `v*` tag-protection ruleset so a tag cannot bypass the release gate.

## Risks

- Path-filter gap: a new COPY source makes the manifest stale; the bats freshness test turns
  that into a red domain gate until the manifest is regenerated (fail-closed). Inputs outside
  bake contexts (runner tools, domain fixtures) are always exercised by the always-required
  domain gate; the consumer projects the foundation qualification runs against are watched as
  fixed inputs. The generated host asset is watched through `host/source-lock.json`;
  `.dockerignore` is watched explicitly.
- Fail-open temptation: skipped image jobs count as success only when `affected == "false"`;
  exit 75 is a failure; releases force the full gate; the security gate opens an issue instead
  of waiving findings. Do not add `continue-on-error` or broaden the skip condition.
- Published-scan platforms come from the current bake release group; the release gate itself
  verifies every candidate platform at publication time.
