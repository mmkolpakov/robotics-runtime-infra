# Vulnerability Applicability

All image scans consume the reviewed OpenVEX document in this directory. It
records package-specific applicability decisions; it does not accept the risk
of an exploitable vulnerability.

`linux-libc-dev.openvex.json` covers findings that Ubuntu associates with the
`linux-libc-dev` binary package because it is built from the Linux kernel source
package. The binary package contains exported userspace API headers. It does not
contain the kernel implementations named by the listed advisories, and
containers execute the separately managed host kernel. The OpenVEX
justification is therefore `vulnerable_code_not_present`.

The Ubuntu package snapshot is updated before this applicability policy is
applied. New unsuppressed findings fail the build and require a fresh review.
The scanner emits remaining findings into SARIF for code scanning, then applies
the same VEX document to the mandatory HIGH/CRITICAL release gate. The reviewed
OpenVEX document is the version-controlled audit record for each applicability
decision.

Use `.trivyignore` only for a time-bounded risk acceptance with a review
reference and expiration date. Do not copy applicability decisions into that
file.

References:

- [Ubuntu package description](https://packages.ubuntu.com/noble-updates/linux-libc-dev)
- [CVE-2026-53175](https://nvd.nist.gov/vuln/detail/CVE-2026-53175)
- [CVE-2026-64531](https://nvd.nist.gov/vuln/detail/CVE-2026-64531)
- [OpenVEX specification](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md)
- [Trivy local VEX files](https://trivy.dev/docs/v0.72/guide/supply-chain/vex/file/)
