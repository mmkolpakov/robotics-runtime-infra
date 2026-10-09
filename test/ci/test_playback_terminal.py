"""Check retained native player termination before cleanup admission."""

import copy
import importlib.util
import json
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
SPEC = importlib.util.spec_from_file_location(
    "playback_provider", ROOT / "scripts/ci/integration/create-playback-provider.py"
)
PROVIDER = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(PROVIDER)


class NativePlayerTerminal(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="native-player-terminal-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)
        self.identifier = "c" * 64
        self.image = "sha256:" + "d" * 64
        self.command = ["ros2", "bag", "play", "--input", "/datasets/bag", "mcap"]
        self.configuration = {
            "terminal_observation": "native-player-exit",
            "playback_command": self.command,
            "expected_playback_image_id": self.image,
        }
        self.before = {
            "Id": self.identifier,
            "Image": self.image,
            "RestartCount": 0,
            "Config": {
                "Cmd": self.command,
                "Labels": {
                    "com.docker.compose.project": "owned-playback",
                    "com.docker.compose.service": "playback",
                },
            },
            "State": {
                "Status": "running",
                "Running": True,
                "ExitCode": 0,
                "OOMKilled": False,
                "Dead": False,
            },
        }
        self.after = copy.deepcopy(self.before)
        self.after["State"].update(Status="exited", Running=False)
        self.receipt = {
            "container_id": self.identifier,
            "project": "owned-playback",
            "deadline_seconds": 75,
            "wait_client_exit_code": 0,
            "player_logs_exit_code": 0,
            "reported_player_exit_code": "0",
            "stop_requested_before_wait": False,
            "command": [
                "timeout",
                "--foreground",
                "75",
                "docker",
                "wait",
                self.identifier,
            ],
        }
        (self.root / "player-wait.stdout").write_bytes(b"0\n")

    def inspect(self):
        for name, value in (
            ("player-before-wait.json", [self.before]),
            ("player-after-wait.json", [self.after]),
            ("player-terminal.json", self.receipt),
        ):
            (self.root / name).write_text(json.dumps(value))
        return PROVIDER.checked_terminal(self.root, self.configuration)

    def test_terminal_refs_are_required_and_nonzero_originals_stay_unaccepted(self):
        self.assertEqual(self.inspect(), PROVIDER.TERMINAL_FACT_FILES)
        original = copy.deepcopy(self.after)
        self.after["State"]["ExitCode"] = 17
        with self.assertRaisesRegex(ValueError, "terminate successfully"):
            self.inspect()
        self.assertEqual(self.after["State"]["ExitCode"], 17)
        self.after = original

    def test_foreign_identity_changed_command_oom_and_restart_refuse(self):
        cases = [
            ("foreign ID", lambda: self.after.update(Id="e" * 64)),
            (
                "foreign owner",
                lambda: self.after["Config"]["Labels"].update(
                    {"com.docker.compose.project": "foreign"}
                ),
            ),
            ("changed command", lambda: self.after["Config"].update(Cmd=["true"])),
            ("OOM", lambda: self.after["State"].update(OOMKilled=True)),
            ("restart", lambda: self.after.update(RestartCount=1)),
        ]
        baseline = copy.deepcopy(self.after)
        for name, change in cases:
            with self.subTest(name=name):
                self.after = copy.deepcopy(baseline)
                change()
                with self.assertRaises(ValueError):
                    self.inspect()

    def test_wait_refusal_timeout_stop_and_wrong_process_refuse(self):
        cases = [
            {"wait_client_exit_code": 124},
            {"reported_player_exit_code": "137"},
            {"stop_requested_before_wait": True},
            {"deadline_seconds": 0},
            {"wait_client_exit_code": False},
            {"command": ["docker", "wait", "e" * 64]},
        ]
        baseline = dict(self.receipt)
        for change in cases:
            with self.subTest(change=change):
                self.receipt = {**baseline, **change}
                with self.assertRaises(ValueError):
                    self.inspect()

    def test_running_player_empty_wait_and_looping_command_refuse(self):
        self.after["State"].update(Status="running", Running=True)
        with self.assertRaises(ValueError):
            self.inspect()
        self.after["State"].update(Status="exited", Running=False)
        (self.root / "player-wait.stdout").write_bytes(b"")
        with self.assertRaises(ValueError):
            self.inspect()
        (self.root / "player-wait.stdout").write_bytes(b"0\n")
        self.command.append("--loop")
        with self.assertRaisesRegex(ValueError, "looping"):
            self.inspect()

    def test_wait_requires_one_canonical_zero_line(self):
        for raw in (b"0", b"0\n"):
            (self.root / "player-wait.stdout").write_bytes(raw)
            self.assertEqual(self.inspect(), PROVIDER.TERMINAL_FACT_FILES)
        for raw in (b"0\n\n", b"0\r\n", b"00\n", b"0\n1\n", b" 0\n"):
            with self.subTest(raw=raw):
                (self.root / "player-wait.stdout").write_bytes(raw)
                with self.assertRaises(ValueError):
                    self.inspect()

    def test_controlled_stop_profile_without_terminal_request_makes_no_eof_claim(self):
        self.assertEqual(PROVIDER.checked_terminal(self.root, {}), ())


if __name__ == "__main__":
    unittest.main()
