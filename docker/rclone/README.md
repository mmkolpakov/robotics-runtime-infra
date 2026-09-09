# Rclone dependency rebuild

The latest upstream release checked on 2026-09-09 is rclone v1.75.1, published
on 2026-09-04. Docker Bake binds that release tag to its peeled commit
`687d264b689b8c49a67e2e52a8a5e0caa01c04ce` in the `rclone-source` Git context.
The local `rclone-build` context supplies this directory independently of the
root build context's allowlist. Only upstream `go.mod` and `go.sum` are patched.

The official 1.75.1 image contained
`google.golang.org/grpc v1.84.0-dev.0.20260723093437-b6eac429d7b6`, reported as
HIGH CVE-2026-84445 in CI run 34298916450. The
[upstream advisory](https://github.com/grpc/grpc-go/security/advisories/GHSA-2v4p-qf9q-27wj)
identifies stable v1.83.2 as fixed. The master fix is commit
[`93e31b48545e2a8aaeb6e06b47fb249f94e6297f`](https://github.com/grpc/grpc-go/commit/93e31b48545e2a8aaeb6e06b47fb249f94e6297f),
published as `v1.85.0-dev.0.20260825072537-93e31b48545e`.

This rebuild selects stable gRPC v1.83.2. It deliberately moves gRPC from the
development snapshot to the patched stable branch. A plain `go get` of that
version also rolled back three transitively selected modules. The patch adds
explicit indirect requirements to preserve their original selected versions:

- `github.com/GoogleCloudPlatform/opentelemetry-operations-go/detectors/gcp v1.34.0`
- `github.com/spiffe/go-spiffe/v2 v2.8.1`
- `google.golang.org/genproto/googleapis/api v0.0.0-20260706201446-f0a921348800`

Among the original selected modules, only gRPC changes branch and `golang.org/x/net`
advances from v0.57.0 to v0.58.0, as required by fixed gRPC. No other existing module
is downgraded. Promoting the existing go-spiffe requirement also exposes its test
dependency `google.golang.org/grpc/examples v0.0.0-20250407062114-b368379ef8f6`
in the module graph; it is not part of the rclone executable. The master fix would
require broader Google API, authentication, OpenTelemetry and protobuf upgrades.

Regenerate the patch from the verified release checkout with Go 1.26.8:

```sh
export GOTOOLCHAIN=local GOMAXPROCS=4
go get google.golang.org/grpc@v1.83.2 \
  github.com/GoogleCloudPlatform/opentelemetry-operations-go/detectors/gcp@v1.34.0 \
  github.com/spiffe/go-spiffe/v2@v2.8.1 \
  google.golang.org/genproto/googleapis/api@v0.0.0-20260706201446-f0a921348800
go mod download
go mod verify
git diff -- go.mod go.sum
```

Compare `go list -m all` before and after regeneration, including transitively
selected versions. Retaining old checksum entries in `go.sum` does not link the
old dependencies. No `replace`, application changes or blanket dependency update
is used.

The builder uses the existing Go 1.26.8 image digest from `Dockerfile`, checks the
toolchain and release version, applies the patch, verifies the module cache and
fixed pins, builds with `-mod=readonly`, and rejects lock changes. It retains the
upstream default build tags and `CGO_ENABLED=0`, with a static binary for each
target architecture. `-trimpath`, an empty build ID and disabled automatic VCS
stamping keep local checkout paths and build times out of the executable.

The executable identifies itself as `v1.75.1+robotics.deps1`. The evidence-sink
image retains the source commit, modified-tree marker, deterministic build date,
patch and binary SHA-256, lock hashes, Go toolchain and linked module versions in
`/usr/share/robotics-runtime/rclone-build.txt`, and the upstream MIT license in
`/usr/share/licenses/rclone/COPYING`.

For local verification, `build.sh` accepts `RCLONE_SOURCE_DIR`,
`RCLONE_OUTPUT_DIR` and `RCLONE_DEPENDENCY_PATCH` directory/file overrides. It
requires an unpatched release checkout and the same `RCLONE_VERSION`,
`RCLONE_REVISION`, `TARGETOS` and `TARGETARCH` values supplied by Bake. Set
`GOMAXPROCS=4` in that process; compilation uses `go build -p 4`.

The existing real Linux S3 upload/check, evidence handoff, reproducibility and
HIGH/CRITICAL image scanning gates remain required. Local cross-compilation and
native tests do not replace them. No CVE exception or gate suppression is added.

Local Windows validation found a separate application behavior: a single-file
`copyto --immutable` overwrote a changed destination and returned success. A
directory `copy --immutable` control rejected the overwrite. The unchanged
release's `operations.CopyFile` path does not use the sync worker's immutable
rejection check. The ordinary copy/check and corrupted-file detection probes
passed, but the single-file immutable probe remains a failed check. Verify this
behavior on Linux/S3; this dependency-only rebuild does not correct it.

Replace this temporary rebuild when an upstream release contains the fixes;
Renovate tracks its release tag and source commit together. Each update must
regenerate or remove the patch and pass the same gates.
