from __future__ import annotations

from infra.scripts.check_apt_versions import candidate_from_policy


def test_candidate_from_policy() -> None:
    sample = """
Package: ros-jazzy-mavros
Version: 2.14.0-1noble
Candidate: 2.14.0-1noble.20260615.151804
Version table:
*** 2.14.0-1noble.20260615.151804 500
"""
    assert candidate_from_policy(sample) == "2.14.0-1noble.20260615.151804"
