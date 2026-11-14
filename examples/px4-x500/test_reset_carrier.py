"""Stock counter-carrier and conservative home-origin source controls."""

from types import SimpleNamespace
import unittest

import numpy as np

from px4_x500_evaluator._ulog import (
    PX4_SOURCE,
    Unavailable,
    altitude_samples,
    home_origin_bound,
    post_command_condition,
)
from test_ulog import positions


def carrier_case(values=(0, 0, 0, 0)):
    estimates, homes = positions(values)
    estimates[0].update(timestamp=8, timestamp_sample=7)
    homes.append({**homes[-1], "timestamp": 9})
    times = (2, 3, 7, 9, 20, 30, 40, 50, 60)
    local = SimpleNamespace(
        name="vehicle_local_position",
        multi_id=0,
        data={
            "timestamp": np.array(times, dtype=np.uint64),
            "timestamp_sample": np.array([t - 1 for t in times], dtype=np.uint64),
            "z_reset_counter": np.array([7] * len(times), dtype=np.uint8),
        },
    )
    ulog = SimpleNamespace(
        msg_info_dict={"ver_sw": PX4_SOURCE},
        initial_parameters={
            "SENS_IMU_MODE": 1,
            "EKF2_EN": 1,
            "LPE_EN": 0,
            "ATT_EN": 0,
        },
        changed_parameters=[],
        data_list=[local],
    )
    return estimates, homes, ulog


