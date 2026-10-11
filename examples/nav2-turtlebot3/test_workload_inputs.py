"""Exercise the actual workload input accessor while native entry stays closed."""

import ast
import json
import copy
import importlib.util
import math
import tempfile
import unittest
from pathlib import Path

from test_v2_documents import inputs
from jsonschema import Draft202012Validator
from robotics_runtime_contracts import load_schema, schema_registry

ROOT = Path(__file__).parent


def workload_functions():
    # Native ROS libraries are unavailable in this portable document profile.
    # Compile the existing pure accessor and main guard, not a replacement driver.
    tree = ast.parse((ROOT / "workload.py").read_bytes())
    selected = [
        node
        for node in tree.body
        if isinstance(node, ast.FunctionDef)
        and node.name in {"readiness_parameters", "main"}
    ]
    namespace = {"math": math}
    exec(
        compile(
            ast.Module(body=selected, type_ignores=[]),
            str(ROOT / "workload.py"),
            "exec",
        ),
        namespace,
    )
    return namespace


class WorkloadInputs(unittest.TestCase):
    def test_actual_v2_writer_output_is_consumed_by_workload_accessor(self):
        with tempfile.TemporaryDirectory() as temporary:
            prepared, _manifest = inputs(Path(temporary))
            scenario = json.loads((prepared / "scenario.json").read_bytes())
            self.assertNotIn("expected_ros_graph", scenario)
            self.assertNotIn("timeouts", scenario)
            graph, budget, stability = workload_functions()["readiness_parameters"](
                scenario
            )
            expected = scenario["extensions"]["org.example.nav2-turtlebot3"][
                "readiness"
            ]
            self.assertIs(graph, expected["graph"])
            self.assertEqual(
                (budget, stability),
                (expected["timeout_sec"], expected["stable_for_sec"]),
            )

    def test_self_contained_graph_type_equals_the_published_sdk_definition(self):
        specification = importlib.util.spec_from_file_location(
            "readiness_schema", ROOT / "sync-readiness-schema.py"
        )
        generated = importlib.util.module_from_spec(specification)
        specification.loader.exec_module(generated)
        stored = json.loads((ROOT / "nav2.schema.json").read_bytes())
        self.assertEqual(stored["$defs"], generated.definitions())
        sdk = Draft202012Validator(
            load_schema("acceptance-scenario.v1")["properties"]["expected_ros_graph"],
            registry=schema_registry(),
        )
        local = Draft202012Validator(
            {"$defs": stored["$defs"], "$ref": "#/$defs/expectedRosGraph"}
        )
        valid = json.loads(
            (ROOT / "evaluator/tests/readiness-control.json").read_bytes()
        )["graph"]
        full = copy.deepcopy(valid)
        full["topics"][0]["qos_profile"] = "sensor_data"
        full["services"] = [
            {
                "name": "/lifecycle_manager_navigation/manage_nodes",
                "type": "nav2_msgs/srv/ManageLifecycleNodes",
                "server_required": True,
            }
        ]
        full["lifecycle_nodes"] = [
            {
                "name": "/bt_navigator",
                "required_state": "active",
                "timeout_sec": 2,
                "stable_for_sec": 0.5,
            }
        ]
        malformed = copy.deepcopy(full)
        malformed["topics"][0]["type"] = "not-a-ROS-message-type"
        unknown = copy.deepcopy(full)
        unknown["unknown"] = True
        bad_qos = copy.deepcopy(full)
        bad_qos["topics"][0]["qos_profile"] = "unknown"
        bad_service = copy.deepcopy(full)
        bad_service["services"][0]["server_required"] = False
        bad_lifecycle = copy.deepcopy(full)
        bad_lifecycle["lifecycle_nodes"][0]["required_state"] = "inactive"
        bad_timeout = copy.deepcopy(full)
        bad_timeout["topics"][0]["first_message_timeout_sec"] = 0
        for graph, accepted in (
            (valid, True),
            (full, True),
            (malformed, False),
            (unknown, False),
            (bad_qos, False),
            (bad_service, False),
            (bad_lifecycle, False),
            (bad_timeout, False),
        ):
            with self.subTest(graph=graph):
                self.assertEqual(sdk.is_valid(graph), accepted)
                self.assertEqual(local.is_valid(graph), accepted)

    def test_direct_main_call_refuses_before_parser_or_ros_effects(self):
        with self.assertRaisesRegex(SystemExit, "native launch requires"):
            workload_functions()["main"]()

    def test_invalid_stability_refuses_before_execution(self):
        with tempfile.TemporaryDirectory() as temporary:
            prepared, _manifest = inputs(Path(temporary))
            scenario = json.loads((prepared / "scenario.json").read_bytes())
            settings = scenario["extensions"]["org.example.nav2-turtlebot3"][
                "readiness"
            ]
            settings["stable_for_sec"] = settings["timeout_sec"]
            with self.assertRaisesRegex(ValueError, "ten-second budget"):
                workload_functions()["readiness_parameters"](scenario)


if __name__ == "__main__":
    unittest.main()
