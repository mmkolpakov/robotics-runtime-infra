"""Synthetic original custody controls; mock decoder positives are not native proof."""

from __future__ import annotations

import hashlib
import json
import tempfile
import unittest
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import patch

from px4_x500_evaluator._ulog import sampled_facts
from robotics_acceptance_harness.evidence import load_evidence_index
from robotics_runtime_contracts.writers import (
    add_evidence_artifact,
    create_evidence_index,
    finalize_evidence_index,
    write_document,
)
from test_ulog import IDENTITY, command, positions

RUN = "run-11111111-2222-4333-8444-555555555555"
BASE = 1700000000000000000


def native_case(folder, case="land"):
    import numpy as np

    folder.mkdir(exist_ok=True)
    refs, records, entries = {}, [], []

    def retain(name, value, *, binary=False, parent=False):
        raw = value if binary else (json.dumps(value) + "\n").encode()
        path = (folder.parent / "parent-facts" if parent else folder) / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(raw)
        ref = {
            "uri": path.as_uri(),
            "sha256": hashlib.sha256(raw).hexdigest(),
            "size_bytes": len(raw),
            "media_type": "application/octet-stream" if binary else "application/json",
        }
        refs[path] = ref
        return ref

    def record(kind, value):
        n = len(records)
        name = f"{n:04d}-{kind}.json"
        row = {
            "run_id": RUN,
            "domain_id": "px4",
            "kind": kind,
            "sequence": n,
            "receiver_unix_ns": str(BASE + n * 1000000),
            "receiver_monotonic_ms": 100 + n * 10,
            "value": value,
        }
        ref = retain(name, row)
        records.append((row, ref))
        entries.append(
            {
                "path": name,
                "kind": kind,
                "sha256": ref["sha256"],
                "size_bytes": ref["size_bytes"],
            }
        )
        return ref

    def snapshot(slot, stamp, topic="vehicle_status", *, armed=1):
        fields = (
            f"    arming_state: {armed}\n    system_id: 1\n    component_id: 1\n"
            if topic == "vehicle_status"
            else "    landed: True\n"
        )
        mono = 100 + len(records) * 10
        record(
            "listener-observation",
            {
                "slot": slot,
                "argv": [
                    "/opt/px4/build/px4_sitl_default/bin/px4-listener",
                    "--instance",
                    "0",
                    topic,
                    "-n",
                    "1",
                ],
                "returncode": 0,
                "stdout": f"TOPIC: {topic}\n    timestamp: {stamp} (0.000001 seconds ago)\n"
                + fields,
                "stderr": "",
                "host_started_monotonic_ms": mono - 2,
                "host_finished_monotonic_ms": mono - 1,
                "parsed": {"timestamp_us": str(stamp), "age_s": 0.000001},
            },
        )

    process = {
        "pid": 100,
        "start_ticks": "123",
        "executable": "/opt/px4/build/px4_sitl_default/bin/px4",
        "executable_sha256": "b" * 64,
        "instance": 0,
    }
    before = record("actor-identity-before", process)
    record("sdk-identity", IDENTITY)
    snapshot("initial-status-a", 80)
    snapshot("initial-land", 85, "vehicle_land_detected")
    snapshot("initial-status-b", 100)
    if case == "unarmed-refusal":
        record(
            "caller-refusal",
            {
                "method": "takeoff",
                "boundary": "caller-precondition",
                "reason": "unarmed",
                "dispatched": False,
            },
        )
    else:
        for i, method in enumerate(("arm", "takeoff"), 1):
            mono = 100 + len(records) * 10
            invocation = f"action-{i:04d}"
            record(
                "action-issued",
                {"invocation_id": invocation, "method": method, "monotonic_ms": mono},
            )
            record(
                "action-" + method,
                {
                    "invocation_id": invocation,
                    "method": method,
                    "monotonic_ms": mono + 10,
                    "dispatch_monotonic_ms": mono + 1,
                    "sdk_result": {"name": "SUCCESS", "value": 1},
                },
            )
        snapshot("pre-land-status", 210, armed=2)
        mono = 100 + len(records) * 10
        record(
            "action-issued",
            {"invocation_id": "action-0003", "method": "land", "monotonic_ms": mono},
        )
        record(
            "action-land",
            {
                "invocation_id": "action-0003",
                "method": "land",
                "monotonic_ms": mono + 10,
                "dispatch_monotonic_ms": mono + 1,
                "sdk_result": {"name": "SUCCESS", "value": 1},
            },
        )
    snapshot("final-status", 300)
    after = record("actor-identity-after", process)
    record(
        "controller-result",
        {
            "complete": True,
            "outcome": {"case": case, "observed": "synthetic source policy"},
            "error": None,
        },
    )
    retain(
        "controller-manifest.json",
        {
            "run_id": RUN,
            "domain_id": "px4",
            "clock_source": "controller-utc-ms",
            "complete": True,
            "started_unix_ns": str(BASE - 1000000),
            "finished_unix_ns": str(BASE + len(records) * 1000000),
            "records": entries,
            "total_bytes": sum(v["size_bytes"] for v in entries),
        },
    )
    cid, image = "a" * 64, "sha256:" + "c" * 64
    container = {
        "Id": cid,
        "Image": image,
        "RestartCount": 0,
        "State": {"Running": True, "StartedAt": "2026-11-03T00:00:00Z"},
        "Config": {
            "Labels": {
                "org.robotics.runtime.run-id": RUN,
                "com.docker.compose.project": "rr-px4-" + "d" * 24,
            }
        },
    }
    execution = "e" * 64
    exec_record = retain(
        "native-worker-exec.json",
        {"owner_id": RUN, "container_id": cid, "exec_id": execution},
        parent=True,
    )
    exec_result = retain(
        "native-worker-result.json",
        {
            "owner_id": RUN,
            "container_id": cid,
            "exec_id": execution,
            "started": True,
            "stream_complete": True,
            "inspect": {
                "ID": execution,
                "ContainerID": cid,
                "Running": False,
                "ExitCode": 0,
            },
            "output_base64": "",
        },
        parent=True,
    )
    custody = {}
    for name, _ref, captured in (
        ("actor_before", before, BASE),
        ("actor_after", after, BASE + 1000000000),
    ):
        custody[name] = retain(
            name + ".json",
            {
                "owner_id": RUN,
                "captured_unix_ns": str(captured),
                "container": container,
                "image": {"Id": image},
                **(
                    {"exec_record": exec_record, "exec_result": exec_result}
                    if name == "actor_after"
                    else {}
                ),
                "process_record": retain(
                    name + "-process.json",
                    {
                        "owner_id": RUN,
                        "container_id": cid,
                        "captured_unix_ns": str(captured),
                        "px4_process": process,
                    },
                    parent=True,
                ),
            },
            parent=True,
        )

    def logger(command_, stamp, output="", code=0, role=None):
        return {
            "owner_id": RUN,
            "container_id": cid,
            "role": role,
            "started_unix_ns": str(stamp),
            "finished_unix_ns": str(stamp + 1000000),
            "invocation": {
                "executable": "/opt/px4/build/px4_sitl_default/bin/px4-logger",
                "argv": ["--instance", "0", command_],
            },
            "result": {
                "ok": code == 0,
                "exitCode": code,
                "timedOut": False,
                "canceled": False,
                "stdout": output,
                "stderr": "",
            },
        }

    start = logger(
        "status",
        BASE - 10000000,
        "Full File Logging Running:\nLog file: ./log/log.ulg\n",
        role="before-case",
    )
    stop = logger("stop", BASE + 2000000000, role="after-case")
    stop["status_after"] = logger("status", BASE + 2010000000, "not running\n", 255)
    custody["logger_start"] = retain("logger-start.json", start, parent=True)
    custody["logger_stop"] = retain("logger-stop.json", stop, parent=True)
    uref = retain("retained/log.ulg", b"synthetic decoder fixture", binary=True)
    custody["export_manifest"] = retain(
        "retained/export-manifest.json",
        {
            "version": 1,
            "runId": RUN,
            "status": "complete",
            "startedUnixNs": str(BASE + 2020000000),
            "completedUnixNs": str(BASE + 2030000000),
            "totalBytes": uref["size_bytes"],
            "entries": [
                {
                    "name": "log.ulg",
                    "relativePath": "log.ulg",
                    "sha256": uref["sha256"],
                    "size_bytes": uref["size_bytes"],
                }
            ],
        },
    )
    native = {
        "run_id": RUN,
        "domain_id": "px4",
        "kind": "native-evidence",
        "value": {"ulog": uref, "custody": custody},
    }
    retain("native-evidence.json", native)

    def dataset(name, rows):
        return SimpleNamespace(
            name=name,
            multi_id=0,
            data={
                k: np.array(
                    [r[k] for r in rows],
                    dtype=np.int8 if type(rows[0][k]) is bool else None,
                )
                for k in rows[0]
            },
        )

    glob, homes = positions(
        [0, 0.1, 0.2, 0] if case == "unarmed-refusal" else [1.2, 1.5]
    )
    for row, stamp in zip(glob, [90, 130, 160, 190, 210], strict=False):
        row["timestamp"] = stamp
        row["timestamp_sample"] = stamp - 1
    homes[0]["timestamp"] = 95
    status = [
        {
            "timestamp": 140,
            "arming_state": 1 if case == "unarmed-refusal" else 2,
            "system_id": 1,
            "component_id": 1,
        },
        {"timestamp": 250, "arming_state": 1, "system_id": 1, "component_id": 1},
    ]
    acks = [
        {
            "timestamp": 280,
            "command": 22,
            "result": 0,
            "target_system": 245,
            "target_component": 190,
            "from_external": False,
        },
        {
            "timestamp": 290,
            "command": 21,
            "result": 0,
            "target_system": 245,
            "target_component": 190,
            "from_external": False,
        },
    ]
    decoded = SimpleNamespace(
        file_corruption=False,
        dropouts=[],
        has_data_appended=False,
        msg_info_dict={"ver_sw": "d6f12ad1c4f70ad3230afd7d86e971421e02fef4"},
        start_timestamp=1,
        last_timestamp=400,
        initial_parameters={"SDLOG_PROFILE": 1, "SDLOG_BACKEND": 3},
        changed_parameters=[],
        data_list=[
            dataset("vehicle_global_position", glob),
            dataset("home_position", homes),
            dataset("vehicle_status", status),
            dataset("vehicle_land_detected", [{"timestamp": 260, "landed": True}]),
            dataset(
                "vehicle_command",
                [command(1, 512)]
                if case == "unarmed-refusal"
                else [command(120), command(125), command(220, 21)],
            ),
            dataset("vehicle_command_ack", acks),
        ],
    )
    return records, native, refs, decoded


