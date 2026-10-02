package compose_test

import data.compose
import rego.v1

test_secure_service_is_allowed if {
	violations := compose.deny with input as {"services": {"runtime": {
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 0
}

test_privileged_service_is_denied if {
	violations := compose.deny with input as {"services": {"runtime": {
		"privileged": true,
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 1
}

test_host_control_fields_are_denied if {
	violations := compose.deny with input as {"services": {"runtime": {
		"provider": {"type": "host-command"},
		"use_api_socket": true,
		"pre_start": [{"command": ["prepare"]}],
		"post_start": [{"command": ["configure"]}],
		"pre_stop": [{"command": ["drain"]}],
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 5
}

test_host_namespaces_are_denied if {
	violations := compose.deny with input as {"services": {"runtime": {
		"network_mode": "host",
		"ipc": "host",
		"pid": "host",
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 3
}

test_host_user_cgroup_and_uts_namespaces_are_denied if {
	violations := compose.deny with input as {"services": {"runtime": {
		"userns_mode": "host",
		"cgroup": "host",
		"uts": "host",
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 3
}

test_private_cgroup_namespace_is_allowed if {
	violations := compose.deny with input as {"services": {"runtime": {
		"cgroup": "private",
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 0
}

test_unconfined_security_profiles_are_denied if {
	violations := compose.deny with input as {"services": {"runtime": {
		"cap_drop": ["ALL"],
		"security_opt": [
			"no-new-privileges:true",
			"seccomp=unconfined",
			"apparmor:unconfined",
			"label=disable",
			"systempaths=unconfined",
		],
	}}}
	count(violations) == 4
	"service \"runtime\" disables kernel confinement with seccomp=unconfined" in violations
}

test_custom_seccomp_profile_is_allowed if {
	violations := compose.deny with input as {"services": {"runtime": {
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true", "seccomp=/etc/robotics/seccomp.json"],
	}}}
	count(violations) == 0
}

test_device_cgroup_rule_is_denied if {
	violations := compose.deny with input as {"services": {"runtime": {
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
		"device_cgroup_rules": ["b *:* rwm"],
	}}}
	violations == {"service \"runtime\" adds a device cgroup rule"}
}

test_device_cgroup_rule_is_reported_once_in_real_observation_profile if {
	violations := compose.deny with input as {"services": {"real-observation-observer": {
		"profiles": ["real-observation"],
		"command": ["robotics-acceptance", "verify"],
		"environment": {
			"ROS_SECURITY_ENABLE": "true",
			"ROS_SECURITY_STRATEGY": "Enforce",
			"ROS_SECURITY_ENCLAVE_OVERRIDE": "/robotics/observer",
		},
		"device_cgroup_rules": ["c 81:* rmw"],
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 1
}

test_host_system_paths_are_denied if {
	violations := compose.deny with input as {"services": {"runtime": {
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
		"volumes": [
			{"type": "bind", "source": "/", "target": "/host", "read_only": true},
			{"type": "bind", "source": "/proc", "target": "/host/proc", "read_only": true},
			{"type": "bind", "source": "/sys/fs/cgroup", "target": "/sys/fs/cgroup"},
			"/proc/sysrq-trigger:/trigger:rw",
		],
	}}}
	count(violations) == 4
}

test_read_only_kernel_identity_file_is_allowed if {
	violations := compose.deny with input as {"services": {"runtime": {
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
		"volumes": [
			{
				"type": "bind",
				"source": "/proc/device-tree/compatible",
				"target": "/run/host/device-tree-compatible",
				"read_only": true,
			},
			"/sys/class/dmi/id/product_name:/run/host/product-name:ro",
		],
	}}}
	count(violations) == 0
}

test_docker_socket_is_denied if {
	violations := compose.deny with input as {"services": {"runtime": {
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
		"volumes": [{"source": "/var/run/docker.sock", "target": "/var/run/docker.sock"}],
	}}}
	count(violations) == 1
}

test_kernel_enumeration_serial_path_is_denied if {
	violations := compose.deny with input as {"services": {"runtime": {
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
		"devices": [{"source": "/dev/ttyUSB0", "target": "/dev/robotics/target"}],
	}}}
	count(violations) == 1
}

test_stable_serial_preflight_path_is_allowed if {
	violations := compose.deny with input as {"services": {"serial-device-preflight": {
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
		"devices": [{
			"source": "/dev/serial/by-id/usb-controller",
			"target": "/dev/robotics/target",
		}],
	}}}
	count(violations) == 0
}

test_arbitrary_serial_preflight_path_is_denied if {
	violations := compose.deny with input as {"services": {"serial-device-preflight": {
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
		"devices": [{"source": "/tmp/controller", "target": "/dev/robotics/target"}],
	}}}
	count(violations) == 1
}

test_receive_only_can_observation_is_allowed if {
	violations := compose.deny with input as {"services": {"can-observation-client": {
		"profiles": ["can-observation"],
		"command": ["nc", "172.30.247.1", "28700"],
		"networks": {"robotics-can-observation": null},
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 0
}

test_can_device_is_denied_in_observation_profile if {
	violations := compose.deny with input as {"services": {"can-observation-client": {
		"profiles": ["can-observation"],
		"command": ["nc", "172.30.247.1", "28700"],
		"networks": {"robotics-can-observation": null},
		"devices": [{"source": "/dev/robotics/can0", "target": "/dev/robotics/can0"}],
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 1
}

test_can_transmit_tool_is_denied_in_observation_profile if {
	violations := compose.deny with input as {"services": {"can-observation-client": {
		"profiles": ["can-observation"],
		"command": ["cansend", "can0", "123#DEADBEEF"],
		"networks": {"robotics-can-observation": null},
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 1
}

test_shell_wrapped_can_transmit_tool_is_denied_in_observation_profile if {
	violations := compose.deny with input as {"services": {"can-observation-client": {
		"profiles": ["can-observation"],
		"command": ["sh", "-c", "/usr/bin/cansend can0 123#DEADBEEF"],
		"networks": {"robotics-can-observation": null},
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 1
}

test_public_port_is_denied_in_can_observation_profile if {
	violations := compose.deny with input as {"services": {"can-observation-client": {
		"profiles": ["can-observation"],
		"command": ["nc", "172.30.247.1", "28700"],
		"networks": {"robotics-can-observation": null},
		"ports": [{"target": 28700, "published": "28700"}],
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 1
}

test_real_observation_without_devices_is_allowed if {
	violations := compose.deny with input as {"services": {"real-observation-observer": {
		"profiles": ["real-observation"],
		"command": ["robotics-acceptance", "verify"],
		"environment": {
			"ROS_SECURITY_ENABLE": "true",
			"ROS_SECURITY_STRATEGY": "Enforce",
			"ROS_SECURITY_ENCLAVE_OVERRIDE": "/robotics/observer",
		},
		"cap_drop": ["ALL"],
		"security_opt": ["no-new-privileges:true"],
	}}}
	count(violations) == 0
}

test_device_is_denied_in_real_observation_profile if {
	candidate := {
		"services": {"real-observation-observer": {
			"profiles": ["real-observation"],
			"command": ["robotics-acceptance", "verify"],
			"environment": {
				"ROS_SECURITY_ENABLE": "true",
				"ROS_SECURITY_STRATEGY": "Enforce",
				"ROS_SECURITY_ENCLAVE_OVERRIDE": "/robotics/observer",
			},
			"devices": [{"source": "/dev/video0", "target": "/dev/video0"}],
			"cap_drop": ["ALL"],
			"security_opt": ["no-new-privileges:true"],
		}},
	}
	violations := compose.deny with input as candidate
	count(violations) == 1
}

test_ros_topic_pub_is_denied_in_real_observation_profile if {
	candidate := {
		"services": {"real-observation-observer": {
			"profiles": ["real-observation"],
			"command": ["bash", "-lc", "ros2 topic pub /cmd_vel geometry_msgs/msg/Twist {}"],
			"environment": {
				"ROS_SECURITY_ENABLE": "true",
				"ROS_SECURITY_STRATEGY": "Enforce",
				"ROS_SECURITY_ENCLAVE_OVERRIDE": "/robotics/observer",
			},
			"cap_drop": ["ALL"],
			"security_opt": ["no-new-privileges:true"],
		}},
	}
	violations := compose.deny with input as candidate
	count(violations) == 1
}

test_permissive_sros2_is_denied_in_real_observation_profile if {
	candidate := {
		"services": {"real-observation-observer": {
			"profiles": ["real-observation"],
			"command": ["robotics-acceptance", "verify"],
			"environment": {
				"ROS_SECURITY_ENABLE": "true",
				"ROS_SECURITY_STRATEGY": "Permissive",
				"ROS_SECURITY_ENCLAVE_OVERRIDE": "/robotics/observer",
			},
			"cap_drop": ["ALL"],
			"security_opt": ["no-new-privileges:true"],
		}},
	}
	violations := compose.deny with input as candidate
	count(violations) == 1
}

test_high_throughput_runtime_manifest_requires_profile_environment if {
	candidate := {
		"services": {"runtime-manifest": {
			"environment": {
				"ROBOTICS_DATA_PLANE_PROFILE": "local_high_throughput",
				"RMW_FASTRTPS_USE_QOS_FROM_XML": "1",
				"RMW_IMPLEMENTATION": "rmw_fastrtps_cpp",
				"ROS_AUTOMATIC_DISCOVERY_RANGE": "LOCALHOST",
			},
			"cap_drop": ["ALL"],
			"security_opt": ["no-new-privileges:true"],
		}},
	}
	violations := compose.deny with input as candidate
	"high-throughput runtime manifest requires FASTRTPS_DEFAULT_PROFILES_FILE=/etc/robotics/fastdds/high-throughput.xml" in violations
}

test_high_throughput_runtime_manifest_environment_is_allowed if {
	candidate := {
		"services": {"runtime-manifest": {
			"environment": {
				"ROBOTICS_DATA_PLANE_PROFILE": "local_high_throughput",
				"FASTRTPS_DEFAULT_PROFILES_FILE": "/etc/robotics/fastdds/high-throughput.xml",
				"RMW_FASTRTPS_USE_QOS_FROM_XML": "1",
				"RMW_IMPLEMENTATION": "rmw_fastrtps_cpp",
				"ROS_AUTOMATIC_DISCOVERY_RANGE": "LOCALHOST",
			},
			"cap_drop": ["ALL"],
			"security_opt": ["no-new-privileges:true"],
		}},
	}
	violations := compose.deny with input as candidate
	count(violations) == 0
}
