from __future__ import annotations

import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


class NativeTraceComposeTests(unittest.TestCase):
    def test_stock_renderer_preserves_owned_program_arrays_and_literal_dollars(self):
        root = ROOT
        configured = os.environ.get("ROBOTICS_TEST_COMPOSE_RENDERER")
        renderer = [configured] if configured else ["docker", "compose"]
        env = {
            "PATH": os.environ["PATH"],
            "HOME": os.environ.get("HOME", "/tmp"),
            "ROBOTICS_RUN_ID": "render-control",
            "ROBOTICS_DOMAIN_ID": "primary",
            "ROS_DOMAIN_ID": "188",
            "GZ_PARTITION": "render-control",
        }
        files = [
            "compose.yaml",
            "compose.simulation-health.yaml",
            "compose.stepped.yaml",
            "compose.observability.yaml",
        ]

        def render(extra=()):
            args = list(renderer)
            for file in files + list(extra):
                args += [
                    "-f",
                    str(root / file) if not Path(file).is_absolute() else file,
                ]
            args += [
                "--profile",
                "stepped",
                "--profile",
                "observability",
                "--profile",
                "acceptance",
                "config",
                "--format",
                "json",
            ]
            result = subprocess.run(
                args, cwd=root, env=env, capture_output=True, text=True, timeout=25
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

        baseline = render()
        diagnostic = render(["compose.native-trace.yaml"])
        image_default = [
            "python3",
            "-m",
            "actual_image_default_fixture",
            "argument with spaces",
            "$literal",
            "$$",
            "${NAME}",
            "",
        ]
        with tempfile.TemporaryDirectory(prefix="diagnostic-render-") as temporary:
            directory = Path(temporary)
            model = directory / "model.json"
            model.write_text(json.dumps(diagnostic))
            image_id = "sha256:" + "7" * 64
            image = directory / "image.json"
            image.write_text(
                json.dumps(
                    {
                        "image_id": image_id,
                        "command": image_default,
                        "image_entrypoint": ["/usr/local/bin/robotics-entrypoint"],
                    }
                )
            )
            fake = directory / "docker"
            fake.write_text('#!/bin/sh\ncat "$TRACE_IMAGE_INFO"\n')
            fake.chmod(0o755)
            helper_env = {
                **env,
                "TRACE_IMAGE_INFO": str(image),
                "PATH": str(directory) + ":" + env["PATH"],
            }
            program = directory / "program"
            subprocess.run(
                [
                    "bash",
                    str(
                        root
                        / "scripts/ci/diagnostics/prepare-simulation-trace-command.sh"
                    ),
                    str(model),
                    image_id,
                    str(program),
                ],
                env=helper_env,
                check=True,
                capture_output=True,
                text=True,
            )
            original = json.loads((program / "program.json").read_text())
            assert original["command"] == image_default
            resolved = render(
                ["compose.native-trace.yaml", str(program / "compose.json")]
            )
            assert baseline["services"]["simulation"].get("command") is None
            resolved_model = directory / "resolved-model.json"
            resolved_model.write_text(json.dumps(resolved))
            comparison = directory / "comparison"
            subprocess.run(
                [
                    "bash",
                    str(
                        root
                        / "scripts/ci/diagnostics/prepare-simulation-trace-command.sh"
                    ),
                    str(resolved_model),
                    image_id,
                    str(comparison),
                ],
                env=helper_env,
                check=True,
                capture_output=True,
                text=True,
            )
            comparable = json.loads((comparison / "program.json").read_text())
            assert comparable["command"] == image_default
            roundtrip = render(
                ["compose.native-trace.yaml", str(comparison / "compose.json")]
            )
            assert (
                roundtrip["services"]["simulation"]["command"]
                == resolved["services"]["simulation"]["command"]
            )
            assert (
                baseline["services"]["simulation-stepper"]["command"]
                == resolved["services"]["simulation-stepper"]["command"]
            )
            expected_wrapper = [
                "/usr/local/bin/robotics-entrypoint",
                "/bin/bash",
                "/tmp/ros-native-trace.sh",
            ]
            assert all(
                resolved["services"][service]["entrypoint"] == expected_wrapper
                for service in ("simulation", "simulation-stepper")
            )

            declared = directory / "declared.json"
            declared.write_text(
                json.dumps(
                    {
                        "services": {
                            "simulation": {
                                "command": ["declared", "argument with spaces"]
                            }
                        }
                    }
                )
            )
            declared_baseline = render([str(declared)])
            declared_diagnostic = render([str(declared), "compose.native-trace.yaml"])
            assert (
                declared_baseline["services"]["simulation"]["command"]
                == declared_diagnostic["services"]["simulation"]["command"]
            )
            declared_model = directory / "declared-model.json"
            declared_model.write_text(json.dumps(declared_diagnostic))
            declared_program = directory / "declared-program"
            subprocess.run(
                [
                    "bash",
                    str(
                        root
                        / "scripts/ci/diagnostics/prepare-simulation-trace-command.sh"
                    ),
                    str(declared_model),
                    image_id,
                    str(declared_program),
                ],
                env=helper_env,
                check=True,
                capture_output=True,
                text=True,
            )
            declared_resolved = render(
                [
                    str(declared),
                    "compose.native-trace.yaml",
                    str(declared_program / "compose.json"),
                ]
            )
            assert (
                declared_resolved["services"]["simulation"]["command"]
                == declared_baseline["services"]["simulation"]["command"]
            )

    def test_unavailable_ust_preserves_underlying_program_argv_and_exit(self):
        with tempfile.TemporaryDirectory(prefix="trace-wrapper-source-") as temporary:
            directory = Path(temporary)
            # Test-owned paths avoid touching the host's fixed diagnostic directories.
            source = (ROOT / "scripts/ci/diagnostics/ros-native-trace.sh").read_text()
            source = source.replace("/tmp/robotics-lttng", str(directory / "lttng"))
            source = source.replace("/tmp/robotics-native-ust", str(directory / "ust"))
            wrapper = directory / "wrapper.sh"
            wrapper.write_text(source)
            binary = directory / "bin"
            binary.mkdir()
            unavailable = binary / "lttng-sessiond"
            unavailable.write_text("#!/bin/sh\nexit 17\n")
            unavailable.chmod(0o755)
            program = directory / "program"
            output = directory / "argv.txt"
            program.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$@" >"$ARGV_OUTPUT"\nexit 42\n'
            )
            program.chmod(0o755)
            arguments = ["argument with spaces", "$literal", "$$", "${NAME}", ""]
            result = subprocess.run(
                ["bash", str(wrapper), str(program), *arguments],
                env={
                    **os.environ,
                    "PATH": str(binary) + ":" + os.environ["PATH"],
                    "ARGV_OUTPUT": str(output),
                },
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 42)
            self.assertEqual(output.read_text().splitlines(), arguments)
            self.assertIn("diagnostic native UST setup exit: 17", result.stderr)


if __name__ == "__main__":
    unittest.main()
