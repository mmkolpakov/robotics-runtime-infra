# OPA release verification

On 2026-09-09, the latest official release was
[OPA v1.20.2](https://github.com/open-policy-agent/opa/releases/tag/v1.20.2),
published on 2026-09-03. Its released binaries contain the fixed dependencies needed for the
11 HIGH/CRITICAL findings in `/usr/local/bin/opa` from CI run 34305345505: eight in the Go
standard library, two in gRPC and one in `golang.org/x/crypto`.

`Dockerfile` selects the upstream `1.20.2-static` image by its multi-platform index digest.
The existing `opa` stage supplies `policy-tooling`, `permit-preflight` and `permit-preflight-ci`.
None of their Bake targets overrides `OPA_IMAGE`, so no Bake change or local OPA build is needed.
Renovate retains the existing Dockerfile image tracking with a minimum OPA version of 1.20.2.
Its [version compatibility rule](https://docs.renovatebot.com/configuration-options/#versioncompatibility)
separates the numeric version from `-static` before applying the SemVer minimum,
then retains the static variant in updates. A plain SemVer range on the full tag
would incorrectly reject future static tags as prereleases.

## Release identity

The official release tag resolves to source commit:

```text
b2c26708e9d55645d7f837db495031f7e4152594
```

The license URL is pinned to that commit. Its unchanged SHA-256 is:

```text
c6596eb7be8581c18be736c846fb9173b69eccf6ef94c5135893ec56bd92ba08
```

The image index and platform manifests inspected from Docker Hub are:

```text
index:       sha256:bb245e9e36be0d0ed486c240b606c56be7aba96014a4a87895fed4ba7a6dfa8d
linux/amd64: sha256:9c5770a0023d56a11224b0514fec2e4e0247357db4392b955c1270fd49cb1f0f
linux/arm64: sha256:f82ea9bcbdbd73776b2f8c3faf75771534d85ed096626809e0234d34621b3bbe
```

Both platform manifests, configs and layers were downloaded through the registry API with each
object checked against its descriptor digest. `/opa` was extracted from each image's layer and
inspected with `go version -m`; these are the image binaries, not the standalone release assets.
Their SHA-256 values are:

```text
linux/amd64 /opa: e2daf61b9ab6a478ae46b4110d84e74441bd566d0b20e3abd86729becb02e8d2
linux/arm64 /opa: e4405751ead28107e412ccd2f4d1e005e5a909099b374618b55fba18ef02be2b
```

Relevant actual module/build information is identical in both binaries, except for `GOARCH`:

```text
go1.27.1
mod   github.com/open-policy-agent/opa v1.20.2+dirty
dep   golang.org/x/crypto              v0.55.0
dep   golang.org/x/net                 v0.58.0
dep   google.golang.org/grpc           v1.83.2
build CGO_ENABLED=0
build GOOS=linux
build vcs.revision=b2c26708e9d55645d7f837db495031f7e4152594
build vcs.time=2026-09-03T20:35:14Z
build vcs.modified=true
```

`GOARCH` is `amd64` and `arm64` respectively. The `+dirty` version and modified-tree marker are
already present in the official upstream binaries. This repository copies them unchanged.
The linked versions cover the supplied SARIF's fixed-version requirements; that comparison is
not a fresh vulnerability scan.

## Original ARM64 scanner evidence

All seven completed `portable-arm64/*.sarif` reports from CI run 34305345505 were inspected.
`multiarch-permit-preflight-linux-arm64.sarif` contains exactly the same 11 HIGH/CRITICAL records
as `cpu-permit-preflight-local.sarif`: CVE ID, package, installed version, fixed versions and path
all match. Every finding points to `usr/local/bin/opa`.

The acceptance-observer, benchmark, edge, evidence-sink, host-io-fixture and inference-cpu ARM64
reports each contain zero HIGH/CRITICAL findings. These reports describe the original images;
the updated OPA image pin still requires a fresh scan on both architectures.

## Local validation

Policy execution used the official `opa_windows_amd64.exe` release asset, verified against the
SHA-256 published by the official GitHub release API:

```text
e2f2e2b735ab98f316171ca47a6b352288cdeb5a616e31aa16335b8934748453
```

It reports OPA 1.20.2, Go 1.27.1 and the same source revision and dependency versions above.
From the repository root, the commands used by
`scripts/ci/static-analysis/verify-policy-format-and-tests.sh` passed on that native binary:

```sh
opa fmt --list --fail policy
opa test policy test/policy/execution --fail-on-empty
```

Result: **66/66 policy tests passed**. Another **18 policy probes passed**, using the inputs and
queries from the existing scenario, workflow, Compose, host I/O, physical-runtime and execution
CI scripts with the native OPA executable in place of their Docker wrapper:

- Four scenario fixtures: stepped smoke and Zenoh were allowed; unsafe Compose and mock physical
  verdict fixtures produced the expected nine and three denials.
- Two hardware workflow fixtures: hardware qualification and RK3588 were allowed.
- Ten rendered Compose configurations: default, high-throughput, observability, edge attach,
  HIL, real observation, real observation test, serial preflight, time and CAN were allowed.
- Two execution probes: the valid fixture was allowed and a permit lifetime limit of 1801 seconds
  was denied, with `time.now_ns` fixed to the fixture's reference time, 2026-07-14T12:00:00Z.

These probes exercise the OPA decisions; they do not represent full execution of the surrounding
CI scripts or their contract-validation steps.

ShellCheck 0.11.0 passed for the existing Cosign/rclone build scripts, permit-preflight entrypoints,
CI library and nine relevant static-analysis scripts. Hadolint 2.14.0 passed the repository's
error threshold, with three existing warnings in unrelated Dockerfile instructions.

`docker buildx bake --file docker-bake.hcl --list=type=targets,format=json` listed 33 targets.
`--print` succeeded for all of them and the `release`, `cpu` and `ci-only` groups. The group checks
from `validate-docker-bake-definition.sh` passed: release and CPU include production preflight
and exclude CI preflight; `ci-only` contains only CI preflight. Policy tooling and production
preflight retain both Linux architectures; CI preflight retains Linux AMD64.

The Docker daemon was unavailable. A `bake --check policy-tooling` attempt was interrupted while
waiting for it; no successful build check is claimed. Container builds, Linux execution on AMD64
and ARM64, and fresh HIGH/CRITICAL scans of the resulting images remain required CI validation.
The local checks do not change the VEX policy or waive any scanner findings.
