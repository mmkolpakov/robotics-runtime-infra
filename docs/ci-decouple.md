# CI gates

CI separates source checks, conditional image builds and scans of published
images. The workflow files define the triggers and commands; repository branch
protection selects the required checks.

| Workflow | Triggers | Responsibility |
| --- | --- | --- |
| `ci-domain` | PR, main, merge group, manual, reusable | Source, consumer, Compose and deployment-tool checks |
| `ci-supply-chain` | PR, main, merge group, manual, reusable | Conditional image build, vulnerability scan and foundation qualification |
| `security-gate` | Nightly, main, manual | Scan published immutable images and report findings |
| `release-images` | `v*` tag | Require fresh gates, build candidates, attest and promote immutable images |

## Source checks

`ci-domain` runs static analysis, consumer examples, Compose validation,
Terraform, Helm and Ansible checks. Its tooling builds do not install packages
from the Ubuntu snapshot mirror. Helm and Ansible tooling use the pinned
`ros:jazzy-ros-base` image; the policy engine uses pinned OPA and Go builder
images.

## Conditional image qualification

`ci-supply-chain` builds and scans the image matrix when image inputs change.
The `changes` job compares the diff with `config/ci/image-inputs.txt`. Regenerate
and check that manifest after changing a build input:

```bash
scripts/ci/supply-chain/image-inputs.sh list > config/ci/image-inputs.txt
scripts/ci/supply-chain/image-inputs.sh check
```

The generator reads `docker-bake.hcl`, its named contexts and the COPY/ADD
sources of referenced Dockerfiles. Fixed inputs also cover Docker configuration,
security policy, supplier/source locks and the consumer examples exercised by
foundation qualification. `test/ci/supply-chain-decouple.bats` fails when the
committed manifest differs from the derived list.

The aggregate accepts skipped image jobs only when `changes` succeeded and
reported `affected == "false"`. Affected inputs require every image job to
succeed. A forced run, a new-branch push or an unavailable diff requires the
full build. A failed classifier fails the aggregate.

The conditional `foundation` job runs source import, contracts and image-lock
checks, installed-host consumption, versioned S3 evidence, live ROS graph,
acceptance isolation, edge attach and neutral-robot digest rejection.
`foundation-integration.yml` also runs on main, a weekly schedule, manual
dispatch and reusable calls. Its canonical-main keyless qualification and
independent-consumer jobs have separate identity requirements; see
[qualification verification](qualification.md#independent-policy).

Build and scan commands use `scripts/ci/supply-chain/run-guarded.sh`.
A snapshot-mirror 5xx failure exits 75 (`EX_TEMPFAIL`) and records
`upstream unavailable`. This is a failed check; retry after the supplier
recovers. It does not waive the build or scan.

## Published-image security

`security-gate` runs daily at 03:17 UTC, after pushes to main and on demand.
It downloads the published release lock and digest records, then scans every
selected digest with Trivy and the reviewed OpenVEX statements. It does not
rebuild the images or accept mutable tags.

A failed scan opens or updates one tracking issue. The report requests triage
within one business day and replacement digests or a reviewed VEX statement for
HIGH/CRITICAL findings within seven calendar days. The issue remains open until
the gate is green. Follow [SECURITY.md](../SECURITY.md) for vulnerability
disclosure; do not publish exploit details in tracking issues.

## Releases and repository protection

`release-image.yml` invokes the domain gate, the supply-chain gate with
`force: true`, and foundation integration. A tag therefore requires fresh
qualification regardless of changed paths before candidate publication,
attestation and promotion.

Configure branch protection to require the aggregate `ci-domain` and
`ci-supply-chain` checks from the GitHub Actions app, up-to-date branches and
resolved conversations. Enforce protection for administrators and disallow force
pushes and branch deletion. Workflow declarations do not configure protection or
reviewer approvals. A `merge_group` trigger permits queue integration when
the repository account supports it.

Skipped images in an unaffected PR do not establish the full matrix's health.
Release admission, hardware qualification and independently trusted provenance
remain separate from a green source check. [Runtime image locks](runtime-lock.md)
define the identities used by each execution mode.
