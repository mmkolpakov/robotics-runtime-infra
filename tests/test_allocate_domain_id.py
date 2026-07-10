from __future__ import annotations

import json
import time
from pathlib import Path

from infra.scripts.allocate_domain_id import (
    DOMAIN_MAX,
    DOMAIN_MIN,
    _is_stale_lock,
    allocate,
    preferred_domain_id,
)


def test_preferred_domain_id_range() -> None:
    value = preferred_domain_id("foundation-a")
    assert DOMAIN_MIN <= value <= DOMAIN_MAX


def test_preferred_domain_id_deterministic() -> None:
    assert preferred_domain_id("foundation-a") == preferred_domain_id("foundation-a")
    assert preferred_domain_id("foundation-a") != preferred_domain_id("foundation-b")


def test_allocate_without_collision_uses_preferred_id(tmp_path: Path) -> None:
    domain_id, collided = allocate("no-collision-run", tmp_path)
    assert domain_id == preferred_domain_id("no-collision-run")
    assert collided is False


def _write_allocation(runs_root: Path, run_id: str, domain_id: int) -> None:
    run_dir = runs_root / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    (run_dir / "domain-id-allocation.json").write_text(
        json.dumps({"run_id": run_id, "ros_domain_id": domain_id}), encoding="utf-8"
    )


def test_allocate_probes_forward_on_active_collision(tmp_path: Path) -> None:
    run_id = "colliding-run"
    preferred = preferred_domain_id(run_id)
    # Simulate another active run that already holds the preferred id.
    _write_allocation(tmp_path, "other-active-run", preferred)

    domain_id, collided = allocate(run_id, tmp_path)
    assert collided is True
    assert domain_id != preferred
    assert DOMAIN_MIN <= domain_id <= DOMAIN_MAX


def test_allocate_ignores_its_own_previous_allocation(tmp_path: Path) -> None:
    run_id = "re-allocated-run"
    preferred = preferred_domain_id(run_id)
    _write_allocation(tmp_path, run_id, preferred)

    domain_id, collided = allocate(run_id, tmp_path)
    assert domain_id == preferred
    assert collided is False


def test_allocate_skips_multiple_colliding_ids(tmp_path: Path) -> None:
    run_id = "multi-collision-run"
    preferred = preferred_domain_id(run_id)
    span = DOMAIN_MAX - DOMAIN_MIN + 1
    for offset in range(3):
        other_id = (preferred - DOMAIN_MIN + offset) % span + DOMAIN_MIN
        _write_allocation(tmp_path, f"blocker-{offset}", other_id)

    domain_id, collided = allocate(run_id, tmp_path)
    assert collided is True
    assert domain_id == (preferred - DOMAIN_MIN + 3) % span + DOMAIN_MIN


def test_lock_within_ttl_is_not_stale(tmp_path: Path) -> None:
    lock_path = tmp_path / "domain-id.lock"
    lock_path.write_text(f"{time.time()}\n", encoding="utf-8")
    assert _is_stale_lock(lock_path) is False


def test_lock_past_ttl_is_stale(tmp_path: Path) -> None:
    lock_path = tmp_path / "domain-id.lock"
    ancient = time.time() - 3600
    lock_path.write_text(f"{ancient}\n", encoding="utf-8")
    assert _is_stale_lock(lock_path, ttl_sec=30.0) is True


def test_lock_with_unrecognized_content_is_stale(tmp_path: Path) -> None:
    lock_path = tmp_path / "domain-id.lock"
    lock_path.write_text("not-a-valid-lock-body", encoding="utf-8")
    assert _is_stale_lock(lock_path) is True


def test_allocate_run_recovers_from_a_stale_lock(tmp_path: Path) -> None:
    from infra.scripts.allocate_domain_id import main

    runs_root = tmp_path / "runs"
    lock_dir = runs_root / ".locks"
    lock_dir.mkdir(parents=True)
    (lock_dir / "domain-id.lock").write_text(f"{time.time() - 3600}\n", encoding="utf-8")

    exit_code = main(["--run-id", "recovered-run", "--runs-root", str(runs_root)])
    assert exit_code == 0
    assert not (lock_dir / "domain-id.lock").exists()
    assert (runs_root / "recovered-run" / "domain-id-allocation.json").is_file()
