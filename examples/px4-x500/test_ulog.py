"""Source-method boundary controls, not native flight qualification."""

from __future__ import annotations

import unittest

from px4_x500_evaluator._ulog import (
    Unavailable,
    altitude_samples,
    altitude_condition,
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
    home = [{"timestamp": 6, "alt": home_alt, "valid_alt": True, "update_count": 3}]
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
            [heights[0] for _t, heights in altitude_samples(rows, home, 10, 100)], [1199, 1200, -200]
        )

    def test_amsl_float32_cancellation_is_not_decimal_rounding(self):
        rows, home = positions([1.2], home_alt=100)
        self.assertEqual(altitude_samples(rows, home, 10, 100)[0][1], (1199,))

    def test_initial_home_and_reset_changes_before_phase_are_allowed(self):
        rows, home = positions([0.0, 0.1, 0.2, 0.0])
        home.insert(
            0, {"timestamp": 1, "alt": 50.0, "valid_alt": False, "update_count": 1}
        )
        home[1]["timestamp"] = 6
        rows.insert(0, {**rows[0], "timestamp": 1, "alt_reset_counter": 2})
        self.assertEqual(len(altitude_samples(rows, home, 10, 100)), 4)

    def test_in_phase_reset_and_invalid_home_are_unavailable(self):
        for kind in ("reset", "invalid"):
            with self.subTest(kind=kind):
                rows, home = positions([0, 0.1])
                if kind == "reset":
                    rows[-1]["alt_reset_counter"] = 8
                else:
                    home[0]["valid_alt"] = False
                with self.assertRaises(Unavailable):
                    altitude_samples(rows, home, 10, 100)

    def test_home_updates_select_each_publications_contemporary_reference(self):
        estimates, homes = positions([1.5, 2.5, 3.5, 4.5])
        homes.extend(
            [
                {**homes[0], "timestamp": 25, "alt": 1.0, "update_count": 4},
                {**homes[0], "timestamp": 45, "alt": 2.0, "update_count": 5},
            ]
        )
        self.assertEqual(
            altitude_samples(estimates, homes, 10, 100),
            [(19, (1500,)), (29, (1500,)), (39, (2500,)), (49, (2500,))],
        )

    def test_home_lookup_uses_publication_not_source_sample_time(self):
        estimates, homes = positions([1.5, 2.5])
        estimates[-1]["timestamp_sample"] = 25
        homes.append({**homes[0], "timestamp": 26, "alt": 1.0, "update_count": 4})
        self.assertEqual(
            altitude_samples(estimates, homes, 10, 100), [(19, (1500,)), (25, (1500,))]
        )

    def test_same_publication_tick_reference_change_keeps_both_actual_values(self):
        estimates, homes = positions([1.5, 2.5])
        homes.append({**homes[0], "timestamp": 30, "alt": 1.0, "update_count": 4})
        self.assertEqual(
            altitude_samples(estimates, homes, 10, 100),
            [(19, (1500,)), (29, (2500, 1500))],
        )

    def test_identical_valid_same_tick_republish_preserves_all_samples(self):
        estimates, homes = positions([1.5, 2.5])
        homes.append({**homes[0], "timestamp": 30})
        self.assertEqual(
            altitude_samples(estimates, homes, 10, 100), [(19, (1500,)), (29, (2500,))]
        )

    def test_same_tick_count_only_update_has_a_unique_height(self):
        estimates, homes = positions([1.5, 2.5])
        homes.append({**homes[0], "timestamp": 30, "update_count": 4})
        self.assertEqual(
            altitude_samples(estimates, homes, 10, 100), [(19, (1500,)), (29, (2500,))]
        )

    def test_same_tick_count_only_update_does_not_mask_altitude_reset(self):
        estimates, homes = positions([1.5, 2.5])
        homes.append({**homes[0], "timestamp": 30, "update_count": 4})
        estimates[-1]["alt_reset_counter"] = 8
        with self.assertRaisesRegex(Unavailable, "altitude reset"):
            altitude_samples(estimates, homes, 10, 100)

    def test_invalid_or_missing_home_never_falls_back_to_older_valid_home(self):
        for change in ({"valid_alt": False}, {"alt": float("nan")}, {"alt": float("inf")}):
            estimates, homes = positions([1.5, 2.5])
            homes.append({**homes[0], "timestamp": 25, **change})
            with self.subTest(change=change), self.assertRaises(Unavailable):
                altitude_samples(estimates, homes, 10, 100)
        estimates, homes = positions([1.5])
        with self.assertRaises(Unavailable):
            altitude_samples(estimates, [], 10, 100)
        homes[0]["timestamp"] = 15
        with self.assertRaisesRegex(Unavailable, "baseline"):
            altitude_samples(estimates, homes, 10, 100)

    def test_invalid_transient_home_in_phase_is_not_hidden_between_samples(self):
        estimates, homes = positions([1.5, 2.5])
        homes.extend(
            [
                {**homes[0], "timestamp": 24, "valid_alt": False},
                {**homes[0], "timestamp": 25, "update_count": 4},
            ]
        )
        with self.assertRaises(Unavailable):
            altitude_samples(estimates, homes, 10, 100)

    def test_home_updates_do_not_mask_reset_or_source_timestamp_regression(self):
        for kind in ("reset", "regression", "future"):
            estimates, homes = positions([1.5, 2.5, 3.5])
            homes.append({**homes[0], "timestamp": 25, "alt": 1.0, "update_count": 4})
            if kind == "reset":
                estimates[-1]["alt_reset_counter"] = 8
            elif kind == "regression":
                estimates[-1]["timestamp_sample"] = 18
            else:
                estimates[-1]["timestamp_sample"] = 41
            with self.subTest(kind=kind), self.assertRaises(Unavailable):
                altitude_samples(estimates, homes, 10, 100)

    def test_out_of_phase_home_updates_do_not_change_selected_reference(self):
        estimates, homes = positions([1.5, 2.5])
        homes.append({**homes[0], "timestamp": 101, "alt": 100.0, "valid_alt": False})
        self.assertEqual(
            altitude_samples(estimates, homes, 10, 100), [(19, (1500,)), (29, (2500,))]
        )

    def test_asof_lookup_keeps_uint64_publication_precision(self):
        estimates, homes = positions([1.5, 2.5])
        offset = 1 << 63
        for row in estimates:
            row["timestamp"] += offset
            row["timestamp_sample"] += offset
        homes[0]["timestamp"] += offset
        homes.append(
            {**homes[0], "timestamp": offset + 25, "alt": 1.0, "update_count": 4}
        )
        self.assertEqual(
            altitude_samples(estimates, homes, offset + 10, offset + 100),
            [(offset + 19, (1500,)), (offset + 29, (1500,))],
        )

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