class CompleteMethodSoftwareControls(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory()
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name)

    def evidence(self, refs):
        draft = create_evidence_index(
            {
                "run_id": RUN,
                "generated_at": "2026-11-03T00:00:00Z",
                "policy_observation": {
                    "recording_mode": "native-sdk-json",
                    "compression": "none",
                    "retention_class": "test-evidence",
                    "upload_mode": "local_only",
                    "remote_sink_used": False,
                    "spool_peak_size_bytes": 0,
                    "upload_lag_max_sec": 0,
                },
            }
        )
        for i, (path, ref) in enumerate(refs.items()):
            draft = add_evidence_artifact(
                draft,
                path,
                {
                    **ref,
                    "artifact_id": f"source-{i}",
                    "kind": "other_evidence",
                    "retention_class": "test-evidence",
                    "storage_state": "local",
                },
            )
        path = self.root / "evidence-index.json"
        write_document(finalize_evidence_index(draft), path)
        return load_evidence_index(path)

    def assess(self, case="land", mutate=None, *, decode=True):
        from contextlib import nullcontext

        records, native, refs, decoded = native_case(self.root / "capture", case)
        self.refs = refs
        if mutate:
            mutate(records, native, decoded)
        evidence = self.evidence(refs)
        with patch("pyulog.ULog", return_value=decoded) if decode else nullcontext():
            return sampled_facts(
                records,
                {"run_id": RUN, "case": case, "application_deadline_ms": 2000},
                None,
                evidence=evidence,
                native=native,
            )

    def test_registered_chain_reaches_all_sampled_comparisons(self):
        result = self.assess()
        for name in ("completion", "command", "grounded", "disarmed", "postcondition"):
            self.assertIs(result[name][0], True, (name, result))

    def test_refusal_four_samples_and_no_dispatch_are_separate(self):
        result = self.assess("unarmed-refusal")
        self.assertIs(result["command"][0], True, result)
        self.assertIs(result["postcondition"][0], True, result)

    def test_unrelated_same_tick_command_and_ack_events_do_not_erase_measurements(self):
        def mutate(_records, _native, decoded):
            import numpy as np

            source = next(d for d in decoded.data_list if d.name == "vehicle_command")
            for cmd in [1000, 1001]:
                event = {
                    **command(220, cmd),
                    "source_system": 1,
                    "source_component": 1,
                    "from_external": False,
                }
                for key, value in event.items():
                    source.data[key] = np.append(source.data[key], value).astype(
                        source.data[key].dtype
                    )
            ack = next(d for d in decoded.data_list if d.name == "vehicle_command_ack")
            for cmd in [511, 512]:
                event = {key: values[-1].item() for key, values in ack.data.items()}
                event.update(command=cmd, timestamp=290)
                for key, value in event.items():
                    ack.data[key] = np.append(ack.data[key], value).astype(
                        ack.data[key].dtype
                    )

        result = self.assess(mutate=mutate)
        for name in ("completion", "command", "grounded", "disarmed", "postcondition"):
            self.assertIs(result[name][0], True, (name, result))

    def test_set_home_guard_uses_whole_command_window_for_every_case_and_sender(self):
        for case in ("land", "application-deadline", "unarmed-refusal"):
            for foreign in (False, True):
                for stamp, blocked in (
                    (100, False),
                    (105, True),
                    (230, True),
                    (300, True),
                    (301, False),
                ):

                    def mutate(_records, _native, decoded):
                        import numpy as np

                        source = next(
                            d for d in decoded.data_list if d.name == "vehicle_command"
                        )
                        event = command(stamp, 179)
                        if foreign:
                            event.update(source_system=77, source_component=88)
                        index = np.searchsorted(
                            source.data["timestamp"], stamp, side="right"
                        )
                        for key, value in event.items():
                            source.data[key] = np.insert(source.data[key], index, value)

                    with self.subTest(case=case, foreign=foreign, stamp=stamp):
                        result = self.assess(case, mutate=mutate)
                        self.assertIs(
                            result["postcondition"][0],
                            None if blocked else True,
                            result,
                        )
                        if blocked:
                            self.assertIn("DO_SET_HOME", result["postcondition"][2])

    def test_same_tick_home_candidates_resolve_only_invariant_case_verdicts(self):
        for case in ("land", "unarmed-refusal"):
            for outcome in (True, False, None):

                def mutate(_records, _native, decoded):
                    import numpy as np

                    source = next(
                        d
                        for d in decoded.data_list
                        if d.name == "vehicle_global_position"
                    )
                    homes = next(
                        d for d in decoded.data_list if d.name == "home_position"
                    )
                    source.data["alt"][1:] = 0
                    if case == "land":
                        source.data["alt"][-1] = {True: 1.5, False: 0.5, None: 1.25}[
                            outcome
                        ]
                        new_home = 0.1
                    else:
                        source.data["alt"][-1] = 0.5 if outcome is False else 0
                        new_home = (
                            0.1
                            if outcome is False
                            else -0.1
                            if outcome is True
                            else -0.201
                        )
                    for key, values in homes.data.items():
                        value = values[-1].item()
                        if key == "timestamp":
                            value = source.data["timestamp"][-1].item()
                        elif key == "alt":
                            value = new_home
                        elif key == "update_count":
                            value += 1
                        homes.data[key] = np.append(values, value).astype(values.dtype)

                with self.subTest(case=case, outcome=outcome):
                    result = self.assess(case, mutate=mutate)
                    self.assertIs(result["postcondition"][0], outcome, result)

    def test_source_sample_roles_preserve_the_complete_publication_window(self):
        for source_stamp, expected in ((119, False), (120, False), (121, True)):

            def mutate(_records, _native, decoded):
                source = next(
                    d for d in decoded.data_list if d.name == "vehicle_global_position"
                )
                source.data["timestamp_sample"][1] = source_stamp
                source.data["alt"][1] = 2.0
                source.data["alt"][2] = 0.0

            with self.subTest(source_stamp=source_stamp):
                result = self.assess(mutate=mutate)
                self.assertIs(result["postcondition"][0], expected, result)

    def test_refusal_boundary_context_is_not_a_fourth_witness(self):
        def mutate(_records, _native, decoded):
            source = next(
                d for d in decoded.data_list if d.name == "vehicle_global_position"
            )
            source.data["timestamp_sample"][1] = 100
            source.data["alt"][1:] = 0.0

        result = self.assess("unarmed-refusal", mutate=mutate)
        self.assertIsNone(result["postcondition"][0], result)

    def test_pre_command_refusal_context_does_not_become_the_excursion_anchor(self):
        def mutate(_records, _native, decoded):
            import numpy as np

            source = next(
                d for d in decoded.data_list if d.name == "vehicle_global_position"
            )
            source.data["timestamp_sample"][1] = 99
            source.data["alt"][1] = 5.0
            source.data["alt"][2:] = 0.0
            for key, values in source.data.items():
                value = values[-1].item()
                if key == "timestamp":
                    value = 240
                elif key == "timestamp_sample":
                    value = 239
                source.data[key] = np.append(values, value).astype(values.dtype)

        result = self.assess("unarmed-refusal", mutate=mutate)
        self.assertIs(result["postcondition"][0], True, result)

    def test_no_strict_post_command_witness_cannot_prove_a_positive(self):
        for stamps in ([118, 119], [119, 120]):

            def mutate(_records, _native, decoded):
                source = next(
                    d for d in decoded.data_list if d.name == "vehicle_global_position"
                )
                source.data["timestamp_sample"][1:] = stamps

            with self.subTest(stamps=stamps):
                result = self.assess(mutate=mutate)
                self.assertIsNone(result["postcondition"][0], result)

    def test_same_tick_conflicting_attributable_acks_remain_ambiguous(self):
        def mutate(_records, _native, decoded):
            import numpy as np

            ack = next(d for d in decoded.data_list if d.name == "vehicle_command_ack")
            event = {key: values[0].item() for key, values in ack.data.items()}
            event["result"] = 2
            for key, value in event.items():
                ack.data[key] = np.insert(ack.data[key], 1, value)

        result = self.assess(mutate=mutate)
        self.assertIsNone(result["command"][0], result)
        self.assertIn("ambiguous", result["command"][2])

    def test_same_tick_foreign_takeoff_is_not_hidden_by_owned_retry(self):
        def mutate(_records, _native, decoded):
            import numpy as np

            source = next(d for d in decoded.data_list if d.name == "vehicle_command")
            event = {**command(125), "source_system": 1}
            for key, value in event.items():
                source.data[key] = np.insert(source.data[key], 2, value)

        result = self.assess(mutate=mutate)
        self.assertIsNone(result["command"][0], result)
        self.assertIn("attribution", result["command"][2])

    def test_takeoff_at_publication_window_edge_is_not_trimmed_by_print_precision(self):
        def mutate(_records, _native, decoded):
            source = next(d for d in decoded.data_list if d.name == "vehicle_command")
            source.data["timestamp"][0] = 101

        result = self.assess(mutate=mutate)
        self.assertIs(result["command"][0], True, result)
        self.assertIs(result["postcondition"][0], True, result)

    def test_received_takeoff_at_refusal_edge_is_not_discarded_as_clock_uncertainty(
        self,
    ):
        def mutate(_records, _native, decoded):
            import numpy as np

            source = next(d for d in decoded.data_list if d.name == "vehicle_command")
            source.data = {
                key: np.array([value], dtype=np.int8 if type(value) is bool else None)
                for key, value in command(101).items()
            }

        result = self.assess("unarmed-refusal", mutate=mutate)
        self.assertIs(result["command"][0], False, result)

    def test_pre_land_publication_guard_remains_independent_of_print_clock_progress(
        self,
    ):
        def mutate(records, _native, _decoded):
            row = next(
                row
                for row, _ref in records
                if row["value"].get("slot") == "pre-land-status"
            )
            row["value"]["stdout"] = row["value"]["stdout"].replace("210 (", "221 (")
            row["value"]["parsed"]["timestamp_us"] = "221"

        result = self.assess(mutate=mutate)
        self.assertIsNone(result["postcondition"][0], result)
        self.assertIn("received land is outside", result["postcondition"][2])

    def test_ulog_above_document_ceiling_is_accepted_within_raw_budget(self):
        # harness 0.23.1 honors the explicit raw-evidence budget; the 8 MiB
        # document ceiling applies only to structured documents.
        from urllib.parse import urlsplit
        from urllib.request import url2pathname

        for size in (8 * 1024**2 + 1, 64 * 1024**2):
            with self.subTest(size=size), tempfile.TemporaryDirectory() as temporary:
                self.root = Path(temporary)
                payload = bytes([0xA5]) * size
                records, native, refs, decoded = native_case(self.root / "capture")
                self.refs = refs
                ref = native["value"]["ulog"]
                path = Path(url2pathname(urlsplit(ref["uri"]).path))
                path.write_bytes(payload)
                ref.update(sha256=hashlib.sha256(payload).hexdigest(), size_bytes=size)
                self.refs[path].update(ref)
                self.rewrite(
                    native["value"]["custody"]["export_manifest"],
                    lambda manifest: manifest.update(
                        totalBytes=size,
                        entries=[
                            {
                                **manifest["entries"][0],
                                "sha256": ref["sha256"],
                                "size_bytes": size,
                            }
                        ],
                    ),
                )
                evidence = self.evidence(refs)
                with patch("pyulog.ULog", return_value=decoded) as decoder:
                    result = sampled_facts(
                        records,
                        {
                            "run_id": RUN,
                            "case": "land",
                            "application_deadline_ms": 2000,
                        },
                        None,
                        evidence=evidence,
                        native=native,
                    )
                for name in (
                    "completion",
                    "command",
                    "grounded",
                    "disarmed",
                    "postcondition",
                ):
                    self.assertIs(result[name][0], True, (name, result))
                self.assertEqual(decoder.call_args[0][0].getvalue(), payload)

    def rewrite(self, ref, update):
        from urllib.parse import urlsplit
        from urllib.request import url2pathname

        path = Path(url2pathname(urlsplit(ref["uri"]).path))
        value = json.loads(path.read_bytes())
        update(value)
        raw = json.dumps(value).encode()
        path.write_bytes(raw)
        ref.update(sha256=hashlib.sha256(raw).hexdigest(), size_bytes=len(raw))
        self.refs[path].update(ref)

    def test_missing_exec_pair_keeps_independent_measurements(self):
        def missing(_records, native, _decoded):
            self.rewrite(
                native["value"]["custody"]["actor_after"],
                lambda actor: actor.pop("exec_result"),
            )

        result = self.assess(mutate=missing)
        self.assertIsNone(result["completion"][0])
        self.assertIn("exec pair is missing", result["completion"][2])
        self.assertIs(result["postcondition"][0], True)

    def test_exec_nonzero_is_known_failed_completion(self):
        for exit_code in (1, 124, 137):
            with (
                self.subTest(exit_code=exit_code),
                tempfile.TemporaryDirectory() as temporary,
            ):
                self.root = Path(temporary)

                def exited(_records, native, _decoded):
                    def update(actor):
                        self.rewrite(
                            actor["exec_result"],
                            lambda result: result["inspect"].update(ExitCode=exit_code),
                        )

                    self.rewrite(native["value"]["custody"]["actor_after"], update)

                result = self.assess(mutate=exited)
                self.assertIs(result["completion"][0], False)
                self.assertIn("exited " + str(exit_code), result["completion"][2])
                self.assertIs(result["postcondition"][0], True)

    def test_exec_foreign_partial_or_created_only_is_incomplete(self):
        mutations = (
            (lambda result: result.update(owner_id="another-owner"), "another owner"),
            (lambda result: result.update(container_id="f" * 64), "another owner"),
            (lambda result: result.update(exec_id="f" * 64), "another owner"),
            (lambda result: result.update(started=False), "created-only or partial"),
            (
                lambda result: result.update(stream_complete=False),
                "created-only or partial",
            ),
            (
                lambda result: result["inspect"].update(Running=True),
                "one settled process",
            ),
            (
                lambda result: result["inspect"].update(ExitCode=True),
                "one settled process",
            ),
            (
                lambda result: result["inspect"].update(ID="f" * 64),
                "one settled process",
            ),
        )
        for change, reason in mutations:
            with (
                self.subTest(reason=reason),
                tempfile.TemporaryDirectory() as temporary,
            ):
                self.root = Path(temporary)

                def mutate(_records, native, _decoded):
                    self.rewrite(
                        native["value"]["custody"]["actor_after"],
                        lambda actor: self.rewrite(actor["exec_result"], change),
                    )

                result = self.assess(mutate=mutate)
                self.assertIsNone(result["completion"][0])
                self.assertIn(reason, result["completion"][2])
                self.assertIs(result["postcondition"][0], True)

    def test_owned_denied_ack_is_failed_even_with_sdk_error_and_missing_land(self):
        def denied(records, _native, decoded):
            import numpy as np

            for record, _ref in records:
                if record["kind"] == "action-takeoff":
                    record["kind"] = "action-error"
                    record["value"]["sdk_result"] = {
                        "name": "COMMAND_DENIED",
                        "value": 4,
                    }
            records[:] = [
                (record, ref)
                for record, ref in records
                if not (
                    record["kind"] in ("action-issued", "action-land")
                    and record["value"].get("method") == "land"
                )
            ]
            source = next(
                d for d in decoded.data_list if d.name == "vehicle_command_ack"
            )
            source.data["result"] = np.array([2, 0])
            source = next(d for d in decoded.data_list if d.name == "vehicle_command")
            source.data = {k: v[:-1] for k, v in source.data.items()}

        result = self.assess(mutate=denied)
        self.assertIs(result["command"][0], False)
        self.assertIn("explicitly rejected", result["command"][2])

    def test_denied_ack_survives_missing_unrelated_measurement_topics(self):
        for topic in (
            "vehicle_global_position",
            "home_position",
            "vehicle_status",
            "vehicle_land_detected",
        ):
            with self.subTest(topic=topic), tempfile.TemporaryDirectory() as temporary:
                self.root = Path(temporary)

                def missing(records, _native, decoded):
                    import numpy as np

                    for record, _ref in records:
                        if record["kind"] == "action-takeoff":
                            record["kind"] = "action-error"
                            record["value"]["sdk_result"] = {
                                "name": "COMMAND_DENIED",
                                "value": 5,
                            }
                    source = next(
                        d for d in decoded.data_list if d.name == "vehicle_command_ack"
                    )
                    source.data["result"] = np.array([2, 0])
                    decoded.data_list = [
                        d for d in decoded.data_list if d.name != topic
                    ]

                result = self.assess(mutate=missing)
                self.assertIs(result["command"][0], False)
                self.assertIn("explicitly rejected", result["command"][2])
                affected = {
                    "vehicle_global_position": "postcondition",
                    "home_position": "postcondition",
                    "vehicle_status": "disarmed",
                    "vehicle_land_detected": "grounded",
                }[topic]
                self.assertIsNone(result[affected][0])
                self.assertIn(topic, result[affected][2])

    def test_missing_terminal_topic_does_not_erase_other_measurements(self):
        def missing(_records, _native, decoded):
            decoded.data_list = [
                d for d in decoded.data_list if d.name != "vehicle_land_detected"
            ]

        result = self.assess(mutate=missing)
        self.assertIsNone(result["grounded"][0])
        for name in ("command", "disarmed", "postcondition"):
            self.assertIs(result[name][0], True)

    def test_nonzero_exec_before_worker_process_records_is_known_failure(self):
        def startup_failed(records, native, _decoded):
            records[:] = [
                (r, ref) for r, ref in records if r["kind"] == "controller-result"
            ]
            records[0][0]["value"].update(
                complete=False,
                outcome={"case": "land", "observed": "unknown"},
                scope="controller startup",
            )
            self.rewrite(
                native["value"]["custody"]["actor_after"],
                lambda actor: self.rewrite(
                    actor["exec_result"],
                    lambda result: result["inspect"].update(ExitCode=1),
                ),
            )

        result = self.assess(mutate=startup_failed)
        self.assertIs(result["completion"][0], False)
        self.assertIn("exited 1", result["completion"][2])
        self.assertIsNone(result["postcondition"][0])

    def test_accepted_ack_with_unknown_sdk_result_does_not_prove_success(self):
        def unknown(records, _native, _decoded):
            for record, _ref in records:
                if record["kind"] == "action-takeoff":
                    record["kind"] = "action-error"
                    record["value"]["sdk_result"] = None

        result = self.assess(mutate=unknown)
        self.assertIsNone(result["command"][0])
        self.assertIs(result["postcondition"][0], True)

    def test_sdk_error_without_attributable_terminal_ack_stays_incomplete(self):
        def unknown(records, _native, decoded):
            for record, _ref in records:
                if record["kind"] == "action-takeoff":
                    record["kind"] = "action-error"
                    record["value"]["sdk_result"] = None
            source = next(
                d for d in decoded.data_list if d.name == "vehicle_command_ack"
            )
            source.data = {k: v[1:] for k, v in source.data.items()}

        result = self.assess(mutate=unknown)
        self.assertIsNone(result["command"][0])
        self.assertIn("acknowledgement", result["postcondition"][2])

    def test_stock_decoder_exception_stays_incomplete(self):
        result = self.assess(decode=False)
        self.assertIsNone(result["postcondition"][0])
        self.assertIn("stock ULog decoding", result["postcondition"][2])

    def test_missing_custody_is_not_a_closure_proof(self):
        result = self.assess(
            mutate=lambda _r, native, _u: native["value"]["custody"].pop("logger_stop")
        )
        self.assertIsNone(result["postcondition"][0])
        self.assertIn("incomplete", result["postcondition"][2])

    def test_slow_listener_with_fresh_printed_age_refuses(self):
        def slow(records, _native, _ulog):
            initial = next(
                r for r, _ref in records if r["kind"] == "listener-observation"
            )
            initial["value"]["host_started_monotonic_ms"] -= 1000

        result = self.assess(mutate=slow)
        self.assertIsNone(result["postcondition"][0])
        self.assertIn("budget", result["postcondition"][2])

    def test_actor_restart_in_original_fact_is_incomplete(self):
        def restart(_records, native, _decoded):
            from urllib.parse import urlsplit
            from urllib.request import url2pathname

            ref = native["value"]["custody"]["actor_after"]
            path = Path(url2pathname(urlsplit(ref["uri"]).path))
            actor = json.loads(path.read_bytes())
            actor["container"]["RestartCount"] = 1
            raw = json.dumps(actor).encode()
            path.write_bytes(raw)
            ref.update(sha256=hashlib.sha256(raw).hexdigest(), size_bytes=len(raw))

        result = self.assess(mutate=restart)
        self.assertIsNone(result["postcondition"][0])
        self.assertIn("restarted", result["completion"][2])

    def test_successful_stop_without_absent_module_status_is_incomplete(self):
        def still_running(_records, native, _decoded):
            from urllib.parse import urlsplit
            from urllib.request import url2pathname

            ref = native["value"]["custody"]["logger_stop"]
            path = Path(url2pathname(urlsplit(ref["uri"]).path))
            stop = json.loads(path.read_bytes())
            stop["status_after"]["result"].update(
                ok=True, exitCode=0, stdout="Not logging\n"
            )
            raw = json.dumps(stop).encode()
            path.write_bytes(raw)
            ref.update(sha256=hashlib.sha256(raw).hexdigest(), size_bytes=len(raw))

        result = self.assess(mutate=still_running)
        self.assertIsNone(result["postcondition"][0])
        self.assertIn("absence", result["postcondition"][2])

    def test_three_refusal_samples_cannot_establish_the_four_sample_condition(self):
        def fewer(_records, _native, decoded):
            source = next(
                d for d in decoded.data_list if d.name == "vehicle_global_position"
            )
            source.data = {k: v[:-1] for k, v in source.data.items()}

        result = self.assess("unarmed-refusal", mutate=fewer)
        self.assertIs(result["command"][0], True)
        self.assertIsNone(result["postcondition"][0])

    def test_persisted_intent_without_dispatch_anchor_is_incomplete_not_native_failure(
        self,
    ):
        def intent(records, _native, _decoded):
            row = {
                "run_id": RUN,
                "domain_id": "px4",
                "kind": "action-issued",
                "sequence": 5,
                "receiver_unix_ns": str(BASE + 5000000),
                "receiver_monotonic_ms": 145,
                "value": {
                    "method": "arm",
                    "invocation_id": "action-0001",
                    "monotonic_ms": 145,
                },
            }
            records.insert(5, (row, {}))
            for number, (record, _ref) in enumerate(records):
                record["sequence"] = number

        result = self.assess("unarmed-refusal", mutate=intent)
        self.assertIsNone(result["command"][0])
        self.assertIs(result["postcondition"][0], True)

    def test_owned_received_takeoff_contradicts_refusal_without_proving_ascent(self):
        def received(_records, _native, decoded):
            import numpy as np

            source = next(d for d in decoded.data_list if d.name == "vehicle_command")
            source.data = {
                key: np.array([value], dtype=np.int8 if type(value) is bool else None)
                for key, value in command(150).items()
            }

        result = self.assess("unarmed-refusal", mutate=received)
        self.assertIs(result["command"][0], False)
        self.assertIs(result["postcondition"][0], True)

    def test_refusal_outside_window_does_not_pass(self):
        def move(records, _native, _ulog):
            next(r for r, _ref in records if r["kind"] == "caller-refusal")[
                "sequence"
            ] = 1000

        result = self.assess("unarmed-refusal", move)
        self.assertIsNone(result["command"][0])
        self.assertIsNone(result["postcondition"][0])


if __name__ == "__main__":
    unittest.main()
