package release_images

import rego.v1

registry_prefix := "ghcr.io/mmkolpakov/robotics-runtime-infra/"
local_prefix := "local/"
runtime_mode := object.get(
	object.get(input, "x-robotics-runtime", {}),
	"mode",
	"source",
)

deny contains "runtime mode must be source or released" if {
	not runtime_mode in {"source", "released"}
}

deny contains message if {
	some name, service in object.get(input, "services", {})
	reference := object.get(service, "image", "")
	startswith(reference, registry_prefix)
	not immutable_sha256_reference(reference)
	message := sprintf(
		"service %q uses a runtime image without an immutable sha256 digest",
		[name],
	)
}

deny contains message if {
	runtime_mode == "released"
	some name, service in object.get(input, "services", {})
	reference := object.get(service, "image", "")
	startswith(reference, local_prefix)
	message := sprintf(
		"service %q falls back to a local development image in released mode",
		[name],
	)
}

approved_images := object.get(
	object.get(input, "x-robotics-runtime", {}),
	"approved_images",
	[],
)

deny contains "released mode requires approved digest-pinned images" if {
	runtime_mode == "released"
	not valid_approved_images
}

deny contains message if {
	runtime_mode == "released"
	some name, service in object.get(input, "services", {})
	"build" in object.keys(service)
	message := sprintf("service %q retains a build definition in released mode", [name])
}

deny contains message if {
	runtime_mode == "released"
	some name, service in object.get(input, "services", {})
	reference := object.get(service, "image", "")
	not startswith(reference, local_prefix)
	not digest_pinned_reference(reference)
	message := sprintf(
		"service %q uses a runtime image without an immutable sha256 digest",
		[name],
	)
}

deny contains message if {
	runtime_mode == "released"
	some name, service in object.get(input, "services", {})
	reference := object.get(service, "image", "")
	digest_pinned_reference(reference)
	not approved_reference(reference)
	message := sprintf("service %q uses an image outside the approved release lock", [name])
}

valid_approved_images if {
	is_array(approved_images)
	count(approved_images) > 0
	every reference in approved_images {
		digest_pinned_reference(reference)
	}
}

digest_pinned_reference(reference) if {
	regex.match("^[^@[:space:]]+@sha256:[a-f0-9]{64}$", reference)
}

repository_digest(reference) := identity if {
	digest_pinned_reference(reference)
	parts := split(reference, "@")

	# Strip a tag after the final slash; retain a registry's port.
	repository := regex.replace(parts[0], ":[^/:]+$", "")
	identity := concat("@", [repository, parts[1]])
}

approved_reference(reference) if {
	some approved in approved_images
	repository_digest(reference) == repository_digest(approved)
}

immutable_sha256_reference(reference) if {
	regex.match(
		"^ghcr\\.io/mmkolpakov/robotics-runtime-infra/[a-z0-9][a-z0-9._/-]*(:[^@[:space:]]+)?@sha256:[a-f0-9]{64}$",
		reference,
	)
}
