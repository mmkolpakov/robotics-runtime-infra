# Renovate pin updates

CI runs `check-pins.mjs` with the Renovate package from the pinned `RENOVATE_IMAGE`.
To run it locally with the same installed package version:

```sh
node test/renovate/check-pins.mjs /path/to/node_modules/renovate
```

The test uses local API fixtures and temporary output files. It does not create remote PRs.
`stable.repos` contains synthetic release data for this test, not an adoptable foundation pin.

## Foundation releases

`foundation.repos` is the input; the compatibility lock, dependency files and Bake source are generated.
After a compatible contracts/harness pair has been published, add its `harness-vX.Y.Z` tag as
`repositories.robotics-runtime.release` and pin the tag's full commit in `version`.
Renovate updates these two fields together from published GitHub releases.
A development pin without `release` intentionally remains pending stable adoption.

Before merging a foundation update, verify the release/tag commit and published package compatibility,
then run:

```sh
bash scripts/ci/foundation/import-sources.sh --refresh-pins
```

Include the generated changes in the PR and pass the required CI and foundation qualification.
The hosted app is not assumed to have permission to run this generator; generated-file drift must
continue to fail CI until it is refreshed. A passing fixture test does not close the actual Renovate
PR or stable-adoption gates.

## Cosign

The Bake `COSIGN_IMAGE` digest and `COSIGN_VERSION` are tracked separately and grouped for review.
Image tags do not prove the binary version: the publisher verification step and the image builds'
binary-version checks remain mandatory. Rclone image updates use the native Dockerfile manager.
