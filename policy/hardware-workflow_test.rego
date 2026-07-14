package hardware_workflow_test

import data.hardware_workflow
import rego.v1

safe_workflow := {
	"on": {"workflow_dispatch": {}},
	"permissions": {"contents": "read"},
	"jobs": {"qualification": {
		"if": "github.ref == 'refs/heads/main'",
		"runs-on": ["self-hosted", "linux", "robotics-hardware"],
		"environment": {"name": "accelerator-lab"},
		"steps": [{
			"uses": "actions/checkout@9c091bb21b7c1c1d1991bb908d89e4e9dddfe3e0",
			"with": {"persist-credentials": false},
		}],
	}},
}

test_protected_manual_workflow_is_allowed if {
	violations := hardware_workflow.deny with input as safe_workflow
	count(violations) == 0
}

test_pull_request_hardware_workflow_is_denied if {
	candidate := object.union(safe_workflow, {
		"on": {"pull_request": {}},
		"jobs": {"qualification": {
			"if": "success()",
			"environment": null,
		}},
	})
	violations := hardware_workflow.deny with input as candidate
	count(violations) == 3
}

test_mutable_action_and_checkout_token_are_denied if {
	candidate := object.union(safe_workflow, {"jobs": {"qualification": {"steps": [{
		"uses": "actions/checkout@v7",
		"with": {"persist-credentials": true},
	}]}}})
	violations := hardware_workflow.deny with input as candidate
	count(violations) == 2
}
