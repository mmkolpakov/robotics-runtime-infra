package scenario

import rego.v1

deny contains "interface mocks are limited to interface_smoke" if {
    input.execution.plant_backend == "interface_mock"
    input.execution.test_intent != "interface_smoke"
}

deny contains "interface mocks cannot produce metric verdicts" if {
    input.execution.plant_backend == "interface_mock"
    count(object.get(input, "assertions", [])) > 0
}

deny contains "interface mocks cannot claim a physical effect" if {
    input.execution.plant_backend == "interface_mock"
    input.execution.physical_effect != "none"
}
