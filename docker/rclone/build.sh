#!/usr/bin/env bash
set -Eeuo pipefail

: "${RCLONE_VERSION:?RCLONE_VERSION is required}"
: "${RCLONE_REVISION:?RCLONE_REVISION is required}"
: "${TARGETOS:?TARGETOS is required}"
: "${TARGETARCH:?TARGETARCH is required}"
[[ "${RCLONE_VERSION}" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ "${RCLONE_REVISION}" =~ ^[a-f0-9]{40}$ ]]

# Directory overrides allow the same build to be checked without a Docker daemon.
source_dir="${RCLONE_SOURCE_DIR:-/src/rclone}"
output_dir="${RCLONE_OUTPUT_DIR:-/out}"
dependency_patch="${RCLONE_DEPENDENCY_PATCH:-/tmp/rclone-go-dependencies.patch}"
export GOTOOLCHAIN=local
export GOFLAGS=-mod=readonly
test "$(go env GOVERSION)" = go1.26.8

cd "${source_dir}"
test "$(tr -d '\r' < VERSION)" = "v${RCLONE_VERSION}"
git apply --check "${dependency_patch}"
git apply "${dependency_patch}"
mkdir -p "${output_dir}"
sha256sum go.mod go.sum > "${output_dir}/rclone-module-locks.sha256"
go mod download
go mod verify
test "$(go list -m -f '{{.Version}}' google.golang.org/grpc)" = v1.83.2
test "$(go list -m -f '{{.Version}}' golang.org/x/net)" = v0.58.0

build_version="v${RCLONE_VERSION}+robotics.deps1"
ldflags="-s -w -buildid= -X github.com/rclone/rclone/fs.Version=${build_version}"
CGO_ENABLED=0 GOOS="${TARGETOS}" GOARCH="${TARGETARCH}" \
  go build -p 4 -trimpath -buildvcs=false -ldflags "${ldflags}" \
    -o "${output_dir}/rclone" .
sha256sum --check "${output_dir}/rclone-module-locks.sha256"
install -m 0444 COPYING "${output_dir}/COPYING"
{
  printf 'source=https://github.com/rclone/rclone\nrevision=%s\nversion=%s\n' \
    "${RCLONE_REVISION}" "${build_version}"
  printf 'tree_state=dirty\nbuild_date=1970-01-01T00:00:00Z\n'
  printf 'dependency_patch_sha256=%s\n' \
    "$(sha256sum "${dependency_patch}" | cut -d ' ' -f 1)"
  printf 'binary_sha256=%s\n' \
    "$(sha256sum "${output_dir}/rclone" | cut -d ' ' -f 1)"
  cat "${output_dir}/rclone-module-locks.sha256"
  go version -m "${output_dir}/rclone"
} > "${output_dir}/rclone-build.txt"
