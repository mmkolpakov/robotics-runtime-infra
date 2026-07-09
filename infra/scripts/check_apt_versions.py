#!/usr/bin/env python3
"""Parse apt-cache policy Candidate lines without shell awk."""

from __future__ import annotations

import argparse
import sys
from pathlib import Path


def candidate_from_policy(text: str) -> str | None:
    for line in text.splitlines():
        stripped = line.strip()
        if stripped.startswith("Candidate:"):
            return stripped.split(":", 1)[1].strip()
    return None


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--policy-file", type=Path)
    parser.add_argument("--package-refs", type=Path)
    args = parser.parse_args()

    if args.policy_file is not None:
        value = candidate_from_policy(args.policy_file.read_text(encoding="utf-8"))
        if value is None:
            print("Candidate not found", file=sys.stderr)
            return 2
        print(value)
        return 0

    if args.package_refs is None:
        print("provide --policy-file or --package-refs", file=sys.stderr)
        return 2

    # package-refs mode is exercised inside the container by Makefile helper.
    for line in args.package_refs.read_text(encoding="utf-8").splitlines():
        if not line.strip():
            continue
        print(line)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
