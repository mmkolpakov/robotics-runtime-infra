package consumer_compose_source_test

import data.consumer_compose_source
import rego.v1

test_literal_service_and_local_config_are_allowed if {
	violations := consumer_compose_source.deny with input as {
		"services": {"product": {"image": "example.invalid/product@sha256:deadbeef"}},
		"configs": {"settings": {"file": "./config/settings.yaml"}},
	}
	count(violations) == 0
}

test_recursive_sources_are_denied if {
	violations := consumer_compose_source.deny with input as {
		"include": ["other.yaml"],
		"services": {"product": {"extends": {"file": "base.yaml", "service": "base"}}},
	}
	count(violations) == 2
}

test_service_file_sources_are_denied if {
	violations := consumer_compose_source.deny with input as {"services": {"product": {
		"env_file": ["product.env"],
		"label_file": ["product.labels"],
	}}}
	count(violations) == 2
}

test_environment_backed_resources_are_denied if {
	violations := consumer_compose_source.deny with input as {
		"configs": {
			"inline": {"content": "${HOST_VALUE}"},
			"environment": {"environment": "HOST_VALUE"},
		},
		"secrets": {"token": {"environment": "HOST_TOKEN"}},
	}
	count(violations) == 3
}

test_host_control_fields_are_denied if {
	violations := consumer_compose_source.deny with input as {"services": {"product": {
		"provider": {"type": "host-command"},
		"use_api_socket": true,
		"pre_start": [{"command": ["prepare"]}],
		"post_start": [{"command": ["configure"]}],
		"pre_stop": [{"command": ["drain"]}],
	}}}
	count(violations) == 5
}
