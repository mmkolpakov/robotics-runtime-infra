package execution

import rego.v1

permit := object.get(input, "permit", {})
statement := object.get(input, "statement", {})
trust_policy := object.get(input, "trust_policy", {})
request := object.get(input, "request", {})
artifacts := object.get(input, "artifacts", {})
signers := object.get(input, "verified_signers", [])

deny contains "statement must use in-toto Statement v1" if {
	object.get(statement, "_type", "") != "https://in-toto.io/Statement/v1"
}

deny contains "statement predicate type does not match the permit" if {
	object.get(statement, "predicateType", "") != object.get(permit, "predicate_type", "")
}

deny contains "statement predicate does not equal the validated permit" if {
	object.get(statement, "predicate", {}) != permit
}

deny contains "statement must contain exactly two subjects" if {
	count(object.get(statement, "subject", [])) != 2
}

deny contains "statement must contain exactly one scenario subject" if {
	count(scenario_subjects) != 1
}

deny contains "statement scenario digest does not match the permit" if {
	count(scenario_subjects) == 1
	object.get(object.get(scenario_subjects[0], "digest", {}), "sha256", "") != object.get(permit, "scenario_sha256", "")
}

deny contains "statement must contain exactly one runtime image subject" if {
	count(image_subjects) != 1
}

deny contains "statement image digest does not match the permit" if {
	count(image_subjects) == 1
	expected := trim_prefix(object.get(permit, "image_digest", ""), "sha256:")
	object.get(object.get(image_subjects[0], "digest", {}), "sha256", "") != expected
}

deny contains "trust policy must use execution-trust-policy.v1" if {
	object.get(trust_policy, "schema_version", "") != "execution-trust-policy.v1"
}

deny contains "trust policy digest does not match the permit" if {
	object.get(artifacts, "trust_policy_sha256", "") != object.get(permit, "trust_policy_sha256", "")
}

deny contains "trust policy lifetime must be between one and 1800 seconds" if {
	max_lifetime := object.get(trust_policy, "max_permit_lifetime_seconds", 0)
	max_lifetime < 1
}

deny contains "trust policy lifetime must be between one and 1800 seconds" if {
	object.get(trust_policy, "max_permit_lifetime_seconds", 0) > 1800
}

deny contains "permit is not active yet" if {
	time.now_ns() < issued_at_ns
}

deny contains "permit has expired" if {
	time.now_ns() > expires_at_ns
}

deny contains "permit lifetime exceeds the trust policy" if {
	expires_at_ns - issued_at_ns > object.get(trust_policy, "max_permit_lifetime_seconds", 0) * 1000000000
}

deny contains "observed interlock check does not match the permit" if {
	object.get(request, "interlock_check", {}) != object.get(permit, "interlock_check", {})
}

deny contains "observed scenario digest does not match the permit" if {
	object.get(request, "scenario_sha256", "") != object.get(permit, "scenario_sha256", "")
}

deny contains "observed image digest does not match the permit" if {
	object.get(request, "image_digest", "") != object.get(permit, "image_digest", "")
}

deny contains "observed target identity does not match the permit" if {
	object.get(request, "target", {}) != object.get(permit, "target", {})
}

deny contains "target is not allowed by the lab trust policy" if {
	not trusted_target
}

deny contains "observed physical effect does not match the permit" if {
	object.get(request, "allowed_physical_effect", "") != object.get(permit, "allowed_physical_effect", "")
}

deny contains "observed hardware scope does not match the permit" if {
	array_set(object.get(request, "hardware_scope", [])) != array_set(object.get(permit, "hardware_scope", []))
}

deny contains message if {
	some signer in signers
	object.get(signer, "identity", "") != expected_identity(object.get(signer, "role", ""))
	message := sprintf("verified %s identity does not match the permit", [object.get(signer, "role", "unknown")])
}

deny contains message if {
	some signer in signers
	not trusted_signer(signer)
	message := sprintf("verified %s signer is not allowed by the lab trust policy", [object.get(signer, "role", "unknown")])
}

deny contains message if {
	some signer in signers
	object.get(signer, "transparency_log_verified", false) != true
	message := sprintf("verified %s signer has no transparency-log proof", [object.get(signer, "role", "unknown")])
}

deny contains message if {
	some signer in signers
	integrated_ns := object.get(signer, "integrated_time", -1) * 1000000000
	integrated_ns < issued_at_ns
	message := sprintf("verified %s signature predates the permit", [object.get(signer, "role", "unknown")])
}

deny contains message if {
	some signer in signers
	integrated_ns := object.get(signer, "integrated_time", -1) * 1000000000
	integrated_ns > expires_at_ns
	message := sprintf("verified %s signature postdates the permit", [object.get(signer, "role", "unknown")])
}

scenario_subjects := [subject |
	some subject in object.get(statement, "subject", [])
	object.get(subject, "name", "") == "robotics-scenario"
]

image_subjects := [subject |
	some subject in object.get(statement, "subject", [])
	object.get(subject, "name", "") == "robotics-runtime-image"
]

issued_at_ns := time.parse_rfc3339_ns(permit.issued_at)
expires_at_ns := time.parse_rfc3339_ns(permit.expires_at)

array_set(values) := {value | some value in values}

expected_identity("operator") := object.get(permit, "operator_id", "")
expected_identity("approver") := object.get(permit, "approver_id", "")

trusted_signer(signer) if {
	some principal in object.get(trust_policy, "principals", [])
	object.get(principal, "role", "") == object.get(signer, "role", "")
	object.get(principal, "identity", "") == object.get(signer, "identity", "")
	object.get(principal, "issuer", "") == object.get(signer, "issuer", "")
}

trusted_target if {
	target := object.get(permit, "target", {})
	some allowed in object.get(trust_policy, "targets", [])
	object.get(allowed, "target_id", "") == object.get(target, "target_id", "")
	object.get(allowed, "identity_kind", "") == object.get(target, "identity_kind", "")
	object.get(allowed, "identity_sha256", "") == object.get(target, "identity_sha256", "")
	object.get(target, "environment", "") in array_set(object.get(allowed, "environments", []))
}

verification := {
	"schema_version": "execution-verification.v1",
	"verification_id": object.get(permit, "permit_id", ""),
	"permit_sha256": object.get(artifacts, "permit_sha256", ""),
	"statement_sha256": object.get(artifacts, "statement_sha256", ""),
	"policy_sha256": object.get(artifacts, "policy_sha256", ""),
	"trust_policy_sha256": object.get(artifacts, "trust_policy_sha256", ""),
	"target": object.get(permit, "target", {}),
	"verified_at": time.format(time.now_ns()),
	"cosign_version": object.get(artifacts, "cosign_version", ""),
	"cosign_image_digest": object.get(artifacts, "cosign_image_digest", ""),
	"signers": signers,
	"decision": "allow",
} if {
	count(deny) == 0
}
