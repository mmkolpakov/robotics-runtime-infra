# Rclone runtime artifact

The evidence sink uses the official Alpine packages for rclone and musl. The
Dockerfile pins both signed APKs by SHA-256 for each supported architecture.
The supplier stage verifies their signatures with Alpine's keys and installs
them without network access. It retains the original APKs and package database
for the supplier image scan. The final image copies the executable and its
matching musl loader into an isolated directory, with a small CLI launcher.

The supported evidence profile uses rclone `copy`, `check`, and `version`.
Immutable uploads use directory `copy --immutable --checksum`. The versioned
S3 integration test checks that retries retain the original object version and
reject changed content. Supplier and final images must pass vulnerability scans.

The installed legacy evidence image uses the same supplier through Docker Bake.
For a local build, supply the existing finalizer image and the desired tag:

```sh
docker buildx bake --load \
  --set 'legacy-evidence-source.platform=linux/amd64' \
  --set 'legacy-evidence-source.args.EVIDENCE_BASE_IMAGE=<finalizer-image>' \
  --set 'legacy-evidence-source.tags=<evidence-image>' legacy-evidence-source
```

When updating the packages, update the per-architecture hashes in the Dockerfile
and rerun the supplier and final image scans and the versioned S3 integration test.
See the [Alpine package](https://pkgs.alpinelinux.org/package/edge/community/x86_64/rclone),
[rclone changelog](https://rclone.org/changelog/), and
[immutable option](https://rclone.org/docs/#immutable).
