package hardware_workflow

import rego.v1

triggers := object.get(input, "on", object.get(input, "true", {}))
jobs := object.get(input, "jobs", {})

deny contains "hardware workflow must only use workflow_dispatch" if {
	object.keys(triggers) != {"workflow_dispatch"}
}

deny contains "workflow permissions must default to contents read" if {
	object.get(object.get(input, "permissions", {}), "contents", "") != "read"
}

deny contains message if {
	some name, job in jobs
	self_hosted(job)
	object.get(job, "environment", null) == null
	message := sprintf("self-hosted job %q has no protected environment", [name])
}

deny contains message if {
	some name, job in jobs
	self_hosted(job)
	not contains(object.get(job, "if", ""), "refs/heads/main")
	message := sprintf("self-hosted job %q is not restricted to main", [name])
}

deny contains message if {
	some name, job in jobs
	some step in object.get(job, "steps", [])
	uses := object.get(step, "uses", "")
	uses != ""
	not regex.match("^[^@]+@[a-f0-9]{40}$", uses)
	message := sprintf("job %q uses an action without an immutable commit SHA", [name])
}

deny contains message if {
	some name, job in jobs
	some step in object.get(job, "steps", [])
	startswith(object.get(step, "uses", ""), "actions/checkout@")
	object.get(object.get(step, "with", {}), "persist-credentials", true) != false
	message := sprintf("job %q persists checkout credentials", [name])
}

self_hosted(job) if {
	runs_on := object.get(job, "runs-on", [])
	is_array(runs_on)
	"self-hosted" in runs_on
}
