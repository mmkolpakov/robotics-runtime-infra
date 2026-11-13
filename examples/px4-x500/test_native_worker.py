"""Source-only controls: importing or executing the native SDK is forbidden."""

import atexit
import hashlib
import shutil
import io
from contextlib import redirect_stderr
import importlib.abc
import importlib.util
import json
import os
from enum import IntEnum
from pathlib import Path
import sys
import tempfile
from types import SimpleNamespace
import unittest
from unittest.mock import patch


class NoNative(importlib.abc.MetaPathFinder):
    def find_spec(self, fullname, path=None, target=None):
        if fullname == "mavsdk" or fullname.startswith("mavsdk."):
            raise AssertionError("native SDK import forbidden in source unit controls")
        return None


sys.meta_path.insert(0, NoNative())
_source = Path(__file__).parent
_sibling_fixture = tempfile.TemporaryDirectory(prefix="px4-worker-import-")
atexit.register(_sibling_fixture.cleanup)
_sibling_root = Path(_sibling_fixture.name)
shutil.copyfile(_source / "native_worker.py", _sibling_root / "native_worker.py")
shutil.copyfile(
    _source / "evaluator/src/px4_x500_evaluator/_px4_listener.py",
    _sibling_root / "_px4_listener.py",
)
spec = importlib.util.spec_from_file_location(
    "native_worker", _sibling_root / "native_worker.py"
)
worker = importlib.util.module_from_spec(spec)
sys.path.insert(0, str(_sibling_root))
try:
    spec.loader.exec_module(worker)
finally:
    sys.path.remove(str(_sibling_root))
RUN = "run-12345678-1234-4123-8123-123456789abc"


class Result(IntEnum):
    SUCCESS = 1
    TIMEOUT = 8


class ActionError(Exception):
    def __init__(self, result):
        self.result = result
        super().__init__(result.name)


class Clock:
    def __init__(self):
        self.value = 0

    def now(self):
        self.value += 0.01
        return self.value

    def sleep(self, seconds):
        self.value += seconds * 1000


def status(timestamp=1000000, state=1, system=1, component=1, age="0.100000"):
    return f"\nTOPIC: vehicle_status\n vehicle_status\n    timestamp: {timestamp} ({age} seconds ago)\n    arming_state: {state}\n    system_id: {system}\n    component_id: {component}\n"


def land(timestamp=1500000, landed=True):
    return f"\nTOPIC: vehicle_land_detected\n vehicle_land_detected\n    timestamp: {timestamp} (0.100000 seconds ago)\n    landed: {landed}\n"


