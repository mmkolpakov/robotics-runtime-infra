# Cosign dependency rebuild

Runtime images build the verified Cosign v3.1.3 release commit
`11926fa5bbbbde47e88fc006b625a17769b743b2`. Docker Bake binds the release tag
and commit in one Git source context. The checked-in patch changes only
`go.mod` and `go.sum`; no Cosign application code is changed.

The upstream release and current Chainguard image contain affected Go modules:

- [GO-2026-6303](https://pkg.go.dev/vuln/GO-2026-6303) requires
  `golang.org/x/crypto v0.55.0`.
- [GO-2026-6180](https://pkg.go.dev/vuln/GO-2026-6180) and
  [GO-2026-6179](https://pkg.go.dev/vuln/GO-2026-6179) require
  `golang.org/x/mod v0.40.0`. Their sumdb fixes also require a fixed build
  toolchain; the builder is the digest-pinned Go 1.26.8 image.
- [GHSA-hrxh-6v49-42gf](https://github.com/grpc/grpc-go/security/advisories/GHSA-hrxh-6v49-42gf)
  and [CVE-2026-84304](https://github.com/grpc/grpc-go/security/advisories/GHSA-vp52-pcj8-j9qc)
  require `google.golang.org/grpc v1.83.1`. The subsequent
  [CVE-2026-84445](https://github.com/grpc/grpc-go/security/advisories/GHSA-2v4p-qf9q-27wj)
  requires v1.83.2, which is the pinned version.

The patch was generated from the release's module locks with Go 1.26.8:

```sh
go get golang.org/x/crypto@v0.55.0 golang.org/x/mod@v0.40.0 google.golang.org/grpc@v1.83.2
go mod verify
git diff -- go.mod go.sum
```

Go's minimum-version selection also updates x/net, x/sync, x/sys, x/term,
x/text and x/tools. Their exact versions and checksums are retained in the
patch. The build verifies the module cache and fixed dependency versions,
compiles with `-mod=readonly`, and rejects any changes to the patched locks.

The binary identifies itself as `v3.1.3+robotics.deps3` with a modified source
tree. It is not an unmodified upstream release artifact. Each runtime image
retains the release commit, patch SHA-256 and linked Go module versions in
`/usr/share/robotics-runtime/cosign-build.txt`, plus the upstream license.
Build timestamps are fixed for reproducibility.

Execution verification keeps the base `cosign_version` and records the
SHA-256 of the actual executable bytes in `cosign_subject_digest`. This is a
binary subject, not an OCI image digest. The patched build is distinguished
by these exact bytes and the retained build metadata. Preflight hashes the
resolved executable; its policy rejects a missing or malformed digest.

The existing real-signature, DSSE tamper, evidence handoff, reproducibility
and HIGH/CRITICAL vulnerability gates remain required. No new CVE exception
is added. Hosted fixture setup still uses the official v3.1.3 installer;
container signing and verification exercise this dependency rebuild.

Replace the patch with an upstream release once it contains these fixes.
Renovate tracks the release version and source commit together. A proposed
update must regenerate or remove the patch and pass the same gates.
