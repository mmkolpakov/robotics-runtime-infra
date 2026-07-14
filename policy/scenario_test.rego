package scenario_test

import data.scenario
import rego.v1

test_interface_smoke_is_allowed if {
	violations := scenario.deny with input as {
		"execution": {
			"plant_backend": "interface_mock",
			"test_intent": "interface_smoke",
			"physical_effect": "none",
		},
		"assertions": [],
	}
	count(violations) == 0
}

test_mock_metric_verdict_is_denied if {
	violations := scenario.deny with input as {
		"execution": {
			"plant_backend": "interface_mock",
			"test_intent": "functional",
			"physical_effect": "actuation",
		},
		"assertions": [{"kind": "metric"}],
	}
	count(violations) == 3
}
