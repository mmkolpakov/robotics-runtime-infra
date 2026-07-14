package execution_test

import data.execution
import rego.v1

fixed_now := time.parse_rfc3339_ns("2026-07-14T12:00:00Z")

violations(candidate) := result if {
	result := execution.deny with input as candidate with time.now_ns as fixed_now
}

test_valid_hil_permit_is_allowed if {
	count(violations(data.execution_valid)) == 0
}

test_valid_hil_permit_emits_verification if {
	verification := execution.verification with input as data.execution_valid with time.now_ns as fixed_now
	verification.schema_version == "execution-verification.v1"
	verification.decision == "allow"
	verification.verified_at == "2026-07-14T12:00:00Z"
	count(verification.signers) == 2
}

test_expired_permit_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/permit/expires_at", "value": "2026-07-14T11:59:59Z"}, {"op": "replace", "path": "/statement/predicate/expires_at", "value": "2026-07-14T11:59:59Z"}])
	"permit has expired" in violations(candidate)
}

test_future_permit_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/permit/issued_at", "value": "2026-07-14T12:01:00Z"}, {"op": "replace", "path": "/statement/predicate/issued_at", "value": "2026-07-14T12:01:00Z"}])
	"permit is not active yet" in violations(candidate)
}

test_tampered_statement_predicate_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/statement/predicate/nonce", "value": "ffffffffffffffffffffffffffffffff"}])
	"statement predicate does not equal the validated permit" in violations(candidate)
}

test_wrong_scenario_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/request/scenario_sha256", "value": "7777777777777777777777777777777777777777777777777777777777777777"}])
	"observed scenario digest does not match the permit" in violations(candidate)
}

test_wrong_image_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/request/image_digest", "value": "sha256:7777777777777777777777777777777777777777777777777777777777777777"}])
	"observed image digest does not match the permit" in violations(candidate)
}

test_wrong_target_identity_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/request/target/identity_sha256", "value": "7777777777777777777777777777777777777777777777777777777777777777"}])
	"observed target identity does not match the permit" in violations(candidate)
}

test_untrusted_target_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/trust_policy/targets/0/identity_sha256", "value": "7777777777777777777777777777777777777777777777777777777777777777"}])
	"target is not allowed by the lab trust policy" in violations(candidate)
}

test_same_approver_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/permit/approver_id", "value": "operator@example.org"}, {"op": "replace", "path": "/statement/predicate/approver_id", "value": "operator@example.org"}, {"op": "replace", "path": "/verified_signers/1/identity", "value": "operator@example.org"}])
	"operator and approver identities must differ" in violations(candidate)
	"verified signer identities must differ" in violations(candidate)
}

test_untrusted_issuer_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/verified_signers/1/issuer", "value": "https://issuer.example.invalid"}])
	"verified approver signer is not allowed by the lab trust policy" in violations(candidate)
}

test_duplicate_bundle_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/verified_signers/1/bundle_sha256", "value": "5555555555555555555555555555555555555555555555555555555555555555"}])
	"verified signer bundles must differ" in violations(candidate)
}

test_signature_outside_permit_window_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/verified_signers/1/integrated_time", "value": 1784031060}])
	"verified approver signature postdates the permit" in violations(candidate)
}

test_missing_transparency_log_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/verified_signers/0/transparency_log_verified", "value": false}])
	"verified operator signer has no transparency-log proof" in violations(candidate)
}

test_hil_effect_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/permit/allowed_physical_effect", "value": "observation"}, {"op": "replace", "path": "/statement/predicate/allowed_physical_effect", "value": "observation"}, {"op": "replace", "path": "/request/allowed_physical_effect", "value": "observation"}])
	"HIL permits must have no physical effect" in violations(candidate)
}

test_actuator_scope_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "add", "path": "/permit/hardware_scope/-", "value": "actuator"}, {"op": "add", "path": "/statement/predicate/hardware_scope/-", "value": "actuator"}, {"op": "add", "path": "/request/hardware_scope/-", "value": "actuator"}])
	"physical execution scope must not contain actuator" in violations(candidate)
}

test_trust_policy_digest_mismatch_is_denied if {
	candidate := json.patch(data.execution_valid, [{"op": "replace", "path": "/artifacts/trust_policy_sha256", "value": "7777777777777777777777777777777777777777777777777777777777777777"}])
	"trust policy digest does not match the permit" in violations(candidate)
}
