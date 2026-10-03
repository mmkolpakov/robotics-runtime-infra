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

The scan retains the full JSON report and enforces HIGH/CRITICAL findings after
applicability filtering. New findings remain blocking until assessed. Raw scan
outputs belong in CI artifacts; local investigation notes do not belong in Git.
No vulnerability risk acceptance is recorded in `.trivyignore`.

References: [Ubuntu package](https://packages.ubuntu.com/noble-updates/linux-libc-dev),
[OpenVEX](https://github.com/openvex/spec/blob/main/OPENVEX-SPEC.md),
[Trivy VEX support](https://trivy.dev/docs/v0.74/guide/supply-chain/vex/file/),
[govulncheck](https://pkg.go.dev/golang.org/x/vuln/cmd/govulncheck).
