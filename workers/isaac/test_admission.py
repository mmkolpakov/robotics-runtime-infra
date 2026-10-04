"""Pure source-profile admission tests; these do not qualify GPU execution."""

from __future__ import annotations

import importlib.util
import unittest
from pathlib import Path

SOURCE = Path(__file__).with_name("admission.py")
SPEC = importlib.util.spec_from_file_location("isaac_admission", SOURCE)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


class AdmissionTest(unittest.TestCase):
    def facts(self) -> dict[str, object]:
        return {
            "os": "linux",
            "distribution": "ubuntu",
            "release": "24.04",
            "kernel": "6.8.0-generic",
            "nvidia_container_runtime": True,
            "compatibility_checker_passed": True,
        }

    def test_selected_profile_accepts_observed_complete_facts(self) -> None:
        MODULE.refuse_unsupported_environment(self.facts())

    def test_wsl_does_not_qualify_selected_native_profile(self) -> None:
        facts = self.facts()
        facts["kernel"] = "6.18.33.2-microsoft-standard-WSL2"
        with self.assertRaisesRegex(ValueError, "WSL"):
            MODULE.refuse_unsupported_environment(facts)

    def test_cuda_discovery_without_checker_does_not_qualify_renderer(self) -> None:
        facts = self.facts()
        facts["compatibility_checker_passed"] = False
        with self.assertRaisesRegex(ValueError, "Compatibility Checker"):
            MODULE.refuse_unsupported_environment(facts)

    def test_other_os_and_missing_native_runtime_are_refused(self) -> None:
        for change in [
            {"os": "windows"},
            {"release": "26.04"},
            {"nvidia_container_runtime": False},
            {"kernel": None},
        ]:
            with self.subTest(change=change), self.assertRaises(ValueError):
                MODULE.refuse_unsupported_environment(self.facts() | change)


if __name__ == "__main__":
    unittest.main()