class Scenario:
    def __init__(self, path, journal_type=worker.Journal):
        self.clock = Clock()
        self.journal = journal_type(
            path, RUN, monotonic=self.clock.now, unix_ms=lambda: 1700000000000
        )
        self.config = {
            "owner_id": RUN,
            "instance": 0,
            "target_system_id": 1,
            "target_component_id": 1,
            "source_system_id": 245,
            "source_component_id": 190,
        }
        self.identity = {
            key: self.config[key]
            for key in (
                "target_system_id",
                "target_component_id",
                "source_system_id",
                "source_component_id",
            )
        }
        self.identity["discovered_system_ids"] = [1]
        self.actor = {
            "pid": 42,
            "start_ticks": "1234",
            "executable": worker.PX4,
            "executable_sha256": "a" * 64,
            "instance": 0,
        }
        self.armed = False
        self.altitude = 0.0
        self.home = True
        self.armable = True
        self.calls = []
        self.failure = None
        self.listener_calls = 0
        self.bad_initial = None
        self.bad_final = False
        self.fixed_time = False
        self.actor_changed = False
        self.in_action = False
        self.stop = False
        self.telemetry = SimpleNamespace(
            health=lambda: SimpleNamespace(
                is_armable=self.armable,
                is_local_position_ok=True,
                is_global_position_ok=True,
                is_home_position_ok=self.home,
            ),
            armed=lambda: self.armed,
            position=lambda: SimpleNamespace(relative_altitude_m=self.altitude),
            landed_state=lambda: SimpleNamespace(
                name="IN_AIR" if self.armed else "ON_GROUND"
            ),
        )
        self.action = SimpleNamespace(
            arm=lambda: self.call("arm"),
            takeoff=lambda: self.call("takeoff"),
            land=lambda: self.call("land"),
        )

    def call(self, method):
        if self.in_action:
            raise AssertionError("overlapping action")
        self.in_action = True
        try:
            records = self.records()
            issued = records[-1]
            assert issued["kind"] == "action-issued"
            assert issued["value"]["method"] == method
            assert (
                (self.journal.output / self.journal.records[-1]["path"])
                .read_bytes()
                .endswith(b"\n")
            )
            self.calls.append(method)
            if method == self.failure:
                raise ActionError(Result.TIMEOUT)
            if method == "arm":
                self.armed = True
            if method == "takeoff":
                self.altitude = 2.0
            if method == "land":
                self.armed = False
                self.altitude = 0
            return Result.SUCCESS
        finally:
            self.in_action = False

    def listener(self, topic, instance, budget):
        self.listener_calls += 1
        stamp = 1000000 if self.fixed_time else 1000000 * self.listener_calls
        text = (
            status(stamp, 2 if self.armed else 1)
            if topic == "vehicle_status"
            else land(stamp)
        )
        if self.bad_initial and self.listener_calls == 1:
            text = self.bad_initial
        if self.bad_final and self.listener_calls >= 4:
            text = "never published\n"
        return {
            "argv": [worker.LISTENER, "--instance", str(instance), topic, "-n", "1"],
            "returncode": 0,
            "stdout": text,
            "stderr": "",
            "host_started_monotonic_ms": self.clock.now(),
            "host_finished_monotonic_ms": self.clock.now(),
        }

    def actor_probe(self, config):
        return (
            {**self.actor, "start_ticks": "9999"}
            if self.actor_changed
            else self.actor.copy()
        )

    def records(self):
        return [
            json.loads((self.journal.output / item["path"]).read_bytes())
            for item in self.journal.records
        ]

    def run(self, name="land"):
        return worker.run_case(
            name,
            self.config,
            self.journal,
            self.telemetry,
            self.action,
            self.identity,
            listener=self.listener,
            actor_probe=self.actor_probe,
            monotonic=self.clock.now,
            sleep=self.clock.sleep,
            stopped=lambda: self.stop,
            action_error=ActionError,
        )


class ListenerTests(unittest.TestCase):
    def test_exact_source_integer_preserved(self):
        parsed = worker.parse_listener(status(9007199254740993), "vehicle_status")
        self.assertEqual(parsed["timestamp_us"], "9007199254740993")

    def test_missing_duplicate_multiple_stale_invalid(self):
        cases = [
            "never published\n",
            status().replace("timestamp: 1000000", "timestamp: 0"),
            status() + "    system_id: 1\n",
            status().replace(
                "TOPIC: vehicle_status", "TOPIC: vehicle_status 2 instances"
            ),
            status(age="1.000000"),
            status(age="nan"),
            status(state=0),
            status().replace("system_id: 1", "system_id: nope"),
            status() + status(),
            status(1 << 64),
        ]
        for text in cases:
            with self.subTest(text=text), self.assertRaises(worker.Refused):
                worker.parse_listener(text, "vehicle_status")

    def test_bool_requires_native_case_and_complete_field(self):
        self.assertTrue(
            worker.parse_listener(land(), "vehicle_land_detected")["landed"]
        )
        with self.assertRaises(worker.Refused):
            worker.parse_listener(
                land().replace("True", "true"), "vehicle_land_detected"
            )

    def test_print_precision_margin(self):
        self.assertEqual(
            worker.parse_listener(status(age="0.999999"), "vehicle_status")["age_s"],
            0.999999,
        )
        with self.assertRaises(worker.Refused):
            worker.parse_listener(
                status(age="0.999999"), "vehicle_status", maximum_age_s=0.9999994
            )


class WorkerTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.scenario = Scenario(Path(self.tmp.name) / "capture")

    def test_land_serial_actions_and_unknown_physical_result(self):
        self.assertTrue(self.scenario.run())
        self.assertEqual(self.scenario.calls, ["arm", "takeoff", "land"])
        records = self.scenario.records()
        self.assertEqual(records[-1]["value"]["physical_outcome"], "unknown")
        self.assertEqual(
            [
                r["value"]["invocation_id"]
                for r in records
                if r["kind"] == "action-issued"
            ],
            ["action-0001", "action-0002", "action-0003"],
        )
        self.assertTrue(self.scenario.journal.closed)

    def test_refusal_has_no_mutations_and_strict_brackets(self):
        self.assertTrue(self.scenario.run("unarmed-refusal"))
        self.assertEqual(self.scenario.calls, [])
        records = self.scenario.records()
        first = next(r for r in records if r["value"].get("slot") == "initial-status-b")
        refusal = next(r for r in records if r["kind"] == "caller-refusal")
        last = next(r for r in records if r["value"].get("slot") == "final-status")
        self.assertLess(first["sequence"], refusal["sequence"])
        self.assertLess(refusal["sequence"], last["sequence"])
        self.assertLess(
            first["receiver_monotonic_ms"], refusal["receiver_monotonic_ms"]
        )
        self.assertLess(refusal["receiver_monotonic_ms"], last["receiver_monotonic_ms"])

    def test_missing_home_refuses_measurement_without_arm_or_takeoff(self):
        self.scenario.home = False
        self.assertFalse(self.scenario.run("unarmed-refusal"))
        self.assertEqual(self.scenario.calls, [])
        self.assertFalse(
            any(r["kind"] == "caller-refusal" for r in self.scenario.records())
        )
        self.assertFalse(
            any(
                r["value"].get("slot", "").startswith("initial-")
                for r in self.scenario.records()
            )
        )

    def test_valid_home_refusal_does_not_require_armable(self):
        self.scenario.armable = False
        self.assertTrue(self.scenario.run("unarmed-refusal"))
        self.assertEqual(self.scenario.calls, [])
        self.assertTrue(
            any(r["kind"] == "caller-refusal" for r in self.scenario.records())
        )

    def test_mutating_case_still_requires_armable_before_phase(self):
        self.scenario.armable = False
        self.assertFalse(self.scenario.run("land"))
        self.assertEqual(self.scenario.calls, [])
        self.assertFalse(
            any(
                r["value"].get("slot", "").startswith("initial-")
                for r in self.scenario.records()
            )
        )

    def test_stalled_source_clock_and_wrong_actor_refuse(self):
        self.scenario.fixed_time = True
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])

    def test_zero_exit_never_published_refuses(self):
        self.scenario.bad_initial = "never published\n"
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])

    def test_multiple_sdk_actors_refuse(self):
        self.scenario.identity["discovered_system_ids"] = [1, 2]
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])

    def test_sender_boolean_is_not_integer_identity(self):
        self.scenario.identity["target_system_id"] = True
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])

    def test_action_error_retains_native_enum_and_settles_serially(self):
        self.scenario.failure = "takeoff"
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, ["arm", "takeoff", "land"])
        failure = next(
            r["value"] for r in self.scenario.records() if r["kind"] == "action-error"
        )
        self.assertEqual(failure["sdk_result"], {"name": "TIMEOUT", "value": 8})
        self.assertEqual(failure["physical_outcome"], "unknown")

    def test_application_deadline_follows_ascent_then_lands(self):
        self.assertTrue(self.scenario.run("application-deadline"))
        records = self.scenario.records()
        boundary = next(r for r in records if r["kind"] == "application-deadline")
        self.assertGreaterEqual(
            boundary["value"]["observed_monotonic_ms"]
            - boundary["value"]["started_monotonic_ms"],
            2000,
        )
        takeoff = next(r for r in records if r["kind"] == "action-takeoff")
        landed = next(r for r in records if r["kind"] == "action-land")
        self.assertLess(takeoff["sequence"], boundary["sequence"])
        self.assertLess(boundary["sequence"], landed["sequence"])

    def test_preland_evidence_failure_does_not_suppress_serial_settlement(self):
        self.scenario.bad_final = True
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, ["arm", "takeoff", "land"])

    def test_late_durable_issuance_refuses_dispatch(self):
        original = self.scenario.journal.retain

        def delayed(kind, value):
            result = original(kind, value)
            if (
                kind == "listener-observation"
                and value.get("slot") == "initial-status-b"
            ):
                self.scenario.clock.sleep(2)
            return result

        self.scenario.journal.retain = delayed
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])

    def test_slow_listener_counts_full_duration_before_arm(self):
        original = self.scenario.listener

        def slow(topic, instance, budget):
            result = original(topic, instance, budget)
            if self.scenario.listener_calls == 1:
                self.scenario.clock.sleep(0.4)
                result["host_finished_monotonic_ms"] = self.scenario.clock.now()
            return result

        self.scenario.listener = slow
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])
        self.assertTrue(
            any(
                r["value"].get("slot") == "initial-status-a"
                for r in self.scenario.records()
            )
        )

    def test_slow_durable_issuance_is_checked_after_write(self):
        original = self.scenario.journal.retain

        def slow(kind, value):
            result = original(kind, value)
            if kind == "action-issued":
                self.scenario.clock.sleep(0.4)
            return result

        self.scenario.journal.retain = slow
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])
        self.assertTrue(
            any(r["kind"] == "action-issued" for r in self.scenario.records())
        )

    def test_slow_post_issuance_process_validation_is_counted(self):
        original = self.scenario.actor_probe

        def slow(config):
            if (
                self.scenario.journal.records
                and self.scenario.records()[-1]["kind"] == "action-issued"
            ):
                self.scenario.clock.sleep(0.4)
            return original(config)

        self.scenario.actor_probe = slow
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])

    def test_dispatch_anchor_includes_durable_issuance_delay(self):
        original = self.scenario.journal.retain

        def slow(kind, value):
            result = original(kind, value)
            if kind == "action-issued":
                self.scenario.clock.sleep(0.1)
            return result

        self.scenario.journal.retain = slow
        self.assertTrue(self.scenario.run())
        records = self.scenario.records()
        issued = next(r for r in records if r["kind"] == "action-issued")
        result = next(r for r in records if r["kind"] == "action-arm")
        self.assertGreaterEqual(
            result["value"]["dispatch_monotonic_ms"] - issued["value"]["monotonic_ms"],
            100,
        )
        self.assertLess(
            result["value"]["dispatch_monotonic_ms"], result["receiver_monotonic_ms"]
        )

    def test_missing_final_source_bound_is_incomplete(self):
        self.scenario.bad_final = True
        self.assertFalse(self.scenario.run("unarmed-refusal"))
        self.assertEqual(self.scenario.calls, [])

    def test_parent_stop_before_mutation(self):
        self.scenario.stop = True
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])

    def test_durable_write_failure_prevents_dispatch(self):
        original = self.scenario.journal.retain

        def fail(kind, value):
            if kind == "action-issued":
                raise OSError("disk refused durable issuance")
            return original(kind, value)

        self.scenario.journal.retain = fail
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])

    def test_actor_changes_refuse_before_native_dispatch(self):
        original = self.scenario.actor_probe
        count = 0

        def changed(config):
            nonlocal count
            count += 1
            result = original(config)
            return {**result, "start_ticks": "9999"} if count > 1 else result

        self.scenario.actor_probe = changed
        self.assertFalse(self.scenario.run())
        self.assertEqual(self.scenario.calls, [])


