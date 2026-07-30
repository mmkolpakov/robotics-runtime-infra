# Vulnerability Applicability

All image scans consume the reviewed OpenVEX documents in this directory.
They record package-specific applicability decisions; they do not accept the
risk of an exploitable vulnerability.

`linux-libc-dev.openvex.json` covers findings that Ubuntu associates with the
`linux-libc-dev` binary package because it is built from the Linux kernel source
package. The binary package contains exported userspace API headers. It does not
contain the kernel implementations named by the listed advisories, and
containers execute the separately managed host kernel. The OpenVEX
justification is therefore `vulnerable_code_not_present`.

`grpc-go-cli.openvex.json` covers GHSA-hrxh-6v49-42gf only along the Cosign
3.1.1 and OPA dependency paths that are present in the permit preflight image.
The OPA root PURL has no version because the binary is reproducibly built from
the pinned v1.18.2 source revision rather than installed as a Go module. The
advisory affects xDS RBAC processing and the HTTP/2 gRPC server. Supported
image entrypoints use Cosign as a signing and verification client and OPA for
local formatting and policy evaluation; neither starts the affected server
code. The OpenVEX statements therefore use
`vulnerable_code_not_in_execute_path`.

The gRPC statements identify Cosign and OPA as products and `grpc-go` as their
subcomponent at the exact affected version. They deliberately do not declare
`grpc-go` itself as a product. The same advisory remains visible in any other
binary or service dependency path. Remove the statements when the pinned
upstream Cosign and OPA builds both contain `grpc-go` 1.82.1 or newer.

The Ubuntu package snapshot is updated before this applicability policy is
applied. New unsuppressed findings fail the build and require a fresh review.
The scanner emits remaining findings into SARIF for code scanning, then applies
the same VEX documents to the mandatory HIGH/CRITICAL release gate. The
reviewed OpenVEX documents are the version-controlled audit record for each
applicability decision.

Use `.trivyignore` only for a time-bounded risk acceptance with a review
reference and expiration date. Do not copy applicability decisions into that
file.

References:

- [Ubuntu package description](https://packages.ubuntu.com/noble-updates/linux-libc-dev)
- [CVE-2026-53175](https://nvd.nist.gov/vuln/detail/CVE-2026-53175)
- [GHSA-hrxh-6v49-42gf](https://github.com/advisories/GHSA-hrxh-6v49-42gf)
- [OpenVEX specification](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md)
- [Trivy local VEX files](https://trivy.dev/docs/v0.72/guide/supply-chain/vex/file/)
