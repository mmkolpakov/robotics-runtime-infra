"""Source-method boundary controls, not native flight qualification."""

from __future__ import annotations

import unittest

from px4_x500_evaluator._ulog import (
    Unavailable,
    altitude_samples,
    command_phase,
    original,
    sampled_facts,
    snapshot,
    phase,
    serial_actions,
    rows,
)

IDENTITY = {
    "source_system_id": 245,
    "source_component_id": 190,
    "target_system_id": 1,
    "target_component_id": 1,
    "discovered_system_ids": [1],
}


def positions(values, *, home_alt=0.0):
    baseline = {
        "timestamp": 5,
        "timestamp_sample": 4,
        "alt": home_alt,
        "alt_valid": True,
        "alt_reset_counter": 7,
    }
    result = [baseline]
    for i, value in enumerate(values):
        result.append(
            {
                **baseline,
                "timestamp": 20 + i * 10,
                "timestamp_sample": 19 + i * 10,
                "alt": home_alt + value,
            }
        )
    home = [{"timestamp": 1, "alt": home_alt, "valid_alt": True, "update_count": 3}]
    return result, home


def command(stamp=100, code=22):
    return {
        "timestamp": stamp,
        "command": code,
        "target_system": 1,
        "target_component": 1,
        "source_system": 245,
        "source_component": 190,
        "from_external": True,
        "confirmation": 0,
        **{"param" + str(i): float("nan") for i in range(1, 8)},
    }


class SampledAltitudeControls(unittest.TestCase):
    def test_float32_millimetres_and_truncation_match_pinned_px4_assignment(self):
        rows, home = positions([1.199, 1.2, -0.2009])
        self.assertEqual(
            [mm for _t, mm in altitude_samples(rows, home, 10, 100)], [1199, 1200, -200]
        )

    def test_amsl_float32_cancellation_is_not_decimal_rounding(self):
        rows, home = positions([1.2], home_alt=100)
        self.assertEqual(altitude_samples(rows, home, 10, 100)[0][1], 1199)

    def test_initial_home_and_reset_changes_before_phase_are_allowed(self):
        rows, home = positions([0.0, 0.1, 0.2, 0.0])
        home.insert(
            0, {"timestamp": 1, "alt": 50.0, "valid_alt": False, "update_count": 1}
        )
        home[1]["timestamp"] = 2
        rows.insert(0, {**rows[0], "timestamp": 1, "alt_reset_counter": 2})
        self.assertEqual(len(altitude_samples(rows, home, 10, 100)), 4)

    def test_in_phase_home_reset_and_invalid_home_are_unavailable(self):
        for kind in ("home", "reset", "invalid"):
            with self.subTest(kind=kind):
                rows, home = positions([0, 0.1])
                if kind == "home":
                    home.append({**home[0], "timestamp": 25, "update_count": 4})
                elif kind == "reset":
                    rows[-1]["alt_reset_counter"] = 8
                else:
                    home[0]["valid_alt"] = False
                with self.assertRaises(Unavailable):
                    altitude_samples(rows, home, 10, 100)

    def test_source_sample_and_publication_must_both_follow_received_command(self):
        rows, home = positions([1.5])
        rows[-1]["timestamp_sample"] = 9
        with self.assertRaisesRegex(Unavailable, "stale"):
            altitude_samples(rows, home, 10, 100)

    def test_repeated_source_sample_does_not_count_as_four_observations(self):
        rows, home = positions([0, 0, 0, 0])
        rows[-1]["timestamp_sample"] = rows[-2]["timestamp_sample"]
        with self.assertRaisesRegex(Unavailable, "independent"):
            altitude_samples(rows, home, 10, 100)

    def test_nonfinite_estimate_is_not_an_observed_absence(self):
        for altitude in (float("nan"), float("inf")):
            rows, home = positions([altitude])
            with self.assertRaises(Unavailable):
                altitude_samples(rows, home, 10, 100)

    def test_home_timestamp_refresh_without_value_change_is_allowed(self):
        rows, home = positions([0, 0.1])
        home.append({**home[0], "timestamp": 25})
        self.assertEqual(len(altitude_samples(rows, home, 10, 100)), 2)