class HomeOriginResetControls(unittest.TestCase):
    def test_pre_phase_reset_after_home_capture_is_unavailable(self):
        estimates, homes = positions([1.5])
        estimates.insert(1, {**estimates[0], "timestamp": 8, "alt_reset_counter": 8})
        estimates[-1]["alt_reset_counter"] = 8
        with self.assertRaisesRegex(Unavailable, "home origin"):
            altitude_samples(estimates, homes, 10, 100)

    def test_missing_global_before_applied_home_is_unavailable(self):
        estimates, homes = positions([1.5])
        homes[0]["timestamp"] = 1
        with self.assertRaisesRegex(Unavailable, "origin"):
            altitude_samples(estimates, homes, 10, 100)

    def test_reset_at_home_publication_has_no_proven_origin_order(self):
        estimates, homes = positions([1.5])
        estimates.insert(1, {**estimates[0], "timestamp": 6, "alt_reset_counter": 8})
        estimates[-1]["alt_reset_counter"] = 8
        with self.assertRaisesRegex(Unavailable, "home origin"):
            altitude_samples(estimates, homes, 10, 100)

    def test_new_applied_home_after_an_earlier_reset_has_coherent_origin(self):
        estimates, homes = positions([1.5])
        estimates.insert(0, {**estimates[0], "timestamp": 1})
        estimates[1]["alt_reset_counter"] = 8
        estimates[-1]["alt_reset_counter"] = 8
        homes.insert(0, {**homes[0], "timestamp": 2, "update_count": 2})
        self.assertEqual(altitude_samples(estimates, homes, 10, 100), [(19, (1500,))])