class FreshnessBudgetTests(unittest.TestCase):
    def observations(self):
        return {
            slot: {
                "host_started_monotonic_ms": 100,
                "host_finished_monotonic_ms": 200,
                "parsed": {"age_s": 0.1},
            }
            for slot in ("initial-status-a", "initial-land", "initial-status-b")
        }

    def test_each_initial_observation_must_meet_combined_budget(self):
        for slot in self.observations():
            with self.subTest(slot=slot):
                values = self.observations()
                values[slot]["parsed"]["age_s"] = 0.9
                with self.assertRaises(worker.Refused):
                    worker.check_initial_freshness(values, 300)
        worker.check_initial_freshness(self.observations(), 300)

    def test_rounding_margin_and_full_listener_duration(self):
        values = self.observations()
        for value in values.values():
            value["parsed"]["age_s"] = 0.799999
        worker.check_initial_freshness(values, 300)
        with self.assertRaises(worker.Refused):
            worker.check_initial_freshness(values, 300.0006)

    def test_missing_or_unordered_observation_cannot_be_fresh(self):
        values = self.observations()
        del values["initial-land"]
        with self.assertRaises(worker.Refused):
            worker.check_initial_freshness(values, 300)
        values = self.observations()
        values["initial-status-a"]["host_finished_monotonic_ms"] = 301
        with self.assertRaises(worker.Refused):
            worker.check_initial_freshness(values, 300)