class ResetCarrierControls(unittest.TestCase):
    def test_native_local_carrier_supplies_the_same_guard_for_both_conditions(self):
        for refusal, values in ((False, (1.5,) * 4), (True, (0,) * 4)):
            estimates, homes, ulog = carrier_case(values)
            with self.subTest(refusal=refusal):
                samples = altitude_samples(estimates, homes, 10, 100, ulog=ulog)
                self.assertEqual(len(samples), 4)
                self.assertIs(
                    post_command_condition(samples, 10, refusal=refusal), True
                )

    def test_complete_global_carrier_does_not_inspect_optional_local_or_parameters(
        self,
    ):
        class Irrelevant:
            def __getattribute__(self, name):
                raise AssertionError("optional evidence must not be inspected: " + name)

        estimates, homes = positions([1.5])
        self.assertEqual(
            altitude_samples(estimates, homes, 10, 100, ulog=Irrelevant()),
            [(19, (1500,))],
        )
        _, _, ulog = carrier_case()
        ulog.data_list[0].data = {}
        ulog.initial_parameters = {}
        self.assertEqual(
            altitude_samples(estimates, homes, 10, 100, ulog=ulog),
            [(19, (1500,))],
        )

    def test_global_reset_violation_cannot_fall_back_to_a_local_carrier(self):
        estimates, homes, ulog = carrier_case()
        estimates.insert(0, {**estimates[0], "timestamp": 3, "timestamp_sample": 2})
        estimates[1]["alt_reset_counter"] = 8
        with self.assertRaisesRegex(Unavailable, "home origin"):
            altitude_samples(estimates, homes, 10, 100, ulog=ulog)

    def test_missing_or_ambiguous_native_local_carrier_is_incomplete(self):
        for kind in ("missing", "instance", "duplicate", "fields", "empty"):
            estimates, homes, ulog = carrier_case()
            local = ulog.data_list[0]
            if kind == "missing":
                ulog.data_list = []
            elif kind == "instance":
                local.multi_id = 1
            elif kind == "duplicate":
                ulog.data_list.append(local)
            elif kind == "fields":
                del local.data["z_reset_counter"]
            else:
                local.data = {k: v[:0] for k, v in local.data.items()}
            with self.subTest(kind=kind), self.assertRaises(Unavailable):
                altitude_samples(estimates, homes, 10, 100, ulog=ulog)

    def test_unknown_or_changed_regular_mode_parameters_cannot_prove_the_alias(self):
        _, _, original = carrier_case()
        for name, correct in original.initial_parameters.items():
            for value in (None, bool(correct), float(correct), 1 - correct):
                estimates, homes, ulog = carrier_case()
                if value is None:
                    del ulog.initial_parameters[name]
                else:
                    ulog.initial_parameters[name] = value
                with (
                    self.subTest(name=name, value=value),
                    self.assertRaisesRegex(Unavailable, "startup parameters"),
                ):
                    altitude_samples(estimates, homes, 10, 100, ulog=ulog)
            for when in (1, 6, 10, 100, 101):
                estimates, homes, ulog = carrier_case()
                ulog.changed_parameters.append((when, name, correct))
                with (
                    self.subTest(name=name, when=when),
                    self.assertRaisesRegex(Unavailable, "startup parameters"),
                ):
                    altitude_samples(estimates, homes, 10, 100, ulog=ulog)

    def test_regular_ekf2_alias_does_not_require_magnetometer_mode(self):
        for value, changes in (
            (None, []),
            (0, []),
            (1, [(1, "SENS_MAG_MODE", 0), (10, "SENS_MAG_MODE", 1)]),
        ):
            estimates, homes, ulog = carrier_case()
            if value is not None:
                ulog.initial_parameters["SENS_MAG_MODE"] = value
            ulog.changed_parameters = changes
            with self.subTest(value=value, changes=changes):
                samples = altitude_samples(estimates, homes, 10, 100, ulog=ulog)
                self.assertIs(post_command_condition(samples, 10, refusal=True), True)

    def test_different_firmware_cannot_claim_the_native_counter_alias(self):
        estimates, homes, ulog = carrier_case()
        ulog.msg_info_dict["ver_sw"] = "0" * 40
        with self.assertRaisesRegex(Unavailable, "pinned EKF2"):
            altitude_samples(estimates, homes, 10, 100, ulog=ulog)

    def test_local_carrier_must_strictly_precede_origin_and_overlap_global(self):
        for kind in ("equal", "after", "no-overlap"):
            estimates, homes, ulog = carrier_case()
            local = ulog.data_list[0]
            keep = local.data["timestamp"] >= (4 if kind == "equal" else 5)
            if kind == "no-overlap":
                keep = local.data["timestamp"] < 8
            local.data = {k: v[keep] for k, v in local.data.items()}
            if kind == "equal":
                local.data["timestamp"][0] = 4
                local.data["timestamp_sample"][0] = 3
            with (
                self.subTest(kind=kind),
                self.assertRaisesRegex(Unavailable, "preceding local|overlap"),
            ):
                altitude_samples(estimates, homes, 10, 100, ulog=ulog)

    def test_reset_before_first_global_and_overlap_disagreement_are_incomplete(self):
        for kind in ("early-reset", "late-reset", "mismatch"):
            estimates, homes, ulog = carrier_case()
            counters = ulog.data_list[0].data["z_reset_counter"]
            if kind == "early-reset":
                counters[2:] = 8
                for row in estimates:
                    row["alt_reset_counter"] = 8
            elif kind == "late-reset":
                counters[-2:] = 8
            else:
                counters[:] = 8
            with (
                self.subTest(kind=kind),
                self.assertRaisesRegex(Unavailable, "reset|carriers disagree"),
            ):
                altitude_samples(estimates, homes, 10, 100, ulog=ulog)

    def test_reset_before_the_local_predecessor_does_not_poison_the_phase(self):
        estimates, homes, ulog = carrier_case()
        ulog.data_list[0].data["z_reset_counter"][0] = 6
        self.assertEqual(len(altitude_samples(estimates, homes, 10, 100, ulog=ulog)), 4)

    def test_non_native_local_field_types_are_incomplete(self):
        for field, dtype in (
            ("timestamp", np.float64),
            ("timestamp", np.int64),
            ("timestamp_sample", np.int64),
            ("z_reset_counter", np.int8),
            ("z_reset_counter", np.float64),
        ):
            estimates, homes, ulog = carrier_case()
            local = ulog.data_list[0]
            local.data[field] = local.data[field].astype(dtype)
            with self.subTest(field=field, dtype=dtype), self.assertRaises(Unavailable):
                altitude_samples(estimates, homes, 10, 100, ulog=ulog)

    def test_local_publication_and_sample_order_cannot_be_repaired(self):
        for kind in (
            "zero-publication",
            "duplicate-publication",
            "backward-publication",
            "zero-sample",
            "future-sample",
            "duplicate-sample",
            "backward-sample",
        ):
            estimates, homes, ulog = carrier_case()
            data = ulog.data_list[0].data
            if kind == "zero-publication":
                data["timestamp"][0] = 0
            elif kind == "duplicate-publication":
                data["timestamp"][3] = data["timestamp"][2]
            elif kind == "backward-publication":
                data["timestamp"][3] = 6
            elif kind == "zero-sample":
                data["timestamp_sample"][2] = 0
            elif kind == "future-sample":
                data["timestamp_sample"][2] = data["timestamp"][2] + 1
            elif kind == "duplicate-sample":
                data["timestamp_sample"][3] = data["timestamp_sample"][2]
            else:
                data["timestamp_sample"][3] = data["timestamp_sample"][2] - 1
            with self.subTest(kind=kind), self.assertRaises(Unavailable):
                altitude_samples(estimates, homes, 10, 100, ulog=ulog)

    def test_global_counter_types_and_source_order_remain_required_with_local(self):
        for kind in ("bool", "float", "range", "future", "zero", "order"):
            estimates, homes, ulog = carrier_case()
            if kind in ("bool", "float", "range"):
                estimates[0]["alt_reset_counter"] = {
                    "bool": True,
                    "float": 7.0,
                    "range": 256,
                }[kind]
            elif kind == "future":
                estimates[0]["timestamp_sample"] = 9
            elif kind == "zero":
                estimates[0]["timestamp_sample"] = 0
            else:
                estimates[0]["timestamp_sample"] = 8
                estimates[1]["timestamp_sample"] = 7
            with self.subTest(kind=kind), self.assertRaises(Unavailable):
                altitude_samples(estimates, homes, 10, 100, ulog=ulog)


