"""Exercise filesystem admission with real contract roles and exact artifact bytes."""

from __future__ import annotations

import copy
import importlib.util
import json
import shutil
import subprocess
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
from importlib.machinery import SourceFileLoader
from pathlib import Path

from robotics_acceptance_harness.extension_schemas import load_extension_schemas
from robotics_runtime_contracts import (
    ContractError,
    ExtensionValidationError,
    file_sha256,
    load_mapping,
    validate_role,
)

ROOT = Path(__file__).resolve().parents[2]
LOADER = SourceFileLoader(
    "robot_description", str(ROOT / "docker/runtime/admit-robot-description")
)
SPEC = importlib.util.spec_from_loader(LOADER.name, LOADER)
assert SPEC is not None and SPEC.loader is not None
admission = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(admission)


class RobotDescriptionTests(unittest.TestCase):
    def setUp(self) -> None:
        temporary = tempfile.TemporaryDirectory(prefix="robot-admission-")
        self.addCleanup(temporary.cleanup)
        self.work = Path(temporary.name)
        self.product = self.work / "producer"
        self.package = "ros/robotics_runtime_infra"
        self.description = f"{self.package}/description/neutral_robot.urdf"
        self.manifest_path = "sim/robot-description.json"
        self.write(
            self.description,
            (
                ROOT
                / "ros_ws/src/robotics_runtime_infra/description/neutral_robot.urdf"
            ).read_bytes(),
        )
        self.write(
            f"{self.package}/package.xml",
            (ROOT / "ros_ws/src/robotics_runtime_infra/package.xml").read_bytes(),
        )
        artifact = {"path": self.description, "sha256": self.digest(self.description)}
        self.manifest = {
            "schema_version": "robot-description.v1",
            "robot_id": "org.example.admission.neutral",
            "source": dict(artifact),
            "package": {"name": "robotics_runtime_infra", "path": self.package},
            "description": {"format": "urdf", **artifact},
            "meshes": [],
            "mass_kg": 1.25,
            "center_of_mass_m": [0.04, 0, 0],
            "inertia_check": {"status": "passed"},
            "spawn": {"frame": "world", "pose": [0, 0, 0, 0, 0, 0]},
        }
        self.scenario = load_mapping(ROOT / "examples/minimal-consumer/scenario.yaml")
        self.scenario_path = self.work / "scenario.json"
        self.repin()
        validate_role(self.manifest, "robot_description")
        validate_role(self.scenario, "acceptance_scenario")
        self.assertTrue(self.admit()["selected"])

    def write(self, relative: str, raw: bytes) -> None:
        path = self.product / relative
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)

    def digest(self, relative: str) -> str:
        return file_sha256(self.product / relative)

    def repin(self) -> None:
        self.write(
            self.manifest_path, (json.dumps(self.manifest, indent=2) + "\n").encode()
        )
        self.scenario.setdefault("workload", {})["robot_description_sha256"] = (
            self.digest(self.manifest_path)
        )
        self.scenario_path.write_text(json.dumps(self.scenario), encoding="utf-8")

    def admit(
        self,
        manifest: str | None = "sim/robot-description.json",
        artifacts: list[str] | None = None,
        extension_schemas: dict[str, bytes] | None = None,
    ) -> dict:
        return admission.admit(
            self.product,
            self.scenario_path,
            manifest,
            artifacts or [],
            extension_schemas=extension_schemas,
        )

    def use_distinct_source_and_meshes(self) -> None:
        source = f"{self.package}/source/neutral_robot.urdf"
        self.write(source, (self.product / self.description).read_bytes())
        self.manifest["source"] = {"path": source, "sha256": self.digest(source)}
        robot = ET.fromstring((self.product / self.description).read_bytes())
        meshes = []
        for index, geometry in enumerate(robot.iter("geometry")):
            if index >= 2:
                break
            relative = f"{self.package}/meshes/part-{index}.stl"
            self.write(
                relative,
                b"solid fixture\nfacet normal 0 0 1\nouter loop\nvertex 0 0 0\nvertex 1 0 0\nvertex 0 1 0\nendloop\nendfacet\nendsolid fixture\n",
            )
            geometry.clear()
            ET.SubElement(
                geometry,
                "mesh",
                filename=f"package://robotics_runtime_infra/meshes/part-{index}.stl",
            )
            meshes.append({"path": relative, "sha256": self.digest(relative)})
        self.write(self.description, ET.tostring(robot, encoding="utf-8"))
        self.manifest["description"]["sha256"] = self.digest(self.description)
        self.manifest["meshes"] = meshes
        self.repin()

    def declare_extension(self) -> tuple[str, Path]:
        uri = "https://schemas.example.org/admission.v1.schema.json"
        schema = {
            "$schema": "https://json-schema.org/draft/2020-12/schema",
            "$id": uri,
            "type": "object",
            "additionalProperties": False,
            "required": ["fixture_name"],
            "properties": {"fixture_name": {"type": "string", "minLength": 1}},
        }
        path = self.work / "extension.schema.json"
        path.write_text(json.dumps(schema), encoding="utf-8")
        for document in (self.scenario, self.manifest):
            document["extension_schemas"] = [
                {
                    "namespace": "org.example.admission",
                    "schema_uri": uri,
                    "sha256": file_sha256(path),
                }
            ]
            document["extensions"] = {
                "org.example.admission": {"fixture_name": "neutral"}
            }
        self.repin()
        return uri, path

    def test_real_extension_registry_validates_both_roles_and_unpinned_scenario(
        self,
    ) -> None:
        uri, path = self.declare_extension()
        registry = load_extension_schemas([f"{uri}={path}"])
        self.assertTrue(self.admit(extension_schemas=registry)["selected"])
        del self.scenario["workload"]
        self.scenario_path.write_text(json.dumps(self.scenario), encoding="utf-8")
        self.assertEqual(self.admit(extension_schemas=registry), {"selected": False})
        self.scenario["extensions"]["org.example.admission"]["fixture_name"] = ""
        self.scenario_path.write_text(json.dumps(self.scenario), encoding="utf-8")
        with self.assertRaises(ExtensionValidationError):
            self.admit(extension_schemas=registry)

    def test_declared_extensions_reject_missing_changed_schema_and_invalid_payload(
        self,
    ) -> None:
        uri, path = self.declare_extension()
        registry = load_extension_schemas([f"{uri}={path}"])
        self.assertTrue(self.admit(extension_schemas=registry)["selected"])
        for supplied in (None, {}, {uri: registry[uri] + b" "}):
            with (
                self.subTest(registry=supplied),
                self.assertRaises(ExtensionValidationError),
            ):
                self.admit(extension_schemas=supplied)
        scenario, manifest = copy.deepcopy(self.scenario), copy.deepcopy(self.manifest)
        for role in ("scenario", "manifest"):
            with self.subTest(role=role):
                self.scenario, self.manifest = (
                    copy.deepcopy(scenario),
                    copy.deepcopy(manifest),
                )
                document = self.scenario if role == "scenario" else self.manifest
                document["extensions"]["org.example.admission"]["fixture_name"] = ""
                self.repin()
                with self.assertRaises(ExtensionValidationError):
                    self.admit(extension_schemas=registry)

    def test_cli_extension_flag_loads_the_actual_schema_file(self) -> None:
        uri, path = self.declare_extension()
        command = [
            sys.executable,
            "-I",
            str(ROOT / "docker/runtime/admit-robot-description"),
            "--root",
            str(self.product),
            "--scenario",
            str(self.scenario_path),
            "--manifest",
            self.manifest_path,
        ]
        arguments = ["--extension-schema", f"{uri}={path}"]
        accepted = subprocess.run(
            command + arguments, capture_output=True, text=True, timeout=15, check=False
        )
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertTrue(json.loads(accepted.stdout)["selected"])
        path.write_bytes(path.read_bytes() + b" ")
        for options in (arguments, []):
            with self.subTest(arguments=options):
                rejected = subprocess.run(
                    command + options,
                    capture_output=True,
                    text=True,
                    timeout=15,
                    check=False,
                )
                self.assertNotEqual(rejected.returncode, 0)
                self.assertEqual(rejected.stdout, "")

    def admit_through_artifact_loader(
        self, manifest: str
    ) -> subprocess.CompletedProcess[str]:
        self.write(
            "artifact-arguments.txt",
            f"--artifact\nother_evidence:robot-description={manifest}\n".encode(),
        )
        return subprocess.run(
            [
                "bash",
                "-c",
                (
                    "set -Eeuo pipefail\n"
                    'source "$1"\n'
                    'foundation_load_artifact_arguments "$2" artifact-arguments.txt\n'
                    '"$3" -I "$4" --root "$2" --scenario "$5" '
                    '"${FOUNDATION_ARTIFACT_SOURCE_ARGUMENTS[@]}"'
                ),
                "robot-description-loader-test",
                str(ROOT / "scripts/ci/foundation/lib.sh"),
                self.product.name,
                sys.executable,
                str(ROOT / "docker/runtime/admit-robot-description"),
                str(self.scenario_path),
            ],
            cwd=self.work,
            capture_output=True,
            text=True,
            timeout=15,
            check=False,
        )

    def test_relative_consumer_root_loader_admits_exact_files(self) -> None:
        self.product = self.product.rename(self.work / "producer with spaces")
        accepted = self.admit_through_artifact_loader(self.manifest_path)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        self.assertEqual(json.loads(accepted.stdout), self.admit())

    def test_relative_consumer_root_loader_rejects_lexical_symlink(self) -> None:
        self.product = self.product.rename(self.work / "producer with spaces")
        accepted = self.admit_through_artifact_loader(self.manifest_path)
        self.assertEqual(accepted.returncode, 0, accepted.stderr)
        link = self.product / "sim/linked-description.json"
        link.symlink_to(self.product / self.manifest_path)
        rejected = self.admit_through_artifact_loader("sim/linked-description.json")
        self.assertNotEqual(rejected.returncode, 0)
        self.assertEqual(rejected.stdout, "")
        self.assertIn("symlink", rejected.stderr)

    def test_exact_files_are_admitted_with_source_description_alias_once(self) -> None:
        result = self.admit()
        self.assertTrue(result["selected"])
        self.assertEqual(result["manifest_sha256"], self.digest(self.manifest_path))
        self.assertEqual(result["description_path"], self.description)
        paths = [artifact["path"] for artifact in result["files"]]
        self.assertEqual(
            paths,
            sorted(
                {self.manifest_path, self.description, f"{self.package}/package.xml"}
            ),
        )
        for artifact in result["files"]:
            path = self.product / artifact["path"]
            self.assertEqual(artifact["sha256"], file_sha256(path))
            self.assertEqual(artifact["size_bytes"], len(path.read_bytes()))

    def test_unpinned_scenario_needs_no_robot_artifacts(self) -> None:
        del self.scenario["workload"]
        self.scenario_path.write_text(json.dumps(self.scenario), encoding="utf-8")
        self.assertEqual(
            self.admit("missing.json", ["unparsed inventory"]), {"selected": False}
        )

    def test_manifest_pin_covers_raw_bytes_including_whitespace(self) -> None:
        path = self.product / self.manifest_path
        path.write_bytes(path.read_bytes() + b" \n")
        validate_role(load_mapping(path), "robot_description")
        with self.assertRaises(ValueError):
            self.admit()

    def test_wrong_or_missing_manifest_cannot_be_admitted(self) -> None:
        self.scenario["workload"]["robot_description_sha256"] = "f" * 64
        self.scenario_path.write_text(json.dumps(self.scenario), encoding="utf-8")
        with self.assertRaises(ValueError):
            self.admit()
        with self.assertRaises(OSError):
            self.admit("sim/missing.json")

    def test_real_roles_reject_invalid_manifest_and_scenario(self) -> None:
        self.manifest["mass_kg"] = 0
        self.repin()
        with self.assertRaises(ContractError):
            self.admit()
        self.scenario["workload"]["robot_description_sha256"] = "invalid digest"
        self.scenario_path.write_text(json.dumps(self.scenario), encoding="utf-8")
        with self.assertRaises(ContractError):
            self.admit()

    def test_native_admission_rejects_unsupported_format_source_and_inertia(
        self,
    ) -> None:
        original = copy.deepcopy(self.manifest)
        variants = [
            {"description": {**original["description"], "format": "sdf"}},
            {
                "source": {
                    "uri": "https://example.invalid/source.urdf",
                    "sha256": original["source"]["sha256"],
                }
            },
            {"inertia_check": {"status": "not_checked"}},
        ]
        for variant in variants:
            with self.subTest(variant=variant):
                self.manifest = {**copy.deepcopy(original), **variant}
                self.repin()
                validate_role(self.manifest, "robot_description")
                with self.assertRaises(ValueError):
                    self.admit()

    def test_valid_nonzero_spawn_preserves_generic_file_admission(self) -> None:
        self.manifest["spawn"]["pose"] = [1, -2, 0.5, 0, 0.5, 1]
        self.repin()
        validate_role(self.manifest, "robot_description")
        self.assertTrue(self.admit()["selected"])

    def test_missing_or_changed_source_description_and_mesh_are_rejected(self) -> None:
        self.use_distinct_source_and_meshes()
        self.admit()
        for artifact in [
            self.manifest["source"],
            self.manifest["description"],
            *self.manifest["meshes"],
        ]:
            path = self.product / artifact["path"]
            original = path.read_bytes()
            for operation in ("remove", "alter"):
                with self.subTest(path=artifact["path"], operation=operation):
                    if operation == "remove":
                        path.unlink()
                    else:
                        path.write_bytes(original + b"changed")
                    with self.assertRaises((ValueError, OSError)):
                        self.admit()
                    path.write_bytes(original)

    def test_missing_or_invalid_package_xml_is_rejected(self) -> None:
        path = self.product / self.package / "package.xml"
        original = path.read_bytes()
        path.unlink()
        with self.assertRaises(OSError):
            self.admit()
        for raw in (
            b"<package>",
            b"<robot><name>robotics_runtime_infra</name></robot>",
            b"<package><name>foreign_package</name></package>",
        ):
            with self.subTest(xml=raw):
                path.write_bytes(raw)
                with self.assertRaises((ValueError, ET.ParseError)):
                    self.admit()
        path.write_bytes(original)

    def test_malformed_or_wrong_description_xml_is_rejected_after_matching_hash(
        self,
    ) -> None:
        for raw in (
            b"<robot>",
            b'<sdf><link name="base"/></sdf>',
            b'<robot name="empty"/>',
        ):
            with self.subTest(xml=raw):
                self.write(self.description, raw)
                for key in ("source", "description"):
                    self.manifest[key]["sha256"] = self.digest(self.description)
                self.repin()
                with self.assertRaises((ValueError, ET.ParseError)):
                    self.admit()

    def test_contained_and_escaping_file_symlinks_are_rejected(self) -> None:
        path = self.product / self.description
        raw = path.read_bytes()
        for target in (self.product / "saved.urdf", self.work / "outside.urdf"):
            with self.subTest(target=target):
                target.write_bytes(raw)
                path.unlink()
                path.symlink_to(target)
                with self.assertRaises(ValueError):
                    self.admit()
                path.unlink()
                path.write_bytes(raw)

    def test_symlinked_parent_directory_is_rejected(self) -> None:
        original = (self.product / self.description).parent
        hidden = self.product / "hidden-description"
        original.rename(hidden)
        original.symlink_to(hidden, target_is_directory=True)
        with self.assertRaises(ValueError):
            self.admit()

    def test_manifest_outside_root_is_rejected_even_with_matching_bytes(self) -> None:
        outside = self.work / "outside-manifest.json"
        outside.write_bytes((self.product / self.manifest_path).read_bytes())
        with self.assertRaises(ValueError):
            self.admit(str(outside))

    def test_escaping_artifact_path_is_rejected_by_the_public_role(self) -> None:
        self.manifest["source"]["path"] = "../outside.urdf"
        self.repin()
        with self.assertRaises(ContractError):
            self.admit()

    def test_two_meshes_sharing_a_parent_are_preserved(self) -> None:
        self.use_distinct_source_and_meshes()
        result = self.admit()
        paths = [artifact["path"] for artifact in result["files"]]
        for artifact in self.manifest["meshes"]:
            self.assertIn(artifact["path"], paths)
        self.assertEqual(len(paths), len(set(paths)))

    def test_undeclared_mesh_reference_is_rejected(self) -> None:
        self.use_distinct_source_and_meshes()
        self.manifest["meshes"].pop()
        self.repin()
        with self.assertRaises(ValueError):
            self.admit()

    def test_retained_inventory_selects_one_physical_manifest(self) -> None:
        relative = f"other_evidence:robot-description={self.manifest_path}"
        absolute = f"other_evidence:alias={self.product / self.manifest_path}"
        self.assertEqual(self.admit(None, [relative, absolute]), self.admit())
        with self.assertRaises(ValueError):
            self.admit(None, [])
        other = "sim/another-manifest.json"
        self.write(other, (self.product / self.manifest_path).read_bytes())
        with self.assertRaises(ValueError):
            self.admit(None, [relative, f"other_evidence:another={other}"])

    def test_exact_tree_relocation_admits_without_original_producer_directory(
        self,
    ) -> None:
        self.use_distinct_source_and_meshes()
        inventory = [f"other_evidence:robot-description={self.manifest_path}"]
        expected = self.admit(None, inventory)
        relocated = self.work / "retained"
        shutil.copytree(self.product, relocated)
        shutil.rmtree(self.product)
        self.assertFalse(self.product.exists())
        actual = admission.admit(relocated, self.scenario_path, None, inventory)
        self.assertEqual(actual, expected)


if __name__ == "__main__":
    unittest.main()
