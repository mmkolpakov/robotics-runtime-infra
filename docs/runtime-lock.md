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

The lock also sets `ROBOTICS_RUNTIME_MODE=released`. The resolved Compose model
records this mode, and `policy/release-images.rego` rejects any internal
`local/*:dev` fallback. Source mode remains the default only when no release
lock is supplied.

An unpublished target is absent from `release.env`. Its absence must not be
filled with a guessed digest, a mutable tag, or a digest copied from another
target. The target enters the lock only after its own OCI manifest has been
published and its registry digest is known.

## Updates

Every release produces a new lock from the declarative image inventory in
`config/ci/release-images.json` and the registry digests returned by BuildKit.
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
