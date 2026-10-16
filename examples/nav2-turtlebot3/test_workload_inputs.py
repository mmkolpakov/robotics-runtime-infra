"""Exercise the actual workload input accessor while native entry stays closed."""

import ast
import json
import copy
import importlib.util
import tempfile
import unittest
from pathlib import Path

from test_v2_documents import inputs
from jsonschema import Draft202012Validator
from robotics_runtime_contracts import load_schema, schema_registry

ROOT = Path(__file__).parent


def workload_functions():
    import runpy

    return runpy.run_path(str(ROOT / "workload.py"))


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

    def test_direct_main_without_bound_inputs_refuses_before_ros_effects(self):
        import sys
        from unittest.mock import patch

        with patch.object(sys, "argv", ["workload.py"]), self.assertRaises(SystemExit):
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


class NativeAdmissionControls(unittest.TestCase):
    def setUp(self):
        import runpy

        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.module = runpy.run_path(str(ROOT / "make-scenario.py"))
        self.root.joinpath("fixture").mkdir()
        fixture, _ = inputs(self.root / "fixture")
        scenario = json.loads((fixture / "scenario.json").read_bytes())
        self.requirements = self.root / "requirements.json"
        self.requirements.write_text(
            json.dumps(
                {
                    "case": "success",
                    "configuration": scenario["extensions"][
                        "org.example.nav2-turtlebot3"
                    ],
                    "evaluator_requirement": scenario["evaluator_requirements"][0],
                }
            )
        )
        self.image_id = "sha256:" + "a" * 64
        self.image_reference = "localhost/nav2@sha256:" + "b" * 64
        self.preflight = self.root / "preflight.json"
        self.fact = self.image_fact()
        self.preflight.write_text(json.dumps(self.fact))

    def image_fact(self):
        import base64
        import hashlib

        policy = json.loads((ROOT / "inputs.lock.json").read_bytes())
        files = {}
        for key, path in self.module["NATIVE_FILES"].items():
            raw = ("controlled fixture " + key).encode()
            files[key] = {
                "path": path,
                "sha256": hashlib.sha256(raw).hexdigest(),
                "size_bytes": len(raw),
                "base64": base64.b64encode(raw).decode(),
            }
        build = {
            "policy_sha256": hashlib.sha256(
                (ROOT / "inputs.lock.json").read_bytes()
            ).hexdigest(),
            "dockerfile_sha256": hashlib.sha256(
                (ROOT / "Dockerfile").read_bytes()
            ).hexdigest(),
            "packages": {
                name: {"version": value["Version"], "sha256": value["SHA256"]}
                for name, value in policy["packages"].items()
            },
            "files": {
                name: {k: v for k, v in value.items() if k != "base64"}
                for name, value in files.items()
            },
        }
        return {
            "image_reference": self.image_reference,
            "image": {"Id": self.image_id, "RepoDigests": [self.image_reference]},
            "facts": {
                "build": build,
                "packages": {
                    name: {"version": value["Version"], "architecture": "amd64"}
                    for name, value in policy["packages"].items()
                },
                "type_support_version": "3.6.2",
                "sdk_versions": {
                    "robotics-runtime-contracts": "0.21.1",
                    "robotics-acceptance-harness": "0.22.2",
                },
                "files": files,
                "rendered": {
                    key: value
                    for key, value in files.items()
                    if key in ("model", "world")
                },
                "launch": self.module["NATIVE_LAUNCH"],
                "middleware_sha256": hashlib.sha256(
                    (ROOT / "fastdds.xml").read_bytes()
                ).hexdigest(),
            },
        }

    def prepare(self):
        prepared = self.root / "prepared"
        manifest = self.module["prepare"](
            None,
            self.requirements,
            prepared,
            native_preflight=self.preflight,
            image_reference=self.image_reference,
            image_id=self.image_id,
        )
        return prepared, manifest

    def test_current_public_bundle_admits_only_exact_bound_subject_model_and_run(self):
        prepared, manifest = self.prepare()
        result = self.module["validate_prepared"](
            prepared, image_id=self.image_id, case="success"
        )
        self.assertEqual(result["run_id"], manifest["run_id"])
        runtime = json.loads((prepared / "runtime.json").read_bytes())
        scenario = json.loads((prepared / "scenario.json").read_bytes())
        self.assertEqual(runtime["native_model"], scenario["native_model"])
        self.assertEqual(runtime["execution_subject"]["digest"], "sha256:" + "b" * 64)
        self.assertNotIn("synthetic", scenario["profile"]["executor"]["version"])
        for image, case in (
            ("sha256:" + "c" * 64, "success"),
            (self.image_id, "cancel"),
        ):
            with self.assertRaises(ValueError):
                self.module["validate_prepared"](prepared, image_id=image, case=case)

    def test_mismatched_image_sdk_model_recipe_or_launch_cannot_write_native_inputs(
        self,
    ):
        changes = [
            lambda d: d["image"].update(Id="sha256:" + "c" * 64),
            lambda d: d["facts"]["sdk_versions"].update(
                {"robotics-acceptance-harness": "0.19.1"}
            ),
            lambda d: d["facts"]["files"]["model"].update(sha256="f" * 64),
            lambda d: d["facts"]["build"].update(dockerfile_sha256="e" * 64),
            lambda d: d["facts"].update(launch=["sh", "-c", "true"]),
        ]
        for change in changes:
            with self.subTest(change=change):
                document = copy.deepcopy(self.fact)
                change(document)
                self.preflight.write_text(json.dumps(document))
                with self.assertRaises(ValueError):
                    self.prepare()
                self.assertFalse((self.root / "prepared").exists())

    def test_synthetic_document_profile_and_changed_prepared_bytes_refuse_native_worker(
        self,
    ):
        self.root.joinpath("documents").mkdir()
        documented, _ = inputs(self.root / "documents")
        with self.assertRaises((OSError, ValueError)):
            self.module["validate_prepared"](
                documented, image_id=self.image_id, case="success"
            )
        prepared, _ = self.prepare()
        path = prepared / "scenario.json"
        path.write_bytes(path.read_bytes() + b" ")
        with self.assertRaisesRegex(ValueError, "prepared input differs"):
            self.module["validate_prepared"](
                prepared, image_id=self.image_id, case="success"
            )

    def test_public_bundle_rejects_altered_profile_even_after_manifest_rehash(self):
        import hashlib

        prepared, _ = self.prepare()
        path = prepared / "runtime.json"
        runtime = json.loads(path.read_bytes())
        runtime["profile"]["executor"]["version"] = "different"
        path.write_text(json.dumps(runtime))
        manifest_path = prepared / "pre-execution-inputs.json"
        manifest = json.loads(manifest_path.read_bytes())
        manifest["runtime"].update(
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            size_bytes=path.stat().st_size,
        )
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaises(ValueError):
            self.module["validate_prepared"](
                prepared, image_id=self.image_id, case="success"
            )

    def test_rehashed_mounted_model_cannot_replace_verified_preflight_bytes(self):
        import hashlib

        prepared, _ = self.prepare()
        model = prepared / "native-model.sdf"
        model.write_bytes(b"altered model")
        manifest_path = prepared / "pre-execution-inputs.json"
        manifest = json.loads(manifest_path.read_bytes())
        manifest["native_model"].update(
            sha256=hashlib.sha256(model.read_bytes()).hexdigest(),
            size_bytes=model.stat().st_size,
        )
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "mounted native input differs"):
            self.module["validate_prepared"](
                prepared, image_id=self.image_id, case="success"
            )

    def test_rehashed_configuration_cannot_replace_executor_binding(self):
        import hashlib

        prepared, _ = self.prepare()
        path = prepared / "nav2-configuration.json"
        value = json.loads(path.read_bytes())
        value["goal"]["x"] += 1
        path.write_text(json.dumps(value))
        manifest_path = prepared / "pre-execution-inputs.json"
        manifest = json.loads(manifest_path.read_bytes())
        manifest["configuration"].update(
            sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
            size_bytes=path.stat().st_size,
        )
        manifest_path.write_text(json.dumps(manifest))
        with self.assertRaisesRegex(ValueError, "configuration"):
            self.module["validate_prepared"](
                prepared, image_id=self.image_id, case="success"
            )

    def test_embedded_image_receipt_is_valid_json_without_literal_escape_suffix(self):
        import shlex

        source = (ROOT / "Dockerfile").read_text().replace("\\\n", "")
        run = next(
            line
            for line in source.splitlines()
            if line.startswith("RUN /opt/consumer/bin/python -c")
        )
        arguments = shlex.split(run.removeprefix("RUN "))
        program = arguments[arguments.index("-c") + 1]
        tree = ast.parse(program)
        write = next(
            node
            for node in ast.walk(tree)
            if isinstance(node, ast.Call)
            and isinstance(node.func, ast.Attribute)
            and node.func.attr == "write_text"
        )
        raw = eval(
            compile(ast.Expression(write.args[0]), str(ROOT / "Dockerfile"), "eval"),
            {"json": json, "receipt": {"files": {}, "packages": {}}},
        )
        self.assertEqual(json.loads(raw), {"files": {}, "packages": {}})

    def test_worker_verifies_native_inputs_before_loading_ros(self):
        import os
        import runpy
        from types import SimpleNamespace
        from unittest.mock import patch

        prepared, manifest = self.prepare()
        worker = runpy.run_path(str(ROOT / "workload.py"))
        args = SimpleNamespace(
            prepared=prepared,
            scenario=prepared / "scenario.json",
            image_id=self.image_id,
            run_id=manifest["run_id"],
            domain_id="nav2",
            case="success",
        )
        with patch.dict(os.environ, {"NAV2_IMAGE_CONFIG_ID": self.image_id}):
            worker["admit_workload"](args)
            args.run_id = "foreign"
            with self.assertRaises(ValueError):
                worker["admit_workload"](args)

    def test_completed_negative_cases_do_not_fabricate_physical_postconditions(self):
        import runpy
        from datetime import datetime, UTC
        from test_v2_documents import completed

        for case in ("success", "cancel", "timeout", "server-failure"):
            with self.subTest(case=case), tempfile.TemporaryDirectory() as temporary:
                root = Path(temporary)
                prepared, _ = inputs(root, case=case)
                capture, _ = completed(
                    prepared,
                    json.loads((prepared / "pre-execution-inputs.json").read_bytes()),
                )
                (capture / "completed-facts.json").unlink()
                (capture / case).mkdir()
                (capture / "workload.json").rename(capture / case / "workload.json")
                (prepared / "native-model.sdf").write_text("fixture")
                (prepared / "native-world.sdf").write_text("fixture")
                (prepared / "native-preflight.json").write_text("{}")
                now = datetime.now(UTC).isoformat()
                (capture / "native-run.json").write_text(
                    json.dumps({"started_at": now, "finished_at": now})
                )
                (capture / "cleanup.json").write_text(
                    json.dumps(
                        {
                            "remaining": [],
                            "worker_settled": True,
                            "recorder_settled": True,
                        }
                    )
                )
                (capture / "recorder-facts").mkdir()
                manifest = json.loads(
                    (prepared / "pre-execution-inputs.json").read_bytes()
                )
                (capture / "recorder-facts/capture-state.json").write_text(
                    json.dumps(
                        {
                            "run_id": manifest["run_id"],
                            "domain_id": "nav2",
                            "capture_status": "complete",
                            "closure_confirmed": True,
                            "policy_observation": {
                                "recording_mode": "native-files",
                                "compression": "none",
                                "retention_class": "test-evidence",
                                "upload_mode": "local_only",
                                "remote_sink_used": False,
                                "spool_peak_size_bytes": 1024,
                                "upload_lag_max_sec": 0,
                            },
                        }
                    )
                )
                (capture / "native-acquired.json").write_text(
                    json.dumps({"HostConfig": {"NetworkMode": "none"}})
                )
                facts = runpy.run_path(str(ROOT / "finalize.py"))["complete_native"](
                    prepared, capture
                )
                if case != "success":
                    self.assertEqual(
                        facts["observations"]["condition"]["state"], "unobserved"
                    )
                self.assertEqual(facts["observations"]["cleanup"]["state"], "measured")
                finalize = runpy.run_path(str(ROOT / "finalize.py"))["complete"]
                self.assertEqual(
                    finalize(prepared, capture)["run_id"], manifest["run_id"]
                )


if __name__ == "__main__":
    unittest.main()
