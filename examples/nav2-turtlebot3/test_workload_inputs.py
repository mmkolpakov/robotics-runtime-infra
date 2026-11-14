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


class NavigatorStartup(unittest.TestCase):
    def test_initial_phase_sets_pose_before_waiting_for_activation(self):
        from unittest.mock import Mock, call, patch

        initialize = workload_functions()["initialize_navigator"]
        navigator = Mock(spec=["setInitialPose", "waitUntilNav2Active"])
        selected_pose = object()
        with patch.dict(initialize.__globals__, {"pose": lambda *args: selected_pose}):
            initialize(navigator, False)
        self.assertEqual(
            navigator.mock_calls,
            [call.setInitialPose(selected_pose), call.waitUntilNav2Active()],
        )

    def test_exercise_does_not_call_pose_republishing_startup_method(self):
        from unittest.mock import Mock

        initialize = workload_functions()["initialize_navigator"]
        navigator = Mock(spec=["setInitialPose", "waitUntilNav2Active"])
        navigator.waitUntilNav2Active.side_effect = AssertionError(
            "SDK startup may publish its stored default pose"
        )
        initialize(navigator, True)
        navigator.setInitialPose.assert_not_called()
        navigator.waitUntilNav2Active.assert_not_called()


class PackageLocations(unittest.TestCase):
    def package_lookup(self, lookup):
        import sys
        from types import ModuleType
        from unittest.mock import patch

        package = ModuleType("ament_index_python")
        package.__path__ = []
        packages = ModuleType("ament_index_python.packages")
        packages.get_package_prefix = lookup
        return patch.dict(
            sys.modules,
            {"ament_index_python": package, "ament_index_python.packages": packages},
        )

    def test_mcap_header_uses_the_selected_ament_overlay(self):
        from unittest.mock import Mock

        with tempfile.TemporaryDirectory() as temporary:
            prefix = Path(temporary) / "workspace install/mcap_vendor"
            header = prefix / "include/mcap_vendor/mcap/writer.hpp"
            header.parent.mkdir(parents=True)
            header.write_bytes(b"selected header bytes")
            lookup = Mock(return_value=str(prefix))
            with self.package_lookup(lookup):
                resolved = workload_functions()["mcap_writer_header_path"]()
            self.assertEqual(resolved, header)
            self.assertEqual(resolved.read_bytes(), b"selected header bytes")
            lookup.assert_called_once_with("mcap_vendor")

    def test_standard_ros_prefix_keeps_the_existing_header_location(self):
        from unittest.mock import Mock

        lookup = Mock(return_value="/opt/ros/jazzy")
        with self.package_lookup(lookup):
            header = workload_functions()["mcap_writer_header_path"]()
        self.assertEqual(
            header, Path("/opt/ros/jazzy/include/mcap_vendor/mcap/writer.hpp")
        )
        lookup.assert_called_once_with("mcap_vendor")

    def test_missing_mcap_package_does_not_fall_back_to_a_system_path(self):
        from unittest.mock import Mock

        lookup = Mock(side_effect=LookupError("package not found"))
        with (
            self.package_lookup(lookup),
            self.assertRaisesRegex(LookupError, "package not found"),
        ):
            workload_functions()["mcap_writer_header_path"]()
        lookup.assert_called_once_with("mcap_vendor")


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
        readiness = scenario["extensions"]["org.example.nav2-turtlebot3"]["readiness"]
        readiness["graph"]["lifecycle_nodes"] = [
            {
                "name": name,
                "required_state": "active",
                "timeout_sec": readiness["timeout_sec"],
                "stable_for_sec": readiness["stable_for_sec"],
            }
            for name in ("/amcl", "/bt_navigator")
        ]
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
            raw = (
                (ROOT / "native_simulation.launch.py").read_bytes()
                if key == "consumer_launch"
                else ("controlled fixture " + key).encode()
            )
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
                    "robotics-runtime-contracts": "0.22.0",
                    "robotics-acceptance-harness": "0.23.1",
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

    def prepare(self, output_name="prepared"):
        prepared = self.root / output_name
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

    def test_native_inputs_require_declared_active_lifecycle_nodes(self):
        requirements = json.loads(self.requirements.read_bytes())
        changes = [
            lambda graph: graph.update(lifecycle_nodes=[]),
            lambda graph: graph["lifecycle_nodes"][0].update(name="/foreign/amcl"),
            lambda graph: graph["lifecycle_nodes"][1].update(required_state="inactive"),
            lambda graph: graph["lifecycle_nodes"][0].update(timeout_sec=0),
        ]
        for index, change in enumerate(changes):
            with self.subTest(change=change):
                selected = copy.deepcopy(requirements)
                change(selected["configuration"]["readiness"]["graph"])
                self.requirements.write_text(json.dumps(selected))
                output_name = "invalid-lifecycle-" + str(index)
                with self.assertRaises(ValueError):
                    self.prepare(output_name)
                self.assertFalse((self.root / output_name).exists())

    def test_bare_podman_config_id_preserves_canonical_binding_and_raw_fact(self):
        bare_id = self.image_id.removeprefix("sha256:")
        self.fact["image"]["Id"] = bare_id
        self.preflight.write_text(json.dumps(self.fact))
        prepared, _manifest = self.prepare()
        result = self.module["validate_prepared"](
            prepared, image_id=self.image_id, case="success"
        )
        self.assertEqual(result["image_id"], self.image_id)
        retained = json.loads((prepared / "native-preflight.json").read_bytes())
        self.assertEqual(retained["image"]["Id"], bare_id)

    def test_mismatched_image_sdk_model_recipe_or_launch_cannot_write_native_inputs(
        self,
    ):
        changes = [
            lambda d: d["image"].update(Id="sha256:" + "c" * 64),
            lambda d: d["image"].update(Id="c" * 64),
            lambda d: d["image"].update(Id="not-a-config-id"),
            lambda d: d["image"].update(Id=None),
            lambda d: d["facts"]["sdk_versions"].update(
                {"robotics-acceptance-harness": "0.19.1"}
            ),
            lambda d: d["facts"]["files"]["model"].update(sha256="f" * 64),
            lambda d: d["facts"]["files"]["consumer_launch"].update(sha256="f" * 64),
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
        with self.assertRaisesRegex(ValueError, "(?s)explain.*exit 2.*profile"):
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

    def test_native_inventory_excludes_known_uninstalled_and_retains_held_packages(
        self,
    ):
        import re
        import shlex
        import subprocess

        source = (ROOT / "Dockerfile").read_text().replace("\\\n", "")
        run = next(
            line
            for line in source.splitlines()
            if line.startswith("RUN /opt/consumer/bin/python -c")
        )
        arguments = shlex.split(run.removeprefix("RUN "))
        build = ast.parse(arguments[arguments.index("-c") + 1])
        inspector = next(
            node
            for node in ast.parse((ROOT / "make-scenario.py").read_text()).body
            if isinstance(node, ast.FunctionDef) and node.name == "inspect_image"
        )
        with tempfile.TemporaryDirectory() as temporary:
            database = Path(temporary)
            database.joinpath("status").write_text(
                "Package: ros-jazzy-installed\nStatus: hold ok installed\n"
                "Architecture: amd64\nVersion: 1\nMaintainer: Fixture <fixture@example.invalid>\nDescription: held fixture\n\n"
                "Package: ros-jazzy-absent\nStatus: unknown ok not-installed\n"
                "Architecture: amd64\n\n"
                "Package: ros-jazzy-config\nStatus: deinstall ok config-files\n"
                "Architecture: amd64\nVersion: 1\nMaintainer: Fixture <fixture@example.invalid>\nDescription: residual fixture\n"
            )
            for tree in (build, inspector):
                assignments = {
                    node.targets[0].id: node.value
                    for node in tree.body
                    if isinstance(node, ast.Assign)
                    and len(node.targets) == 1
                    and isinstance(node.targets[0], ast.Name)
                }
                name = "inventory" if "inventory" in assignments else "installed"
                command = ast.literal_eval(assignments[name].args[0])
                raw = subprocess.check_output(
                    [command[0], "--admindir=" + str(database), *command[1:]]
                )
                selected = eval(
                    compile(
                        ast.Expression(assignments["ros_packages"]),
                        "ROS inventory",
                        "eval",
                    ),
                    {name: raw},
                )
                self.assertEqual(selected, ["ros-jazzy-installed"])
            queries = re.findall(
                r"\$\((dpkg-query[^\n]+)\)", (ROOT / "Dockerfile").read_text()
            )
            self.assertEqual(len(queries), 2)
            for query in queries:
                selected = subprocess.check_output(
                    [
                        "/bin/sh",
                        "-c",
                        query.replace("dpkg-query", 'dpkg-query --admindir="$1"', 1),
                        "fixture",
                        str(database),
                    ],
                    text=True,
                ).splitlines()
                self.assertEqual(selected, ["ros-jazzy-installed"])
            self.assertEqual(
                (ROOT / "Dockerfile").read_text().count("--reinstall --only-upgrade"), 2
            )

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

    def test_each_rehashed_run_binding_refuses_independently(self):
        import hashlib

        prepared, _ = self.prepare()
        run_path = prepared / "run.json"
        manifest_path = prepared / "pre-execution-inputs.json"
        original_run, original_manifest = (
            run_path.read_bytes(),
            manifest_path.read_bytes(),
        )
        changes = {
            "run_id": "run-22222222-3333-4444-8555-666666666666",
            "scenario_id": "another-scenario",
            "scenario_sha256": "f" * 64,
            "domains": [{"domain_id": "another-domain", "role": "simulation"}],
        }
        for field, value in changes.items():
            with self.subTest(field=field):
                run = json.loads(original_run)
                run[field] = value
                raw = json.dumps(run).encode()
                run_path.write_bytes(raw)
                manifest = json.loads(original_manifest)
                manifest["run_context"].update(
                    sha256=hashlib.sha256(raw).hexdigest(), size_bytes=len(raw)
                )
                manifest_path.write_text(json.dumps(manifest))
                with self.assertRaisesRegex(ValueError, "run context"):
                    self.module["validate_prepared"](
                        prepared, image_id=self.image_id, case="success"
                    )
        run_path.write_bytes(original_run)
        manifest_path.write_bytes(original_manifest)

    def test_cli_and_local_checks_consume_the_captured_generation(self):
        import subprocess
        from unittest.mock import patch

        prepared, _ = self.prepare()
        names = (
            "nav2.schema.json",
            "native-preflight.json",
            "native-profile.json",
            "nav2-configuration.json",
        )
        originals = {name: (prepared / name).read_bytes() for name in names}
        validate = self.module["validate_prepared"]
        capture, invoke = validate.__globals__["read_once"], subprocess.run
        counts = {}

        def read_once(path, limit, **options):
            if path.parent == prepared:
                counts[path.name] = counts.get(path.name, 0) + 1
            return capture(path, limit, **options)

        def run(arguments, **options):
            if arguments[1] == "explain":
                for name in names:
                    (prepared / name).write_bytes(b"{}")
                option = arguments[arguments.index("--extension-schema") + 1]
                schema = Path(option.split("=", 1)[1])
                self.assertNotEqual(schema, prepared / "nav2.schema.json")
                self.assertEqual(schema.read_bytes(), originals["nav2.schema.json"])
                self.assertEqual(schema.stat().st_mode & 0o777, 0o400)
                self.assertEqual(schema.parent.stat().st_mode & 0o777, 0o700)
            return invoke(arguments, **options)

        try:
            with (
                patch.dict(validate.__globals__, {"read_once": read_once}),
                patch.object(subprocess, "run", side_effect=run),
            ):
                admitted = validate(prepared, image_id=self.image_id, case="success")
            self.assertEqual(
                admitted["configuration"], json.loads(originals[names[-1]])
            )
            for name in names:
                self.assertEqual(counts[name], 1)
        finally:
            for name, raw in originals.items():
                (prepared / name).write_bytes(raw)

    def test_cli_failures_do_not_retry_or_issue_another_run(self):
        import subprocess
        from unittest.mock import patch

        invoke = subprocess.run
        modes = (
            "missing",
            "exit2",
            "timeout-after-write",
            "missing-output",
            "wrong-stdout",
            "existing-output",
        )
        for mode in modes:
            with self.subTest(mode=mode):
                output = self.root / ("cli-" + mode)
                calls = []

                def run(arguments, **options):
                    calls.append(arguments)
                    if mode == "missing":
                        raise FileNotFoundError("controlled unavailable executable")
                    if mode == "exit2":
                        options["stderr"].write(
                            b"error: $.runtime.profile differs from scenario\n"
                        )
                        return subprocess.CompletedProcess(arguments, 2)
                    if arguments[1] == "create-run":
                        context = Path(arguments[arguments.index("--output") + 1])
                        reserved = arguments[arguments.index("--run-id") + 1]
                        if mode == "missing-output":
                            options["stdout"].write((reserved + "\n").encode())
                            return subprocess.CompletedProcess(arguments, 0)
                        if mode == "existing-output":
                            context.write_text("{}")
                        result = invoke(arguments, **options)
                        if mode == "timeout-after-write":
                            self.assertEqual(result.returncode, 0)
                            raise subprocess.TimeoutExpired(arguments, 30)
                        if mode == "wrong-stdout":
                            options["stdout"].seek(0)
                            options["stdout"].truncate()
                            options["stdout"].write(b"another-run\n")
                        return result
                    return invoke(arguments, **options)

                def prepare():
                    return self.module["prepare"](
                        None,
                        self.requirements,
                        output,
                        native_preflight=self.preflight,
                        image_reference=self.image_reference,
                        image_id=self.image_id,
                    )

                with patch.object(subprocess, "run", side_effect=run):
                    with self.assertRaises((ValueError, OSError)):
                        prepare()
                    self.assertLessEqual(sum(c[1] == "create-run" for c in calls), 1)
                    if mode == "timeout-after-write":
                        issued = json.loads((output / "run.json").read_bytes())[
                            "run_id"
                        ]
                        command = next(c for c in calls if c[1] == "create-run")
                        self.assertEqual(issued, command[command.index("--run-id") + 1])
                        count = len(calls)
                        with self.assertRaises(FileExistsError):
                            prepare()
                        self.assertEqual(len(calls), count)
                self.assertFalse((output / "pre-execution-inputs.json").exists())

    def test_worker_keeps_admitted_scenario_when_source_changes_before_ros_use(self):
        import os
        import sys
        from unittest.mock import patch

        prepared, manifest = self.prepare()
        worker = workload_functions()
        main = worker["main"]
        actual_admit = worker["admit_workload"]
        admitted = {}
        parameters = json.loads((prepared / "scenario.json").read_bytes())[
            "extensions"
        ]["org.example.nav2-turtlebot3"]

        class BeforeRosUse(Exception):
            pass

        def admit(args):
            admitted.update(actual_admit(args))
            return admitted

        def load_ros():
            (prepared / "scenario.json").write_text("{}")

        def readiness(scenario):
            self.assertIs(scenario, admitted["scenario"])
            self.assertEqual(
                scenario["extensions"]["org.example.nav2-turtlebot3"], parameters
            )
            raise BeforeRosUse()

        argv = [
            "workload.py",
            "--case",
            "success",
            "--run-id",
            manifest["run_id"],
            "--domain-id",
            "nav2",
            "--output",
            str(self.root / "worker"),
            "--scenario",
            str(prepared / "scenario.json"),
            "--prepared",
            str(prepared),
            "--image-id",
            self.image_id,
            "--goal-x",
            str(parameters["goal"]["x"]),
            "--goal-y",
            str(parameters["goal"]["y"]),
        ]
        for option, key in (
            ("--action-budget-sec", "action_budget_sec"),
            ("--application-timeout-sec", "application_timeout_sec"),
            ("--max-pose-error-m", "max_final_pose_error_m"),
            ("--min-displacement-m", "min_displacement_m"),
            ("--max-observation-age-sec", "max_observation_age_sec"),
            ("--odometry-frame", "odometry_frame"),
        ):
            argv.extend([option, str(parameters[key])])
        for edge in parameters["required_tf_edges"]:
            argv.extend(["--required-tf-edge", *edge])
        with (
            patch.dict(os.environ, {"NAV2_IMAGE_CONFIG_ID": self.image_id}),
            patch.object(sys, "argv", argv),
            patch.dict(
                main.__globals__,
                {
                    "admit_workload": admit,
                    "load_ros": load_ros,
                    "readiness_parameters": readiness,
                },
            ),
            self.assertRaises(BeforeRosUse),
        ):
            main()

    def test_cli_diagnostics_and_identifier_responses_are_bounded(self):
        import subprocess
        from unittest.mock import patch

        snapshot = self.root / "bounded-cli"
        snapshot.mkdir(mode=0o700)

        def refusal(arguments, **options):
            self.assertNotIn("capture_output", options)
            self.assertNotEqual(options["stdout"], subprocess.PIPE)
            self.assertNotEqual(options["stderr"], subprocess.PIPE)
            options["stdout"].write(b"STDOUT_NOT_LOGGED" * 10000)
            options["stderr"].write(
                b"error: $.runtime.profile differs from scenario\n"
                + b"x" * 8192
                + b"DIAGNOSTIC_TAIL_NOT_LOGGED"
            )
            return subprocess.CompletedProcess(arguments, 2)

        with patch.object(subprocess, "run", side_effect=refusal):
            with self.assertRaises(ValueError) as caught:
                self.module["run_cli"](snapshot, "explain")
        message = str(caught.exception)
        self.assertIn("$.runtime.profile", message)
        self.assertIn("exit 2", message)
        self.assertIn("[diagnostic truncated]", message)
        self.assertNotIn("STDOUT_NOT_LOGGED", message)
        self.assertNotIn("DIAGNOSTIC_TAIL_NOT_LOGGED", message)
        self.assertLess(len(message), 4352)

        def oversized(arguments, **options):
            options["stdout"].write(b"x" * 8192)
            return subprocess.CompletedProcess(arguments, 0)

        with patch.object(subprocess, "run", side_effect=oversized):
            self.assertEqual(self.module["run_cli"](snapshot, "explain"), "")
            with self.assertRaisesRegex(ValueError, "output exceeded its byte limit"):
                self.module["run_cli"](snapshot, "create-run")


if __name__ == "__main__":
    unittest.main()
