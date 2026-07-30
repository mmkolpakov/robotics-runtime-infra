.runtime_id = "ci.physical-attach-runtime" |
.oci_image.reference = $image_reference |
.oci_image.digest = $image_digest |
.components.contracts_revision = $contracts_revision |
.components.harness_revision = $harness_revision |
.components.infra_revision = $infra_revision |
.host.architecture = $architecture |
.host.kernel = $kernel |
.security.policy_digests = [$observer_policy_sha256] |
.physical_targets = [
  {
    target_id: "controller-ci",
    scope: "controller",
    identity_kind: "x509_spki",
    identity_sha256: $target_identity,
    preflight_evidence_sha256: $target_evidence_sha256
  }
] |
.clock = {
  basis: "system_time",
  sync_protocol: "chrony_ntp",
  offset_ms: 0.5,
  drift_ppm: 2
}
