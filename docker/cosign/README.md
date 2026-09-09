# Cosign runtime artifact

The runtime copies Cosign from the publisher-signed Chainguard image pinned by
`COSIGN_IMAGE` in `docker-bake.hcl`. CI verifies its signature with the exact
Chainguard workflow identity and the GitHub OIDC issuer before accepting an update.
The image digest is recorded in execution verification as `cosign_subject_digest`.
It identifies the source OCI image, not a locally rebuilt executable.

Local dependency patches and downstream Cosign builds are not used. Updates must
pass publisher verification, the real signature and tamper tests, and vulnerability
applicability checks. A valid publisher signature does not imply absence of CVEs.

See [Chainguard signature verification](https://edu.chainguard.dev/chainguard/containers/security-and-compliance/verifying-chainguard-images-and-metadata-signatures-with-cosign/).
