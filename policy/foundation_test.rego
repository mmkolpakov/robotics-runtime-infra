package foundation_test

import data.foundation
import rego.v1

base_input := {
	"foundation": {
		"services": {"simulation": {"image": "example/foundation@sha256:123"}},
		"networks": {"default": {"name": "foundation_default"}},
	},
	"consumer": {
		"services": {
			"product": {
				"image": "example/product@sha256:456",
				"volumes": [{"type": "bind", "source": "/workspace/consumer/src", "target": "/src"}],
			},
		},
	},
	"resolved": {
		"services": {
			"simulation": {"image": "example/foundation@sha256:123"},
			"product": {
				"image": "example/product@sha256:456",
				"volumes": [{"type": "bind", "source": "/workspace/consumer/src", "target": "/src"}],
			},
		},
		"networks": {"default": {"name": "foundation_default"}},
	},
	"consumer_root": "/workspace/consumer",
	"allowed_services": ["product"],
}

test_valid_consumer_is_allowed if {
	violations := foundation.deny with input as base_input
	count(violations) == 0
}

test_foundation_override_is_denied if {
	modified := object.union(base_input, {
		"consumer": {"services": {"simulation": {"image": "attacker"}}},
		"allowed_services": ["simulation"],
	})
	violations := foundation.deny with input as modified
	count(violations) > 0
}

test_unlisted_service_is_denied if {
	modified := object.union(base_input, {"allowed_services": []})
	violations := foundation.deny with input as modified
	count(violations) > 0
}

test_external_bind_mount_is_denied if {
	consumer := object.union(base_input.consumer, {
		"services": {
			"product": {
				"image": "example/product@sha256:456",
				"volumes": [{"type": "bind", "source": "/tmp", "target": "/src"}],
			},
		},
	})
	modified := object.union(base_input, {"consumer": consumer})
	violations := foundation.deny with input as modified
	count(violations) > 0
}

test_modified_foundation_service_is_denied if {
	resolved := object.union(base_input.resolved, {
		"services": object.union(base_input.resolved.services, {
			"simulation": {"image": "attacker"},
		}),
	})
	modified := object.union(base_input, {"resolved": resolved})
	violations := foundation.deny with input as modified
	count(violations) > 0
}

test_local_driver_volume_options_are_denied if {
	modified := object.union(base_input, {
		"consumer": object.union(base_input.consumer, {
			"volumes": {
				"socket": {
					"driver": "local",
					"driver_opts": {"device": "/var/run/docker.sock", "type": "none"},
				},
			},
		}),
	})
	violations := foundation.deny with input as modified
	count(violations) > 0
}

test_volumes_from_is_denied if {
	consumer := object.union(base_input.consumer, {
		"services": {
			"product": object.union(base_input.consumer.services.product, {
				"volumes_from": ["simulation:rw"],
			}),
		},
	})
	violations := foundation.deny with input as object.union(base_input, {"consumer": consumer})
	count(violations) > 0
}

test_external_config_file_is_denied if {
	consumer := object.union(base_input.consumer, {
		"configs": {"host": {"file": "/etc/passwd"}},
	})
	violations := foundation.deny with input as object.union(base_input, {"consumer": consumer})
	count(violations) > 0
}

test_external_secret_is_denied if {
	consumer := object.union(base_input.consumer, {
		"secrets": {"host": {"external": true}},
	})
	violations := foundation.deny with input as object.union(base_input, {"consumer": consumer})
	count(violations) > 0
}
