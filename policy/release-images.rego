package release_images

import rego.v1

registry_prefix := "ghcr.io/mmkolpakov/robotics-runtime-infra/"
local_prefix := "local/robotics-runtime-infra/"
runtime_mode := object.get(
	object.get(input, "x-robotics-runtime", {}),
	"mode",
	"source",
)

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

immutable_sha256_reference(reference) if {
	regex.match(
		"^ghcr\\.io/mmkolpakov/robotics-runtime-infra/[a-z0-9][a-z0-9._/-]*(:[^@[:space:]]+)?@sha256:[a-f0-9]{64}$",
		reference,
	)
}
