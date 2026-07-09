from __future__ import annotations

from infra.scripts.allocate_domain_id import allocate


def test_allocate_range() -> None:
    value = allocate("foundation-a")
    assert 1 <= value <= 100


def test_allocate_deterministic() -> None:
    assert allocate("foundation-a") == allocate("foundation-a")
    assert allocate("foundation-a") != allocate("foundation-b")
