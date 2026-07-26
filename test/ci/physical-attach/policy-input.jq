{
  permit: $permit[0],
  statement: $statement[0],
  trust_policy: $trust_policy[0],
  request: $request[0],
  artifacts: {
    permit_sha256: $permit_sha256,
    statement_sha256: $statement_sha256,
    policy_sha256: $policy_sha256,
    trust_policy_sha256: $trust_policy_sha256,
    cosign_version: $cosign_version,
    cosign_image_digest: $cosign_image_digest
  },
  verified_signers: [
    {
      role: "operator",
      identity: $operator_identity,
      issuer: $operator_issuer,
      bundle_sha256: $operator_bundle_sha256,
      integrated_time: $operator_integrated_time,
      transparency_log_verified: true
    },
    {
      role: "approver",
      identity: $approver_identity,
      issuer: $approver_issuer,
      bundle_sha256: $approver_bundle_sha256,
      integrated_time: $approver_integrated_time,
      transparency_log_verified: true
    }
  ]
}
