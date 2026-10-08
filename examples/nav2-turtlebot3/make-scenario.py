"""Write the consumer requirements through the published contracts API."""

import argparse
import hashlib
from pathlib import Path

from robotics_runtime_contracts import load_mapping
from robotics_runtime_contracts.writers import write_document

NAMESPACE = "org.example.nav2-turtlebot3"
SCHEMA_URI = "urn:nav2-turtlebot3:scenario:v1"


def create(
    case: str,
    receipt_path: Path,
    middleware_path: Path,
    schema_path: Path,
    output: Path,
) -> None:
    receipt = load_mapping(receipt_path)
    schema = schema_path.read_bytes()
    graph = {
        "topics": [
            {
                "name": name,
                "type": message_type,
                "min_publishers": 1,
                "min_subscribers": 1,
                "first_message_timeout_sec": 10,
                "qos_profile": "transient_local"
                if name == "/amcl_pose"
                else "system_default",
            }
            for name, message_type in (
                ("/odom", "nav_msgs/msg/Odometry"),
                ("/clock", "rosgraph_msgs/msg/Clock"),
                ("/tf", "tf2_msgs/msg/TFMessage"),
                ("/amcl_pose", "geometry_msgs/msg/PoseWithCovarianceStamped"),
            )
        ],
        "services": [
            {
                "name": "/request_nomotion_update",
                "type": "std_srvs/srv/Empty",
                "server_required": True,
            }
        ],
        "actions": [
            {
                "name": "/navigate_to_pose",
                "type": "nav2_msgs/action/NavigateToPose",
                "server_required": True,
            }
        ],
        "lifecycle_nodes": [
            {
                "name": name,
                "required_state": "active",
                "timeout_sec": 10,
                "stable_for_sec": 0.1,
            }
            for name in ("/amcl", "/bt_navigator")
        ],
    }
    scenario = {
        "schema_version": "acceptance-scenario.v1",
        "scenario_id": "nav2-turtlebot3-" + case,
        "execution": {
            "target_environment": "simulation",
            "hardware_scope": [],
            "physical_effect": "none",
            "test_intent": "functional",
            "data_source": "simulator",
            "plant_backend": "simulated_physics",
            "time_mode": "simulation_realtime",
            "data_plane_profile": "fastdds-udp-private",
            "security_profile": "none",
        },
        "authorization": {"mode": "none"},
        "forbidden_ros_graph": {"topics": [], "services": [], "actions": []},
        "seed": 0,
        "timeouts": {
            "startup_sec": 180,
            "graph_ready_sec": 10,
            "stable_for_sec": 0.1,
            "execution_sec": 120,
            "shutdown_sec": 30,
        },
        "expected_ros_graph": graph,
        "provider_requirements": {
            "capabilities": ["ros-topic-capture", "owned-native-cleanup"]
        },
        "evaluator_requirements": [
            {
                "namespace": NAMESPACE,
                "entry_point": "nav2_turtlebot3_evaluator:evaluate",
                "distribution": "nav2-turtlebot3-evaluator",
                "version": "0.2.1",
                "artifact_sha256": receipt["artifact"]["sha256"],
                "receipt_sha256": hashlib.sha256(receipt_path.read_bytes()).hexdigest(),
            }
        ],
        "metric_definitions": [],
        "assertions": [],
        # Fixed public consumer baseline; never adjusted to make an observed run pass.
        "time_policy": {
            "min_realtime_factor": 0.8,
            "max_deadline_miss_ratio": 0.01,
            "time_authority_min_samples": 30,
            "max_time_authority_delivery_latency_p50_ms": 2,
            "max_time_authority_delivery_latency_p95_ms": 5,
            "max_time_authority_delivery_latency_ms": 250,
        },
        "data_plane_policy": {
            "max_message_age_ms": 100,
            "max_loss_ratio": 0,
            "shm_transport": False,
            "data_sharing": False,
            "private_ipc": True,
            "middleware_configuration_sha256": hashlib.sha256(
                middleware_path.read_bytes()
            ).hexdigest(),
        },
        "evidence_policy": {
            "topics": [
                "/odom",
                "/tf",
                "/tf_static",
                "/clock",
                "/amcl_pose",
                "/navigate_to_pose/_action/feedback",
                "/navigate_to_pose/_action/status",
            ],
            "recording_mode": "bounded",
            "compression": "zstd",
            "max_segment_size_bytes": 64 * 1024**2,
            "max_segment_duration_sec": 180,
            "max_spool_size_bytes": 64 * 1024**2,
            "spool_high_watermark_ratio": 1,
            "max_upload_lag_sec": 0,
            "upload_mode": "local_only",
            "retention_class": "test-evidence",
            "remote_sink_allowed": False,
        },
        "extension_schemas": [
            {
                "namespace": NAMESPACE,
                "schema_uri": SCHEMA_URI,
                "sha256": hashlib.sha256(schema).hexdigest(),
            }
        ],
        "extensions": {
            NAMESPACE: {
                "case": case,
                "goal": {"x": 1.0, "y": -0.5},
                "action_budget_sec": 120.0,
                "application_timeout_sec": 2.0,
                "max_final_pose_error_m": 0.35,
                "min_displacement_m": 0.5,
                "max_observation_age_sec": 2.0,
                "odometry_frame": "odom",
                "required_tf_edges": [
                    ["map", "odom"],
                    ["odom", "base_footprint"],
                    ["base_footprint", "base_link"],
                ],
            }
        },
    }
    if output.exists():
        raise FileExistsError("scenario output must be new")
    write_document(scenario, output, extension_schemas={SCHEMA_URI: schema})


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--case",
        choices=["success", "cancel", "timeout", "server-failure"],
        required=True,
    )
    parser.add_argument("--evaluator-receipt", type=Path, required=True)
    parser.add_argument("--middleware-profile", type=Path, required=True)
    parser.add_argument("--schema", type=Path, required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    create(
        args.case,
        args.evaluator_receipt,
        args.middleware_profile,
        args.schema,
        args.output,
    )


if __name__ == "__main__":
    main()