class JournalTests(unittest.TestCase):
    def test_fsync_precedes_dispatch_and_original_bytes_match_manifest(self):
        with tempfile.TemporaryDirectory() as directory:
            scenario = Scenario(Path(directory) / "capture")
            calls = []
            original_fsync = os.fsync
            original_call = scenario.call

            def sync(fd):
                calls.append("fsync")
                return original_fsync(fd)

            def call(method):
                self.assertEqual(calls[-1], "fsync")
                calls.append(method)
                return original_call(method)

            scenario.call = call
            with patch.object(worker.os, "fsync", sync):
                self.assertTrue(scenario.run())
            manifest = json.loads(
                (scenario.journal.output / "controller-manifest.json").read_bytes()
            )
            self.assertEqual(
                manifest["total_bytes"],
                sum(item["size_bytes"] for item in manifest["records"]),
            )
            for item in manifest["records"]:
                raw = (scenario.journal.output / item["path"]).read_bytes()
                self.assertEqual(hashlib.sha256(raw).hexdigest(), item["sha256"])
                self.assertEqual(len(raw), item["size_bytes"])
            self.assertEqual(manifest["started_unix_ns"], "1700000000000000000")

    def test_exclusive_directory_and_nonfinite_payload_rejected(self):
        with tempfile.TemporaryDirectory() as directory:
            path = Path(directory) / "capture"
            journal = worker.Journal(path, RUN)
            with self.assertRaises(FileExistsError):
                worker.Journal(path, RUN)
            with self.assertRaises(ValueError):
                journal.retain("bad", {"value": float("nan")})
            self.assertEqual(journal.records, [])

    def test_record_budget_rejects_before_creating_record(self):
        with tempfile.TemporaryDirectory() as directory:
            journal = worker.Journal(Path(directory) / "capture", RUN)
            with self.assertRaises(worker.Refused):
                journal.retain("oversize", {"value": "x" * 1048576})
            self.assertEqual(list(journal.output.iterdir()), [])


class ActorConfigTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.path = Path(self.tmp.name) / "actor.json"
        self.payload = json.dumps({"owner_id": RUN}).encode()

    def refused_before_sdk(self):
        output = Path(self.tmp.name) / "not-created"
        argv = [
            "native_worker.py",
            "unarmed-refusal",
            "--run-id",
            RUN,
            "--output",
            str(output),
            "--config",
            str(self.path),
        ]
        with (
            patch.object(sys, "argv", argv),
            patch.object(worker, "native_sdk") as native,
        ):
            with (
                redirect_stderr(io.StringIO()),
                self.assertRaises(SystemExit) as stopped,
            ):
                worker.main()
            self.assertEqual(stopped.exception.code, 2)
            native.assert_not_called()
        self.assertFalse(output.exists())

    def test_valid_original_regular_config(self):
        self.path.write_bytes(self.payload)
        self.assertEqual(worker.read_actor_config(self.path, RUN), {"owner_id": RUN})

    def test_fifo_refused_before_sdk_import(self):
        os.mkfifo(self.path)
        self.refused_before_sdk()

    def test_symlink_refused_before_sdk_import(self):
        target = self.path.with_name("original.json")
        target.write_bytes(self.payload)
        self.path.symlink_to(target)
        self.refused_before_sdk()

    def test_oversize_refused_before_read_and_sdk_import(self):
        self.path.write_bytes(b"x" * 32769)
        with patch.object(
            worker.os, "read", side_effect=AssertionError("oversize must not be read")
        ):
            self.refused_before_sdk()

    def test_owner_mismatch_refused_before_sdk_import(self):
        self.path.write_text(json.dumps({"owner_id": "another-owner"}))
        self.refused_before_sdk()

    def test_in_place_mutation_refused_before_sdk_import(self):
        self.path.write_bytes(self.payload)
        original = os.read
        changed = False

        def mutate(descriptor, amount):
            nonlocal changed
            raw = original(descriptor, amount)
            if not changed:
                changed = True
                self.path.write_bytes(self.payload + b" ")
            return raw

        with patch.object(worker.os, "read", mutate):
            self.refused_before_sdk()

    def test_path_replacement_refused_before_sdk_import(self):
        self.path.write_bytes(self.payload)
        original = os.read
        replaced = False

        def replace(descriptor, amount):
            nonlocal replaced
            raw = original(descriptor, amount)
            if not replaced:
                replaced = True
                self.path.rename(self.path.with_name("previous.json"))
                self.path.write_bytes(self.payload)
            return raw

        with patch.object(worker.os, "read", replace):
            self.refused_before_sdk()