class NativeCommandControls(unittest.TestCase):
    def test_owned_retry_nan_defaults_and_late_ack_are_supported(self):
        retry = command(120)
        retry["confirmation"] = 1
        ack = {
            "timestamp": 250,
            "command": 22,
            "result": 0,
            "target_system": 245,
            "target_component": 190,
            "from_external": False,
        }
        self.assertEqual(
            command_phase([command(), retry], [ack], IDENTITY, 22, (50, 300)),
            (100, True),
        )

    def test_foreign_command_and_conflicting_ack_are_ambiguous(self):
        ack = {
            "timestamp": 200,
            "command": 22,
            "result": 0,
            "target_system": 245,
            "target_component": 190,
        }
        wrong = command()
        wrong["source_system"] = 1
        with self.assertRaisesRegex(Unavailable, "attribution"):
            command_phase([wrong], [ack], IDENTITY, 22, (50, 300))
        with self.assertRaisesRegex(Unavailable, "ambiguous"):
            command_phase(
                [command()],
                [ack, {**ack, "timestamp": 201, "result": 2}],
                IDENTITY,
                22,
                (50, 300),
            )

    def test_unknown_ack_enum_cannot_become_known_denial(self):
        ack = {
            "timestamp": 200,
            "command": 22,
            "result": 7,
            "target_system": 245,
            "target_component": 190,
        }
        for value in (7, -1, True):
            with (
                self.subTest(value=value),
                self.assertRaisesRegex(Unavailable, "result is unknown"),
            ):
                command_phase(
                    [command()], [{**ack, "result": value}], IDENTITY, 22, (50, 300)
                )

    def test_second_application_invocation_is_not_an_sdk_retry(self):
        def row(sequence, kind, invocation):
            return (
                {
                    "kind": kind,
                    "sequence": sequence,
                    "value": {"method": "takeoff", "invocation_id": invocation},
                },
                {},
            )

        kinds = {
            "action-issued": [
                row(1, "action-issued", "action-0001"),
                row(3, "action-issued", "action-0002"),
            ],
            "action-takeoff": [row(2, "action-takeoff", "action-0001")],
        }
        with self.assertRaisesRegex(Unavailable, "repeated"):
            serial_actions(kinds)

    def test_digest_match_cannot_substitute_another_original_uri(self):
        class Evidence:
            def __init__(self):
                self.local_files = {
                    "other": {
                        "uri": "file:///other",
                        "sha256": "a" * 64,
                        "size_bytes": 1,
                        "media_type": "application/octet-stream",
                    }
                }

            def read_local(self, *_args, **_kwargs):
                raise AssertionError("unbound original must not be read")

        with self.assertRaisesRegex(Unavailable, "exact URI"):
            original(
                {
                    "uri": "file:///original",
                    "sha256": "a" * 64,
                    "size_bytes": 1,
                    "media_type": "application/octet-stream",
                },
                Evidence(),
            )

    def test_application_deadline_is_separate_from_missing_native_measurement(self):
        config = {
            "run_id": "run",
            "case": "application-deadline",
            "application_deadline_ms": 2000,
        }
        record = {
            "kind": "application-deadline",
            "sequence": 0,
            "value": {
                "started_monotonic_ms": 100,
                "observed_monotonic_ms": 2100,
                "budget_ms": 2000,
            },
        }
        result = sampled_facts([(record, {"sha256": "a" * 64})], config, None)
        self.assertIs(result["deadline"][0], True)
        self.assertIsNone(result["postcondition"][0])
        record["value"]["budget_ms"] = 1999
        self.assertIsNone(sampled_facts([(record, {})], config, None)["deadline"][0])


class StockBooleanControls(unittest.TestCase):
    def test_stock_int8_boolean_is_normalized_only_for_known_fields(self):
        import numpy as np
        from types import SimpleNamespace

        for value in (0, 1, -1, 2):
            ulog = SimpleNamespace(
                data_list=[
                    SimpleNamespace(
                        name="home_position",
                        multi_id=0,
                        data={
                            "timestamp": np.array([1]),
                            "valid_alt": np.array([value], dtype=np.int8),
                        },
                    )
                ]
            )
            if value in (0, 1):
                self.assertIs(
                    rows(ulog, "home_position", ("timestamp", "valid_alt"))[0][
                        "valid_alt"
                    ],
                    value == 1,
                )
            else:
                with self.assertRaisesRegex(Unavailable, "stock int8 zero or one"):
                    rows(ulog, "home_position", ("timestamp", "valid_alt"))


