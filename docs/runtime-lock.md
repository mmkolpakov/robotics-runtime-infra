# Runtime Image Lock

This repository has two explicit execution modes. They serve different
purposes and must not be mixed within one run.

## Source Mode

Source mode builds the current checkout and uses the `local/*:dev` image
defaults from the Compose files:

```bash
docker compose build simulation
docker compose up --detach --wait simulation
```

This mode is for development and validation of uncommitted or unreleased
changes. A local image is not a published release and carries no release
qualification claim.

## Released Mode

Released mode pulls immutable images listed in `release.env`:

```bash
gh release download v0.8.0-rc.1 \
  --repo mmkolpakov/robotics-runtime-infra \
  --pattern release.env
docker compose --env-file release.env pull simulation
docker compose --env-file release.env up --detach --no-build --wait simulation
```

`release.env` is the canonical lock for portable OCI images that have actually
been published. The release workflow generates it after all candidate images
pass and attaches it to the matching GitHub release; it is never edited in the
source tree. Every entry uses the form `tag@sha256:digest`. The tag keeps the
human-readable release version while the digest fixes the exact manifest
selected by the registry.

The lock also sets `ROBOTICS_RUNTIME_MODE=released` and records the exact
release source commit and tag ref. The resolved Compose model records the
runtime mode, and `policy/release-images.rego` rejects any internal
`local/*:dev` fallback. Source mode remains the default only when no release
lock is supplied.

Physical-attach tooling accepts a released `PERMIT_PREFLIGHT_IMAGE` only from
the canonical release repository at an OCI digest. In source mode, the
coordinator resolves the local tag once to its Docker image ID before Compose
is evaluated. The immutable identity is derived by the coordinator rather than
accepted as a second operator-supplied value.

Before a released verifier image is inspected or executed, the coordinator
uses `gh attestation verify` to require its GitHub artifact attestation from
the canonical release workflow, the source commit and tag recorded in
`release.env`, and a GitHub-hosted runner. The attestation is read from the OCI
registry and its verified digest is retained as run evidence. Released mode
therefore requires a GitHub token in `GH_TOKEN`; it never accepts the source
mode fallback. The Sigstore root used to authorize physical execution is
embedded read-only in the digest-pinned verifier image. It is not accepted from
the operator-supplied authorization directory.

An unpublished target is absent from `release.env`. Its absence must not be
filled with a guessed digest, a mutable tag, or a digest copied from another
target. The target enters the lock only after its own OCI manifest has been
published and its registry digest is known.

## Updates

Every release produces a new lock from the declarative image inventory in
the Bake `release` group, `config/ci/release-environment.json`, and the registry
digests returned by BuildKit.
Consumers update by downloading the lock attached to the selected release. A
source dependency updater cannot invent or modify released image records.

## Policy Check

`policy/release-images.rego` evaluates resolved Docker Compose JSON. It rejects
references in this repository's GHCR namespace unless they contain a complete
SHA-256 digest:

```bash
docker compose --env-file release.env config --format json |
  opa eval --stdin-input \
    --data policy/release-images.rego \
    --format pretty \
    'data.release_images.deny'
```

The policy intentionally accepts `local/*:dev` references used by source mode.
It does not replace image publication, signature verification, provenance
verification, or hardware qualification.

GitHub's command and provenance model are documented in
[the `gh attestation verify` manual](https://cli.github.com/manual/gh_attestation_verify)
and
[GitHub artifact attestation guidance](https://docs.github.com/en/actions/how-tos/secure-your-work/use-artifact-attestations/use-artifact-attestations).
