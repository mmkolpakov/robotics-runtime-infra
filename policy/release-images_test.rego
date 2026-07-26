package release_images_test

import data.release_images
import rego.v1

test_published_image_with_tag_and_digest_is_allowed if {
	violations := release_images.deny with input as {
		"services": {
			"simulation": {
				"image": "ghcr.io/mmkolpakov/robotics-runtime-infra/simulation:0.5.0@sha256:9165b1ad483c7b9ef9739c988fff7e6b015daa4893b09a2b99b015d9cb34e5e6",
			},
		},
	}
	count(violations) == 0
}

test_local_development_image_is_allowed if {
	violations := release_images.deny with input as {
		"services": {
			"simulation": {
				"image": "local/robotics-simulation:dev",
			},
		},
	}
	count(violations) == 0
}

test_local_development_image_is_denied_in_released_mode if {
	violations := release_images.deny with input as {
		"x-robotics-runtime": {"mode": "released"},
		"services": {
			"simulation": {
				"image": "local/robotics-runtime-infra/simulation:dev",
			},
		},
	}
	"service \"simulation\" falls back to a local development image in released mode" in violations
}

test_mutable_published_tag_is_denied if {
	violations := release_images.deny with input as {
		"services": {
			"simulation": {
				"image": "ghcr.io/mmkolpakov/robotics-runtime-infra/simulation:0.5.0",
			},
		},
	}
	"service \"simulation\" uses a runtime image without an immutable sha256 digest" in violations
}

test_short_digest_is_denied if {
	violations := release_images.deny with input as {
		"services": {
			"simulation": {
				"image": "ghcr.io/mmkolpakov/robotics-runtime-infra/simulation:0.5.0@sha256:9165b1ad",
			},
		},
	}
	"service \"simulation\" uses a runtime image without an immutable sha256 digest" in violations
}

test_third_party_registry_reference_is_out_of_scope if {
	violations := release_images.deny with input as {
		"services": {
			"bridge": {
				"image": "docker.io/eclipse/zenoh-bridge-ros2dds:1.9.0",
			},
		},
	}
	count(violations) == 0
}