class ProcessTests(unittest.TestCase):
    def test_missing_boot_binding_never_guesses(self):
        with self.assertRaises(worker.Refused):
            worker.process_identity({"instance": 0})


class ListenerProcessTests(unittest.TestCase):
    def execute(self, code, budget=1000):
        original = worker.subprocess.Popen

        def child(_argv, **kwargs):
            return original([sys.executable, "-c", code], **kwargs)

        with patch.object(worker.subprocess, "Popen", child):
            return worker.stock_listener("vehicle_status", 3, budget)

    def test_nonzero_child_retains_original_diagnostic(self):
        result = self.execute(
            "import sys;print('never published');print('fault',file=sys.stderr);sys.exit(7)"
        )
        self.assertEqual(result["returncode"], 7)
        self.assertEqual(result["stdout"], "never published\n")
        self.assertEqual(result["stderr"], "fault\n")
        self.assertEqual(result["argv"][1:3], ["--instance", "3"])

    def test_output_cap_retains_only_marked_truncated_prefix(self):
        result = self.execute("import os;os.write(1,b'x'*100000)")
        self.assertIn("truncated", result["error"])
        self.assertEqual(
            len(result["stdout"].encode()) + len(result["stderr"].encode()), 32768
        )

    def test_timeout_settles_only_owned_listener_child(self):
        result = self.execute(
            "import time;print('partial',flush=True);time.sleep(2)", 100
        )
        self.assertIn("budget", result["error"])
        self.assertEqual(result["stdout"], "partial\n")
        self.assertIsNotNone(result["returncode"])

    def test_invalid_utf8_retains_original_hex_and_refuses(self):
        result = self.execute("import os;os.write(1,b'\\xff')")
        self.assertEqual(result["stdout_hex"], "ff")
        self.assertIn("not UTF-8", result["error"])


class ProcessIdentityTests(unittest.TestCase):
    def test_explicit_instance_start_ticks_and_executable_hash(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            proc = root / "42"
            proc.mkdir()
            executable = root / "px4"
            executable.write_bytes(b"fixture executable bytes, not executable")
            (proc / "exe").symlink_to(executable)
            (proc / "cmdline").write_bytes(
                b"\0".join([b"/px4", b"--instance", b"3", b""])
            )
            (proc / "stat").write_text(
                "42 (px4 with spaces) "
                + " ".join(["S"] + ["0"] * 18 + ["1234"] + ["0"] * 3)
            )
            config = {
                "px4_pid": 42,
                "px4_start_ticks": "1234",
                "instance": 3,
                "px4_executable_sha256": hashlib.sha256(
                    executable.read_bytes()
                ).hexdigest(),
            }
            with patch.object(worker, "PX4", str(executable)):
                observed = worker.process_identity(config, proc_root=root)
                self.assertEqual(observed["start_ticks"], "1234")
                self.assertEqual(observed["instance"], 3)
                (proc / "cmdline").write_bytes(b"/px4\0")
                with self.assertRaises(worker.Refused):
                    worker.process_identity(config, proc_root=root)


if __name__ == "__main__":
    unittest.main()
