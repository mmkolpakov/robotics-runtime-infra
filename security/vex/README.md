# Vulnerability Applicability

All image scans consume the reviewed OpenVEX document in this directory. It
records package-specific applicability decisions; it does not accept the risk
of an exploitable vulnerability.

`linux-libc-dev.openvex.json` covers findings that Ubuntu associates with the
`linux-libc-dev` binary package because it is built from the Linux kernel source
package. The binary package contains exported userspace API headers. It does not
contain the vulnerable implementations identified in the individual reviews, and
containers execute the separately managed host kernel. The OpenVEX
justification is therefore `vulnerable_code_not_present`.

The Ubuntu package snapshot is updated before this applicability policy is
applied. New unsuppressed findings fail the build and require a fresh review.
The scanner emits remaining findings into SARIF for code scanning, then applies
the same VEX document to the mandatory HIGH/CRITICAL release gate. The reviewed
OpenVEX document is the version-controlled audit record for each applicability
decision.

The [2026-09-08 review](linux-libc-dev-2026-09-08.md) maps each of the 135 new
HIGH/CRITICAL findings to primary CVE records, implementation paths and the
actual amd64/arm64 package contents. Six findings have Ubuntu fixes in
`6.8.0-139.139` and receive no new VEX statement. Version 4 adds 129 individual
statements restricted to that exact package version, **amd64** and Ubuntu
24.04, matching the actual residual in [CI run 34192891669](https://github.com/mmkolpakov/robotics-runtime-infra/actions/runs/34192891669/job/101954401272).
The [captured comparison](linux-libc-dev-2026-09-08.ci.json) records the report
hash, PR merge revision, signed APT build evidence and all 129 residual CVEs.
The existing 55 statements remain unchanged. The policy version, reviewed
statement scope and correspondence with the actual residual are checked in
`test/ci/security-scanning.bats`.

The pins landed as `a2f62d3`; CI built PR merge `5336df5` and installed `.139`
from snapshot `20260908T000000Z`. All six fixed CVEs disappeared; the remaining
124 HIGH and five CRITICAL CVEs exactly match the new statements. They do not
match the old `.136` package or arm64. The arm64 payload review is retained,
but new arm64 statements require a rebuilt residual scan. The NVIDIA image
still contains OpenSSL `.11` (no HIGH/CRITICAL findings in this report); the
`.15` pin belongs to the separate `ubuntu-ca` stage. No OpenSSL exemption is
added. CI must rerun the existing scanner and gate with this VEX version;
neither the whole NVIDIA image group nor CI is qualified by this comparison.

The review distinguishes kernel implementations from the separately packaged
`perf` userspace tool, processor errata, and an exported-path header change
guarded by `__KERNEL__`. It qualifies only the named header package, never the
running kernel, host processor, or other binaries in the image.

Use `.trivyignore` only for a time-bounded risk acceptance with a review
reference and expiration date. Do not copy applicability decisions into that
file.

References:

- [Ubuntu package description](https://packages.ubuntu.com/noble-updates/linux-libc-dev)
- [CVE-2026-53175](https://nvd.nist.gov/vuln/detail/CVE-2026-53175)
- [CVE-2026-64531](https://nvd.nist.gov/vuln/detail/CVE-2026-64531)
- [OpenVEX specification](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md)
- [Trivy local VEX files](https://trivy.dev/docs/v0.72/guide/supply-chain/vex/file/)
