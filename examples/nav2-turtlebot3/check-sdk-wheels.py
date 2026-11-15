"""Check bounded wheel bytes against this consumer's committed published SDK policy."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
from pathlib import Path

POLICY = Path(__file__).with_name("inputs.lock.json")


def check(wheels: Path, *, include_native_evaluator=False) -> None:
    policy = json.loads(POLICY.read_bytes())
    expected = policy["sdk_cohort"]["wheels"]
    if include_native_evaluator:
        evaluator = policy["native_evaluator"]
        expected[evaluator["filename"]] = evaluator
    if not all(hasattr(os, flag) for flag in ("O_NOFOLLOW", "O_NONBLOCK")):
        raise ValueError("SDK policy check requires POSIX no-follow/nonblocking opens")
    for name, identity in expected.items():
        path = Path(os.path.abspath(wheels / name))
        if path.is_symlink() or path.resolve(strict=True) != path.absolute():
            raise ValueError("SDK wheel must be a regular stored file without symlinks")
        descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
        with os.fdopen(descriptor, "rb") as stream:
            before = os.fstat(stream.fileno())
            size = identity["size_bytes"]
            if not stat.S_ISREG(before.st_mode) or before.st_size != size:
                raise ValueError("SDK wheel differs from committed cohort policy")
            raw = stream.read(size + 1)
            after = os.fstat(stream.fileno())
        fields = ("st_dev", "st_ino", "st_size", "st_mtime_ns", "st_ctime_ns")
        if (
            len(raw) != size
            or hashlib.sha256(raw).hexdigest() != identity["sha256"]
            or any(getattr(before, field) != getattr(after, field) for field in fields)
        ):
            raise ValueError("SDK wheel differs from committed cohort policy")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wheels", type=Path)
    parser.add_argument("--include-native-evaluator", action="store_true")
    arguments = parser.parse_args()
    check(arguments.wheels, include_native_evaluator=arguments.include_native_evaluator)


if __name__ == "__main__":
    main()
