package foundation

import rego.v1

deny contains message if {
	some name, _ in input.consumer.services
	name in object.keys(input.foundation.services)
	message := sprintf("consumer service %q conflicts with the foundation", [name])
}

deny contains message if {
	consumer_names := {name | some name, _ in input.consumer.services}
	allowed_names := {name | some name in input.allowed_services}
	consumer_names != allowed_names
	message := sprintf(
		"consumer services must equal the explicit allow-list: services=%v allow-list=%v",
		[consumer_names, allowed_names],
	)
}

deny contains message if {
	some name, service in input.foundation.services
	object.get(input.resolved.services, name, null) != service
	message := sprintf("resolved foundation service %q differs from the trusted model", [name])
}

deny contains message if {
	expected := object.keys(input.foundation.services) | object.keys(input.consumer.services)
	observed := object.keys(input.resolved.services)
	expected != observed
	message := sprintf("resolved service registry differs: expected=%v observed=%v", [expected, observed])
}

deny contains message if {
	some kind in ["volumes", "networks", "configs", "secrets"]
	foundation_resources := object.get(input.foundation, kind, {})
	consumer_resources := object.get(input.consumer, kind, {})
	some name, _ in consumer_resources
	name in object.keys(foundation_resources)
	not shared_default_network(kind, name)
	message := sprintf("consumer %s %q conflicts with the foundation", [kind, name])
}

deny contains message if {
	some kind in ["volumes", "networks", "configs", "secrets"]
	some name, resource in object.get(input.foundation, kind, {})
	object.get(object.get(input.resolved, kind, {}), name, null) != resource
	message := sprintf("resolved foundation %s %q differs from the trusted model", [kind, name])
}

deny contains message if {
	some name, service in input.consumer.services
	some volume in object.get(service, "volumes", [])
	object.get(volume, "type", "") == "bind"
	source := object.get(volume, "source", "")
	not within_consumer_root(source)
	message := sprintf("consumer service %q mounts a path outside its repository: %s", [name, source])
}

deny contains message if {
	some name, service in input.consumer.services
	count(object.get(service, "volumes_from", [])) > 0
	message := sprintf("consumer service %q uses volumes_from", [name])
}

deny contains message if {
	some name, resource in object.get(input.consumer, "volumes", {})
	unsafe_volume(resource)
	message := sprintf("consumer volume %q bypasses project isolation", [name])
}

deny contains message if {
	some kind in ["configs", "secrets"]
	some name, resource in object.get(input.consumer, kind, {})
	object.get(resource, "external", false) == true
	message := sprintf("consumer %s %q is external", [kind, name])
}

deny contains message if {
	some kind in ["configs", "secrets"]
	some name, resource in object.get(input.consumer, kind, {})
	path := object.get(resource, "file", "")
	path != ""
	not within_consumer_root(path)
	message := sprintf("consumer %s %q reads outside its repository: %s", [kind, name, path])
}

deny contains message if {
	some name, service in input.consumer.services
	contexts := object.get(object.get(service, "build", {}), "additional_contexts", {})
	count(contexts) > 0
	message := sprintf("consumer service %q uses additional build contexts", [name])
}

deny contains message if {
	some name, service in input.consumer.services
	build := object.get(service, "build", {})
	context := object.get(build, "context", "")
	context != ""
	not within_consumer_root(context)
	message := sprintf("consumer service %q builds from outside its repository: %s", [name, context])
}

within_consumer_root(path) if {
	path == input.consumer_root
}

within_consumer_root(path) if {
	startswith(path, sprintf("%s/", [input.consumer_root]))
}

shared_default_network("networks", "default")

unsafe_volume(resource) if {
	object.get(resource, "external", false) == true
}

unsafe_volume(resource) if {
	object.get(resource, "name", "") != ""
}

unsafe_volume(resource) if {
	count(object.get(resource, "driver_opts", {})) > 0
}

unsafe_volume(resource) if {
	driver := object.get(resource, "driver", "local")
	driver != "local"
}