class CandidateConditionControls(unittest.TestCase):
    def samples(self, heights):
        return list(enumerate(heights, 1))

    def test_positive_ambiguity_invariance_and_incomplete(self):
        for values, expected in [
            ([(1200, 1300)], True),
            ([(1199, 1000)], False),
            ([(1199, 1200)], None),
            ([(1199, 1200), (1300,)], True),
            ([(1199,), (1200,)], True),
        ]:
            with self.subTest(values=values):
                self.assertIs(altitude_condition(self.samples(values), refusal=False), expected)

    def test_refusal_ambiguity_invariance_and_incomplete(self):
        for values, expected in [
            ([(0, 100), (100,), (100,), (100,)], True),
            ([(0,), (-201, 201)], False),
            ([(0,), (0, 201), (0,), (0,)], None),
            ([(0, 500), (0,), (500,), (0,)], False),
            ([(0, 500), (0,), (0,), (0,)], None),
            ([(0, 201), (100,), (100,), (100,)], True),
            ([(0,), (200,), (0,)], None),
            ([(0,), (201,)], False),
        ]:
            with self.subTest(values=values):
                self.assertIs(altitude_condition(self.samples(values), refusal=True), expected)

    def test_first_anchor_is_correlated_with_its_own_candidate_choice(self):
        self.assertIs(
            altitude_condition(self.samples([(0, 400), (200,), (200,), (200,)]), refusal=True),
            True,
        )

    def test_discrete_refusal_candidates_match_each_actual_point_world(self):
        from itertools import product

        choices = [(0,), (-201,), (201,), (-201, 201), (0, 201)]
        for count in (1, 2, 4):
            for values in product(choices, repeat=count):
                results = set()
                for world in product(*values):
                    excursion = max(abs(mm - world[0]) for mm in world)
                    results.add(False if excursion > 200 else True if count >= 4 else None)
                expected = next(iter(results)) if len(results) == 1 else None
                self.assertIs(
                    altitude_condition(self.samples(values), refusal=True),
                    expected,
                    values,
                )


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


class EventTimestampControls(unittest.TestCase):
    def dataset(self, name, times):
        import numpy as np
        from types import SimpleNamespace

        return SimpleNamespace(
            data_list=[
                SimpleNamespace(
                    name=name,
                    multi_id=0,
                    data={
                        "timestamp": np.array(times),
                        "command": np.array([511, 512, 400][: len(times)]),
                    },
                )
            ]
        )

    def test_distinct_same_tick_event_rows_keep_original_order_and_count(self):
        for name in ("vehicle_command", "vehicle_command_ack"):
            decoded = rows(
                self.dataset(name, [100, 100, 101]), name, ("timestamp", "command")
            )
            self.assertEqual(
                [(r["timestamp"], r["command"]) for r in decoded],
                [(100, 511), (100, 512), (101, 400)],
            )

    def test_event_regression_nonpositive_and_state_ties_stay_unavailable(self):
        for name, times in [
            ("vehicle_command", [100, 99]),
            ("vehicle_command_ack", [0, 100]),
            ("vehicle_status", [100, 100]),
            ("vehicle_global_position", [100, 100]),
        ]:
            with (
                self.subTest(name=name, times=times),
                self.assertRaisesRegex(Unavailable, "not ordered"),
            ):
                rows(self.dataset(name, times), name, ("timestamp", "command"))


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
