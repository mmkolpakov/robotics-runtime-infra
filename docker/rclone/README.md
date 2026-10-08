# Rclone runtime artifact

The evidence sink copies the unchanged executable from the official rclone image
pinned by `RCLONE_IMAGE` in `Dockerfile`. No local Go module patch is applied.
The MIT license is retained separately from the pinned upstream source.

Immutable uploads use directory `copy --immutable --checksum`. Single-file
`copyto --immutable` does not enforce the same overwrite check. The versioned S3
integration test verifies that retries keep the original object version and reject
changed content. The released image must pass that behavior test and vulnerability
applicability checks before a pin update is accepted.

See the [rclone changelog](https://rclone.org/changelog/) and
[immutable option](https://rclone.org/docs/#immutable).
