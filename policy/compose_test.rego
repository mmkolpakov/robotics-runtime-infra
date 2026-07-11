package compose_test

import rego.v1
import data.compose

test_secure_service_is_allowed if {
    violations := compose.deny with input as {
        "services": {
            "runtime": {
                "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"]
            }
        }
    }
    count(violations) == 0
}

test_privileged_service_is_denied if {
    violations := compose.deny with input as {
        "services": {
            "runtime": {
                "privileged": true,
                "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"]
            }
        }
    }
    count(violations) == 1
}

test_host_namespaces_are_denied if {
    violations := compose.deny with input as {
        "services": {
            "runtime": {
                "network_mode": "host",
                "ipc": "host",
                "pid": "host",
                "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"]
            }
        }
    }
    count(violations) == 3
}

test_docker_socket_is_denied if {
    violations := compose.deny with input as {
        "services": {
            "runtime": {
                "cap_drop": ["ALL"],
                "security_opt": ["no-new-privileges:true"],
                "volumes": [{"source": "/var/run/docker.sock", "target": "/var/run/docker.sock"}]
            }
        }
    }
    count(violations) == 1
}
