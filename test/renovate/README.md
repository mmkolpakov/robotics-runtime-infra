# Renovate pin updates

CI runs `check-pins.mjs` with the Renovate package from the pinned `RENOVATE_IMAGE`,
where the package is installed in `/usr/local/renovate`. To run it locally with the same
Renovate version:

```sh
docker run --rm --volume "${PWD}:/work:ro" --workdir /work "${RENOVATE_IMAGE}" \
  node test/renovate/check-pins.mjs /usr/local/renovate
```

The test uses local API fixtures and temporary output files. It does not create remote PRs.
`stable.repos` contains synthetic release data for this test, not an adoptable foundation pin.

## Foundation releases

`foundation.repos` is the input; the compatibility lock, dependency files and Bake source
are generated. After a compatible contracts/harness pair has been published, add its
`harness-vX.Y.Z` tag as `repositories.robotics-runtime.release`, placed before `version`,
and pin the tag's full commit in `version`. Renovate updates these two fields together
from published GitHub releases. A development pin without `release` is not tracked.

Before merging a foundation update, verify the release/tag commit and published package
compatibility, then run:

```sh
bash scripts/ci/foundation/import-sources.sh --refresh-pins
```

Include the generated changes in the PR and pass the required CI and foundation
qualification. Renovate does not run this generator; generated-file drift fails CI until
the inputs are refreshed.

## Cosign

The Bake `COSIGN_IMAGE` digest and `COSIGN_VERSION` are tracked separately and grouped for
review. Image tags do not prove the binary version: the publisher verification step and the
image builds' binary-version checks remain mandatory. Rclone image updates use the native
Dockerfile manager.
