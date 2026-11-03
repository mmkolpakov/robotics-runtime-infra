# Vulnerability applicability

Image scans use `linux-libc-dev.openvex.json` to distinguish exported Ubuntu
kernel headers from the host kernel implementations associated with their
source package. Its existing statements apply only to the components named
in the policy. They do not qualify the host kernel, hardware or other binaries.

`go-modules.openvex.json` covers dependencies of the published Cosign and rclone
binaries. Each statement names the exact binary module version as the product
and the exact dependency version as its subcomponent, so an image or dependency
update makes the statement inapplicable. A statement records the call-graph
evidence (`govulncheck` source and binary modes) and is removed once the
publisher ships a fixed dependency.

The scan retains the JSON report, including native suppressed-finding records
with their original finding, source and rationale, and enforces HIGH/CRITICAL findings after
applicability filtering. New findings remain blocking until assessed. Raw scan
outputs belong in CI artifacts; local investigation notes do not belong in Git.
No vulnerability risk acceptance is recorded in `.trivyignore`.

References: [Ubuntu package](https://packages.ubuntu.com/noble-updates/linux-libc-dev),
[OpenVEX](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md),
[Trivy VEX support](https://trivy.dev/docs/v0.75/guide/supply-chain/vex/file/),
[govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck).

## Canonical Ubuntu identity projection

Canonical's OpenVEX uses `distro=noble`; Trivy identifies the same distribution
as `distro=ubuntu-24.04`. The optional preparation helper translates this one
qualifier for an observed Ubuntu 24.04 noble `linux-libc-dev` package. It uses
the stock PackageURL parser and preserves the full version, architecture,
namespace and every other qualifier; a subpath is unsupported. A missing or ambiguous exact
supplier binding fails preparation. Other distributions are unsupported.

The approved source pin is [canonical-source.json](canonical-source.json).
It currently contains two unchanged Canonical records, CVE-2026-63825 and
CVE-2026-72399, at commit
`f904483357e84d1836895448ed579c7aa1bede4f`. Their header-package declarations
cover version `6.8.0-147.147`, including amd64 and arm64. They do not cover
`6.8.0-142.142` or every finding associated with the Linux source package.
The existing project VEX is not rewritten or extended to version 147.

Given a trusted Canonical Git checkout in `CANONICAL_SOURCE_REPO`, materialize
the pinned originals with stock Git. The helper verifies each reviewed hash:

```bash
raw=artifacts/security/canonical-raw
mkdir -p "$raw"
revision="$(jq -r .source_commit security/vex/canonical-source.json)"
while IFS= read -r name; do
  git -C "$CANONICAL_SOURCE_REPO" show \
    "${revision}:vex/cve/${name:4:4}/${name}" >"$raw/$name"
done < <(jq -r '.files[].name' security/vex/canonical-source.json)
uv venv artifacts/security-tools
uv pip install --python artifacts/security-tools/bin/python \
  --require-hashes --no-deps -r scripts/ci/security/requirements.lock
```

Retain an unfiltered Trivy JSON report with package inventory and the
`os-release` bytes from the same immutable image and platform. These are
observations from the image producer, not user-supplied claims about an image.
Use its exact package PURL; the following example prepares the amd64 binding:

```bash
artifacts/security-tools/bin/python scripts/ci/security/prepare-ubuntu-vex.py \
  --vendor-dir artifacts/security/canonical-raw \
  --source-commit "$revision" \
  --scan-report artifacts/security/candidate-unfiltered.json \
  --os-release artifacts/security/candidate-os-release \
  --package-purl 'pkg:deb/ubuntu/linux-libc-dev@6.8.0-147.147?arch=amd64&distro=ubuntu-24.04' \
  --output-dir artifacts/security/canonical-amd64
ROBOTICS_CI_VENDOR_VEX_DIR="$PWD/artifacts/security/canonical-amd64" \
  scripts/ci/security/scan-image.sh "$IMAGE" candidate linux/amd64
```

The output contains the unchanged raw supplier bytes, a derived OpenVEX document
authored by the project maintainer, provenance and standard SHA256SUMS. The provenance binds the
reviewed source commit and hashes, observed report and OS bytes, exact PURL pair,
tool identity and derived document hash. The derived author is the project
maintainer; it does not inherit Canonical authorship or a supplier signature.
Statement status, justification, impact and timestamps remain supplier data.
Stock Trivy makes the applicability decision and retains suppressed findings.

The optional directory must remain under the retained security artifact
directory. The wrapper checks its files before scanning and mounts it read-only.
SHA256SUMS checks consistency of trusted prepared input; it does not authenticate
the preparer or replace verification of the image and supplier source.
An unset option preserves the existing scan path. All scans retain package
inventory and suppressed findings; HIGH/CRITICAL conversion remains unchanged.
A successful synthetic identity test does not admit an image.

Supplier and corresponding final-image gates can explicitly set
`ROBOTICS_CI_TRIVY_DETECTION_PRIORITY=comprehensive`. This passes the stock
Trivy flag so that Go binaries owned by an OS package are also analyzed against
upstream advisories. Other explicit values fail before scanning; an unset
option preserves Trivy's default. Reports retain findings at every severity;
the existing HIGH/CRITICAL gate remains unchanged.

For further findings, use the stock Trivy report to identify the affected
binary package and retrieve the corresponding unchanged files from a reviewed
Canonical Git snapshot. Hashes can be generated with stock Git and sha256sum;
the approved input pin must cover the exact records being prepared. Missing
supplier records or package bindings are not converted into exceptions.
Unmatched findings remain blocking. This two-record integration does not
claim automatic ingestion or resolution of all Ubuntu advisories.

Sources: [Canonical VEX](https://documentation.ubuntu.com/security/security-updates/vex/),
[Trivy 0.76.1 file support](https://github.com/aquasecurity/trivy/blob/v0.76.1/docs/guide/supply-chain/vex/file.md),
[PackageURL](https://github.com/package-url/packageurl-python).
