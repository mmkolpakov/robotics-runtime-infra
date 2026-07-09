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


def allocate(run_id: str) -> int:
    digest = hashlib.sha256(run_id.encode("utf-8")).hexdigest()
    return int(digest[:8], 16) % 100 + 1


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

    domain_id = allocate(run_id)
    started = time.time()
    while True:
        try:
            fd = os.open(str(lock_path), os.O_CREAT | os.O_EXCL | os.O_WRONLY)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                handle.write(f"{run_id}:{domain_id}\n")
            break
        except FileExistsError:
            if time.time() - started > 30:
                print("timed out waiting for domain-id lock", file=sys.stderr)
                return 3
            time.sleep(0.05)

    payload = {
        "run_id": run_id,
        "ros_domain_id": domain_id,
        "range": {"min": 1, "max": 100},
        "formula": "sha256(run_id)[:8] % 100 + 1",
    }
    out_path.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.remove(lock_path)
    print(domain_id)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
