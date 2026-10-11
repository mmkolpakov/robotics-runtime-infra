"""Check candidate wheel storage against this consumer's committed SDK policy."""

from __future__ import annotations

import argparse
import hashlib
import json
from pathlib import Path

POLICY = Path(__file__).with_name("inputs.lock.json")


def check(wheels: Path) -> None:
    expected = json.loads(POLICY.read_bytes())["sdk_test_cohort"]["wheels"]
    for name, digest in expected.items():
        path = wheels / name
        if path.is_symlink() or not path.is_file():
            raise ValueError("SDK wheel must be a regular stored file")
        with path.open("rb") as stream:
            observed = hashlib.file_digest(stream, "sha256").hexdigest()
        if observed != digest:
            raise ValueError("SDK wheel differs from committed cohort policy")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("wheels", type=Path)
    arguments = parser.parse_args()
    check(arguments.wheels)


if __name__ == "__main__":
    main()
