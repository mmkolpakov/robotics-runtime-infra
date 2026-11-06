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
            "SIMULATION_IMAGE": "local/source-render-control:fixture",
            "ROBOTICS_DOMAIN_ID": "primary",
            "ROS_DOMAIN_ID": "188",
            "GZ_PARTITION": "render-control",
            "ROBOTICS_METRICS_TOPIC": "/example/sequence",
            "ROBOTICS_PLAYBACK_CLOCK_HZ": "200",
            "ROBOTICS_PLAYBACK_RATE": "1",
            "ROBOTICS_PLAYBACK_START_OFFSET": "0",
        }
        files = [
            "compose.yaml",
            "compose.foundation.yaml",
            "compose.stepped.yaml",
            "compose.record.yaml",
            "compose.evidence.yaml",
            "compose.observability.yaml",
        ]

        profiles = ["stepped", "record", "acceptance", "evidence", "observability"]

        def render(extra=()):
            args = list(renderer)
            for file in files + list(extra):
                args += [
                    "-f",
                    str(root / file) if not Path(file).is_absolute() else file,
                ]
            for profile in profiles:
                args += ["--profile", profile]
            args += ["config", "--format", "json"]
            result = subprocess.run(
                args, cwd=root, env=env, capture_output=True, text=True, timeout=25
            )
            self.assertEqual(result.returncode, 0, result.stderr)
            return json.loads(result.stdout)

        baseline = render()
        diagnostic_overlays = [
            "compose.native-trace.yaml",
            "compose.native-trace-simulation.yaml",
        ]
        diagnostic = render(diagnostic_overlays)
        self.assertEqual(set(diagnostic["services"]), set(baseline["services"]))
        self.assertIn("simulation-stepper", diagnostic["services"])
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
            resolved = render(diagnostic_overlays + [str(program / "compose.json")])
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
            roundtrip = render(diagnostic_overlays + [str(comparison / "compose.json")])
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
            declared_diagnostic = render([str(declared)] + diagnostic_overlays)
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
                [str(declared)]
                + diagnostic_overlays
                + [str(declared_program / "compose.json")]
            )
            assert (
                declared_resolved["services"]["simulation"]["command"]
                == declared_baseline["services"]["simulation"]["command"]
            )

        # Match the recording_playback branch's actual files and active profiles.
        files = [
            "compose.yaml",
            "compose.foundation.yaml",
            "compose.record.yaml",
            "compose.evidence.yaml",
            "compose.observability.yaml",
            "compose.playback.yaml",
            "compose.foundation-playback.yaml",
        ]
        profiles = [
            "playback",
            "test",
            "record",
            "acceptance",
            "evidence",
            "observability",
        ]
        playback_baseline = render()
        playback_diagnostic = render(
            ["compose.native-trace.yaml", "compose.native-trace-playback.yaml"]
        )
        self.assertEqual(
            set(playback_diagnostic["services"]), set(playback_baseline["services"])
        )
        self.assertNotIn("simulation-stepper", playback_diagnostic["services"])
        self.assertEqual(
            playback_diagnostic["services"]["simulation"],
            playback_baseline["services"]["simulation"],
        )
        for actor in ("playback", "runtime-metrics"):
            self.assertEqual(
                playback_diagnostic["services"][actor]["command"],
                ["/bin/bash", "/tmp/ros-native-trace.sh"]
                + playback_baseline["services"][actor]["command"],
            )

    def test_unavailable_ust_preserves_underlying_program_argv_and_exit(self):
        with tempfile.TemporaryDirectory(prefix="trace-wrapper-source-") as temporary:
            directory = Path(temporary)
            # Test-owned paths avoid touching the host's fixed diagnostic directories.
            source = (ROOT / "scripts/ci/diagnostics/ros-native-trace.sh").read_text()
            source = source.replace(
                "/tmp/robotics-native-lttng", str(directory / "lttng")
            )
            source = source.replace("/tmp/robotics-native-ust", str(directory / "ust"))
            for original in ("/tmp/robotics-native-lttng", "/tmp/robotics-native-ust"):
                self.assertNotIn(original, source)
            wrapper = directory / "wrapper.sh"
            wrapper.write_text(source)
            binary = directory / "bin"
            binary.mkdir()
            unavailable = binary / "lttng-sessiond"
            unavailable.write_text("#!/bin/sh\nexit 17\n")
            unavailable.chmod(0o755)
            program = directory / "program"
            output = directory / "argv.txt"
            home_output = directory / "lttng-home.txt"
            program.write_text(
                '#!/bin/sh\nprintf "%s\\n" "$@" >"$ARGV_OUTPUT"\n'
                'printf "%s\\n" "$LTTNG_HOME" >"$LTTNG_HOME_OUTPUT"\nexit 42\n'
            )
            program.chmod(0o755)
            arguments = ["argument with spaces", "$literal", "$$", "${NAME}", ""]
            result = subprocess.run(
                ["bash", str(wrapper), str(program), *arguments],
                env={
                    **os.environ,
                    "PATH": str(binary) + ":" + os.environ["PATH"],
                    "ARGV_OUTPUT": str(output),
                    "LTTNG_HOME_OUTPUT": str(home_output),
                },
                capture_output=True,
                text=True,
                timeout=15,
            )
            self.assertEqual(result.returncode, 42)
            self.assertEqual(output.read_text().splitlines(), arguments)
            actual_home = Path(home_output.read_text().strip())
            self.assertEqual(actual_home, directory / "lttng")
            self.assertTrue(actual_home.is_relative_to(directory))
            self.assertIn("diagnostic native UST setup exit: 17", result.stderr)


if __name__ == "__main__":
    unittest.main()
