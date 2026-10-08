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

test_consumer_local_image_is_denied_in_released_mode if {
	violations := release_images.deny with input as {
		"x-robotics-runtime": {"mode": "released"},
		"services": {"product": {"image": "local/consumer/product:dev"}},
	}
	"service \"product\" falls back to a local development image in released mode" in violations
}

test_misspelled_runtime_mode_is_denied if {
	violations := release_images.deny with input as {
		"x-robotics-runtime": {"mode": "relased"},
		"services": {},
	}
	"runtime mode must be source or released" in violations
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

approved := "ghcr.io/mmkolpakov/robotics-runtime-infra/simulation:0.5.0@sha256:9165b1ad483c7b9ef9739c988fff7e6b015daa4893b09a2b99b015d9cb34e5e6"

test_released_tag_and_repository_digest_are_equivalent if {
	every image in [
		approved,
		"ghcr.io/mmkolpakov/robotics-runtime-infra/simulation@sha256:9165b1ad483c7b9ef9739c988fff7e6b015daa4893b09a2b99b015d9cb34e5e6",
		"ghcr.io/mmkolpakov/robotics-runtime-infra/simulation:display-tag@sha256:9165b1ad483c7b9ef9739c988fff7e6b015daa4893b09a2b99b015d9cb34e5e6",
	] {
		violations := release_images.deny with input as {
			"x-robotics-runtime": {"mode": "released", "approved_images": [approved]},
			"services": {"simulation": {"image": image}},
		}
		count(violations) == 0
	}
}

test_released_requires_a_nonempty_valid_approved_set if {
	every approvals in [[], null, {}, ["mutable:tag"], [approved, 1]] {
		violations := release_images.deny with input as {
			"x-robotics-runtime": {"mode": "released", "approved_images": approvals},
			"services": {"simulation": {"image": approved}},
		}
		"released mode requires approved digest-pinned images" in violations
	}
	violations := release_images.deny with input as {
		"x-robotics-runtime": {"mode": "released"},
		"services": {"simulation": {"image": approved}},
	}
	"released mode requires approved digest-pinned images" in violations
}

test_released_rejects_foreign_mutable_and_missing_images if {
	every service in [
		{"image": "docker.io/example/product:latest"},
		{"image": "docker.io/example/product@sha256:1234"},
		{"build": {"context": "."}},
	] {
		violations := release_images.deny with input as {
			"x-robotics-runtime": {"mode": "released", "approved_images": [approved]},
			"services": {"product": service},
		}
		"service \"product\" uses a runtime image without an immutable sha256 digest" in violations
	}
}

test_released_rejects_unapproved_repository_or_digest if {
	every image in [
		"ghcr.io/foreign/robotics-runtime-infra/simulation@sha256:9165b1ad483c7b9ef9739c988fff7e6b015daa4893b09a2b99b015d9cb34e5e6",
		"ghcr.io/mmkolpakov/robotics-runtime-infra/other@sha256:9165b1ad483c7b9ef9739c988fff7e6b015daa4893b09a2b99b015d9cb34e5e6",
		"ghcr.io/mmkolpakov/robotics-runtime-infra/simulation@sha256:0000000000000000000000000000000000000000000000000000000000000000",
	] {
		violations := release_images.deny with input as {
			"x-robotics-runtime": {"mode": "released", "approved_images": [approved]},
			"services": {"product": {"image": image}},
		}
		"service \"product\" uses an image outside the approved release lock" in violations
	}
}

test_released_rejects_every_residual_build if {
	every build in [{}, {"context": "."}, ".", null] {
		violations := release_images.deny with input as {
			"x-robotics-runtime": {"mode": "released", "approved_images": [approved]},
			"services": {"simulation": {"image": approved, "build": build}},
		}
		"service \"simulation\" retains a build definition in released mode" in violations
	}
}

test_source_builds_and_foreign_mutable_images_keep_existing_scope if {
	violations := release_images.deny with input as {
		"x-robotics-runtime": {"mode": "source"},
		"services": {"product": {"image": "docker.io/example/product:dev", "build": "."}},
	}
	count(violations) == 0
}

test_approved_registry_port_is_not_a_display_tag if {
	image := "registry.example:5000/product@sha256:9165b1ad483c7b9ef9739c988fff7e6b015daa4893b09a2b99b015d9cb34e5e6"
	lock := "registry.example:5000/product:v1@sha256:9165b1ad483c7b9ef9739c988fff7e6b015daa4893b09a2b99b015d9cb34e5e6"
	violations := release_images.deny with input as {
		"x-robotics-runtime": {"mode": "released", "approved_images": [lock]},
		"services": {"product": {"image": image}},
	}
	count(violations) == 0
	wrong_port := release_images.deny with input as {
		"x-robotics-runtime": {"mode": "released", "approved_images": [lock]},
		"services": {"product": {"image": replace(image, ":5000/", ":5001/")}},
	}
	"service \"product\" uses an image outside the approved release lock" in wrong_port
}

test_approved_upstream_dependency_is_allowed if {
	image := "otel/opentelemetry-collector-contrib@sha256:0000000000000000000000000000000000000000000000000000000000000001"
	violations := release_images.deny with input as {
		"x-robotics-runtime": {"mode": "released", "approved_images": [approved, image]},
		"services": {"collector": {"image": image}},
	}
	count(violations) == 0
}