class ConservativeHomeOriginControls(unittest.TestCase):
    def test_last_different_home_publication_is_the_conservative_bound(self):
        _, homes = positions([])
        homes[-1]["timestamp"] = 8
        homes.append({**homes[-1], "timestamp": 9})
        self.assertEqual(home_origin_bound(homes, len(homes) - 1), 4)

    def test_missed_home_set_before_reset_and_yaw_republish_is_incomplete(self):
        for carrier in ("global", "local"):
            estimates, homes, ulog = carrier_case((1.5,) * 4)
            homes[1]["timestamp"] = 8
            estimates[0].update(timestamp=7, timestamp_sample=6)
            for row in estimates:
                row["alt_reset_counter"] = 8
            if carrier == "global":
                estimates.insert(
                    0,
                    {
                        **estimates[0],
                        "timestamp": 3,
                        "timestamp_sample": 2,
                        "alt_reset_counter": 7,
                    },
                )
            else:
                ulog.data_list[0].data["z_reset_counter"][2:] = 8
            with (
                self.subTest(carrier=carrier),
                self.assertRaisesRegex(Unavailable, "home origin"),
            ):
                altitude_samples(estimates, homes, 10, 100, ulog=ulog)

    def test_global_carrier_at_lower_bound_cannot_prove_prior_reset_state(self):
        estimates, homes = positions([1.5])
        estimates[0].update(timestamp=4, timestamp_sample=3)
        with self.assertRaisesRegex(Unavailable, "preceding global"):
            altitude_samples(estimates, homes, 10, 100)

    def test_first_logged_valid_home_cannot_invent_an_establishment_boundary(self):
        estimates, homes = positions([1.5])
        with self.assertRaisesRegex(Unavailable, "observed vertical-value transition"):
            altitude_samples(estimates, homes[1:], 10, 100)

    def test_reset_between_establishment_and_yaw_republish_is_not_hidden(self):
        estimates, homes = positions([1.5])
        homes.append({**homes[-1], "timestamp": 9})
        estimates.insert(
            1,
            {
                **estimates[0],
                "timestamp": 8,
                "timestamp_sample": 7,
                "alt_reset_counter": 8,
            },
        )
        estimates[-1]["alt_reset_counter"] = 8
        with self.assertRaisesRegex(Unavailable, "home origin"):
            altitude_samples(estimates, homes, 10, 100)

    def test_count_only_local_update_does_not_advance_the_vertical_bound(self):
        _, homes = positions([])
        homes.append({**homes[-1], "timestamp": 8, "update_count": 4})
        homes.append({**homes[-1], "timestamp": 9})
        self.assertEqual(home_origin_bound(homes, len(homes) - 1), 4)

    def test_equal_but_noncontiguous_history_does_not_extend_the_bound(self):
        _, homes = positions([])
        homes.extend(
            [
                {**homes[-1], "timestamp": 7, "alt": 1.0},
                {**homes[-1], "timestamp": 8},
                {**homes[-1], "timestamp": 9},
            ]
        )
        self.assertEqual(home_origin_bound(homes, len(homes) - 1), 7)


if __name__ == "__main__":
    unittest.main()
