package compose

import rego.v1

deny contains message if {
	some name, service in input.services
	service.privileged == true
	message := sprintf("service %q enables privileged mode", [name])
}

deny contains message if {
	some name, service in input.services
	service.network_mode == "host"
	message := sprintf("service %q joins the host network namespace", [name])
}

deny contains message if {
	some name, service in input.services
	service.ipc == "host"
	message := sprintf("service %q joins the host IPC namespace", [name])
}

deny contains message if {
	some name, service in input.services
	service.pid == "host"
	message := sprintf("service %q joins the host PID namespace", [name])
}

deny contains message if {
	some name, service in input.services
	count(object.get(service, "cap_add", [])) > 0
	message := sprintf("service %q adds Linux capabilities", [name])
}

deny contains message if {
	some name, service in input.services
	not "ALL" in object.get(service, "cap_drop", [])
	message := sprintf("service %q does not drop all Linux capabilities", [name])
}

deny contains message if {
	some name, service in input.services
	not "no-new-privileges:true" in object.get(service, "security_opt", [])
	message := sprintf("service %q does not enable no-new-privileges", [name])
}

deny contains message if {
	some name, service in input.services
	some volume in object.get(service, "volumes", [])
	source := volume_source(volume)
	docker_socket(source)
	message := sprintf("service %q mounts the Docker control socket", [name])
}

deny contains message if {
	some name, service in input.services
	some device in object.get(service, "devices", [])
	broad_device(device)
	message := sprintf("service %q exposes a broad device mapping", [name])
}

volume_source(volume) := source if {
	is_object(volume)
	source := object.get(volume, "source", "")
}

volume_source(volume) := source if {
	is_string(volume)
	source := split(volume, ":")[0]
}

docker_socket(source) if {
	source == "/var/run/docker.sock"
}

docker_socket(source) if {
	source == "/run/docker.sock"
}

broad_device(device) if {
	is_string(device)
	startswith(device, "/dev:/dev")
}

broad_device(device) if {
	is_object(device)
	object.get(device, "source", "") == "/dev"
}
