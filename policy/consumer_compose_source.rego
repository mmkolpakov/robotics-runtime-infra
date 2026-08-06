package consumer_compose_source

import rego.v1

host_control_fields := {"provider", "use_api_socket", "pre_start", "post_start", "pre_stop"}

deny contains "consumer Compose source must not include other models" if {
	count(object.get(input, "include", [])) > 0
}

deny contains message if {
	some name, service in object.get(input, "services", {})
	object.get(service, "extends", null) != null
	message := sprintf("consumer service %q uses extends", [name])
}

deny contains message if {
	some name, service in object.get(input, "services", {})
	object.get(service, "env_file", null) != null
	message := sprintf("consumer service %q uses env_file", [name])
}

deny contains message if {
	some name, service in object.get(input, "services", {})
	object.get(service, "label_file", null) != null
	message := sprintf("consumer service %q uses label_file", [name])
}

deny contains message if {
	some name, resource in object.get(input, "configs", {})
	some source in ["content", "environment"]
	object.get(resource, source, null) != null
	message := sprintf("consumer config %q uses %s", [name, source])
}

deny contains "consumer Compose source must not declare secrets" if {
	count(object.get(input, "secrets", {})) > 0
}

deny contains message if {
	some name, service in object.get(input, "services", {})
	some field in host_control_fields
	object.get(service, field, null) != null
	message := sprintf("consumer service %q uses host-control field %s", [name, field])
}