class ListenerGrammarControls(unittest.TestCase):
    def record(self, *, topic="vehicle_status", fields=None):
        if fields is None:
            fields = "    arming_state: 1\n    system_id: 1\n    component_id: 1\n"
        return {
            "value": {
                "slot": "initial-land"
                if topic == "vehicle_land_detected"
                else "initial-status-a",
                "argv": [
                    "/opt/px4/build/px4_sitl_default/bin/px4-listener",
                    "--instance",
                    "0",
                    topic,
                    "-n",
                    "1",
                ],
                "returncode": 0,
                "stdout": f"TOPIC: {topic}\n    timestamp: 1000000 (0.250000 seconds ago)\n"
                + fields,
                "host_started_monotonic_ms": 100,
                "host_finished_monotonic_ms": 110,
                "parsed": {"timestamp_us": "1000000", "age_s": 0.0},
            }
        }

    def test_original_age_is_returned_instead_of_retained_claim(self):
        record = self.record()
        record["value"]["parsed"]["native_print_clock_us"] = {
            "lower": "1",
            "upper": "2",
        }
        parsed = snapshot(record, 1, 1)
        self.assertEqual(
            parsed["native_print_clock_us"], {"lower": "1249999", "upper": "1250001"}
        )
        self.assertEqual(parsed["age_s"], 0.25)
        self.assertEqual(parsed["timestamp_us"], "1000000")

    def test_fixed_version_grammar_rejects_permissive_variants(self):
        original = self.record()["value"]["stdout"]
        for raw in (
            original.replace("0.250000", "0.25"),
            original.replace("1000000 (", str(1 << 64) + " ("),
            original + "    extra_field: 1\n    extra_field: 2\n",
            original + "x" * 32768,
        ):
            with self.subTest(raw=raw[:100]):
                record = self.record()
                record["value"]["stdout"] = raw
                with self.assertRaises(Unavailable):
                    snapshot(record, 1, 1)
        with self.assertRaises(Unavailable):
            snapshot(
                self.record(topic="vehicle_land_detected", fields="    landed: true\n"),
                1,
                1,
                landed=True,
            )

    def test_identity_invocation_and_elapsed_policy_remain_separate(self):
        for field, value in (
            ("argv", ["listener"]),
            ("returncode", False),
            ("host_finished_monotonic_ms", 4000),
            (
                "stdout",
                self.record()["value"]["stdout"].replace(
                    "system_id: 1", "system_id: 2"
                ),
            ),
        ):
            with self.subTest(field=field):
                record = self.record()
                record["value"][field] = value
                with self.assertRaises(Unavailable):
                    snapshot(record, 1, 1)


class NativePrintClockControls(unittest.TestCase):
    def records(self):
        records = [({"kind": "sdk-identity", "sequence": 0, "value": IDENTITY}, {})]
        for number, (slot, topic, stamp, age) in enumerate(
            [
                ("initial-status-a", "vehicle_status", 100, "0.000010"),
                ("initial-land", "vehicle_land_detected", 85, "0.000030"),
                ("initial-status-b", "vehicle_status", 100, "0.000020"),
                ("final-status", "vehicle_status", 300, "0.000001"),
            ],
            1,
        ):
            row = ListenerGrammarControls().record(
                topic=topic,
                fields="    landed: True\n"
                if topic == "vehicle_land_detected"
                else None,
            )
            row["kind"], row["sequence"] = "listener-observation", number
            row["value"]["slot"] = slot
            row["value"]["stdout"] = row["value"]["stdout"].replace(
                "1000000 (0.250000", f"{stamp} ({age}"
            )
            row["value"]["parsed"]["timestamp_us"] = str(stamp)
            records.append((row, {}))
        return records

    def test_cached_publication_with_clock_progress_keeps_exact_publication_window(
        self,
    ):
        records = self.records()
        _kinds, _identity, _slots, start, end, _snapshots = phase(records)
        self.assertEqual((start, end), (100, 300))
        ack = {
            "timestamp": 102,
            "command": 22,
            "result": 0,
            "target_system": 245,
            "target_component": 190,
            "from_external": False,
        }
        self.assertEqual(
            command_phase([command(101)], [ack], IDENTITY, 22, (start, end)),
            (101, True),
        )

    def test_native_clock_rollback_and_overlapping_precision_bounds_are_not_progress(
        self,
    ):
        for age in ["0.000005", "0.000026"]:
            records = self.records()
            records[2][0]["value"]["stdout"] = records[2][0]["value"]["stdout"].replace(
                "0.000030", age
            )
            with self.assertRaisesRegex(Unavailable, "print clock"):
                phase(records)

    def test_publication_rollback_and_zero_event_window_stay_unavailable(self):
        records = self.records()
        records[3][0]["value"]["stdout"] = records[3][0]["value"]["stdout"].replace(
            "100 (", "99 ("
        )
        records[3][0]["value"]["parsed"]["timestamp_us"] = "99"
        with self.assertRaisesRegex(Unavailable, "publication timestamp"):
            phase(records)
        records = self.records()
        final = records[-1][0]["value"]
        final["stdout"] = final["stdout"].replace("300 (0.000001", "100 (0.000100")
        final["parsed"]["timestamp_us"] = "100"
        with self.assertRaisesRegex(Unavailable, "publication window is empty"):
            phase(records)


if __name__ == "__main__":
    unittest.main()
