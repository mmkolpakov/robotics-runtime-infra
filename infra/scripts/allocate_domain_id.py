#!/usr/bin/env python3
"""Allocate a deterministic ROS_DOMAIN_ID for a run."""

from __future__ import annotations

import argparse
import contextlib
import hashlib
import json
import os
import sys
import time
from pathlib import Path


DOMAIN_MIN = 1
DOMAIN_MAX = 100

# A bare `O_EXCL` lock file with no recovery path means one process that
# dies (crash, OOM-kill, CI runner cancellation) between creating the lock
# and removing it wedges every future allocation on this host until someone
# manually deletes the file. The lock now records its owner PID and
# creation time so a stale lock -- its owning PID is gone, or it has simply
# been held far longer than any real allocation ever takes -- can be
# reclaimed automatically instead of requiring manual recovery.
_LOCK_TTL_SEC = 30.0
_LOCK_WAIT_SEC = 30.0


def _is_stale_lock(lock_path: Path, *, ttl_sec: float = _LOCK_TTL_SEC) -> bool:
    try:
        raw = lock_path.read_text(encoding="utf-8").strip()
    except OSError:
        # Already gone (a concurrent racer reclaimed/removed it) or
        # unreadable: either way it cannot be blocking anyone, so it is
        # safe to treat as "not a lock we need to wait on".
        return True
    pid_str, _, created_str = raw.partition(":")
    try:
        pid = int(pid_str)
        created = float(created_str)
    except ValueError:
        # Content from before this format existed (or corrupted): cannot
        # prove it is live, so prefer availability over wedging forever.
        return True
    if time.time() - created > ttl_sec:
        return True
    if os.name != "posix":
        # No portable liveness check on Windows; TTL above is the only
        # recovery mechanism there.
        return False
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return True
    except PermissionError:
        return False
    return False


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


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--run-id", required=True)
    parser.add_argument("--runs-root", default="runs")
    args = parser.parse_args(argv)

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
        except FileExistsError:
            if _is_stale_lock(lock_path):
                with contextlib.suppress(FileNotFoundError):
                    lock_path.unlink()
                continue
            if time.time() - started > _LOCK_WAIT_SEC:
                print("timed out waiting for domain-id lock", file=sys.stderr)
                return 3
            time.sleep(0.05)
            continue
        with os.fdopen(fd, "w", encoding="utf-8") as handle:
            handle.write(f"{os.getpid()}:{time.time()}\n")
        break

    try:
        domain_id, collided = allocate(run_id, runs_root)
    finally:
        with contextlib.suppress(FileNotFoundError):
            lock_path.unlink()

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
