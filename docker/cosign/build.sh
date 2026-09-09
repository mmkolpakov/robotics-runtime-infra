#!/usr/bin/env bash
set -Eeuo pipefail

: "${COSIGN_VERSION:?COSIGN_VERSION is required}"
: "${COSIGN_REVISION:?COSIGN_REVISION is required}"
: "${TARGETOS:?TARGETOS is required}"
: "${TARGETARCH:?TARGETARCH is required}"
[[ "${COSIGN_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "${COSIGN_REVISION}" =~ ^[a-f0-9]{40}$ ]]

cd /src/cosign
git apply --check /tmp/cosign-go-dependencies.patch
git apply /tmp/cosign-go-dependencies.patch
sha256sum go.mod go.sum > /tmp/cosign-module-locks.sha256
export GOTOOLCHAIN=local
export GOFLAGS=-mod=readonly
go mod download
go mod verify
test "$(go list -m -f '{{.Version}}' golang.org/x/crypto)" = v0.55.0
test "$(go list -m -f '{{.Version}}' golang.org/x/mod)" = v0.40.0

build_version="v${COSIGN_VERSION}+robotics.deps1"
version_package=sigs.k8s.io/release-utils/version
ldflags="-buildid= -X ${version_package}.gitVersion=${build_version}"
ldflags+=" -X ${version_package}.gitCommit=${COSIGN_REVISION}"
ldflags+=" -X ${version_package}.gitTreeState=dirty"
ldflags+=" -X ${version_package}.buildDate=1970-01-01T00:00:00Z"
mkdir -p /out
CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
  go build -trimpath -buildvcs=false -ldflags "${ldflags}" -o /out/cosign ./cmd/cosign
sha256sum --check /tmp/cosign-module-locks.sha256
{
  printf 'source=https://github.com/sigstore/cosign\nrevision=%s\nversion=%s\n' \
    "${COSIGN_REVISION}" "${build_version}"
  printf 'dependency_patch_sha256=%s\n' \
    "$(sha256sum /tmp/cosign-go-dependencies.patch | cut -d ' ' -f 1)"
  go version -m /out/cosign
} > /out/cosign-build.txt
