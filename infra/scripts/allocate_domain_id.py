#!/usr/bin/env python3
"""Allocate a deterministic ROS_DOMAIN_ID for a run."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import sys
import time
from pathlib import Path


DOMAIN_MIN = 1
DOMAIN_MAX = 100


def preferred_domain_id(run_id: str) -> int:
    digest = hashlib.sha256(run_id.encode("utf-8")).hexdigest()
    return int(digest[:8], 16) % (DOMAIN_MAX - DOMAIN_MIN + 1) + DOMAIN_MIN


def _active_allocations(runs_root: Path, *, exclude_run_id: str) -> dict[int, str]:
    """Domain ids currently claimed by other runs' allocation records.

    A run's allocation file is treated as active until that run directory is
    removed (or `clean`ed), which is the harness/infra convention for
    finished runs. This does not require a separate release call: an
    unreleased stale record simply means that domain id is unavailable for
    reuse until the run directory is cleaned up, which is a safe (if
    conservative) default for a namespace of 100 ids.
    """
    taken: dict[int, str] = {}
    if not runs_root.is_dir():
        return taken
    for entry in runs_root.iterdir():
        if not entry.is_dir() or entry.name in {exclude_run_id, ".locks", "current"}:
            continue
        allocation_file = entry / "domain-id-allocation.json"
        if not allocation_file.is_file():
            continue
        try:
            data = json.loads(allocation_file.read_text(encoding="utf-8"))
        except (OSError, ValueError):
            continue
        other_run_id = data.get("run_id")
        domain_id = data.get("ros_domain_id")
        if isinstance(domain_id, int) and other_run_id:
            taken[domain_id] = str(other_run_id)
    return taken


def allocate(run_id: str, runs_root: Path) -> tuple[int, bool]:
    """Return `(domain_id, collided)` for `run_id`.

    `collided` is True when the hash-preferred id was already claimed by a
    *different* active run_id and a free id had to be probed for instead.
    """
    preferred = preferred_domain_id(run_id)
    taken = _active_allocations(runs_root, exclude_run_id=run_id)
    if preferred not in taken:
        return preferred, False
    for offset in range(1, DOMAIN_MAX - DOMAIN_MIN + 1):
        candidate = (preferred - DOMAIN_MIN + offset) % (DOMAIN_MAX - DOMAIN_MIN + 1) + DOMAIN_MIN
        if candidate not in taken:
            return candidate, True
    raise RuntimeError(f"no free ROS_DOMAIN_ID in [{DOMAIN_MIN}, {DOMAIN_MAX}]")


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--runs-root", default="runs")
    args = parser.parse_args()

    run_id = args.run_id.strip()
    if not run_id:
        print("RUN_ID must be non-empty", file=sys.stderr)
        return 2

    runs_root = Path(args.runs_root)
    run_dir = runs_root / run_id
    run_dir.mkdir(parents=True, exist_ok=True)
    lock_dir = runs_root / ".locks"
    lock_dir.mkdir(parents=True, exist_ok=True)
    lock_path = lock_dir / "domain-id.lock"
    out_path = run_dir / "domain-id-allocation.json"

    started = time.time()
    while True:
        try:
            fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            break
        except FileExistsError:
            if time.time() - started > 30:
                print("timed out waiting for domain-id lock", file=sys.stderr)
                return 3
            time.sleep(0.05)

    try:
        domain_id, collided = allocate(run_id, runs_root)
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(f"{run_id}:{domain_id}\n")
    finally:
        os.remove(lock_path)

    payload = {
        "run_id": run_id,
        "ros_domain_id": domain_id,
        "range": {"min": DOMAIN_MIN, "max": DOMAIN_MAX},
        "formula": "sha256(run_id)[:8] % 100 + 1, probed forward on active collision",
        "collision_probed": collided,
    }
    out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    print(domain_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
