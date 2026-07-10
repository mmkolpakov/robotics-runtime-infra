#!/usr/bin/env python3
"""Regenerate machine-readable `*.json` contract files from their
human-edited `*.yaml` sources.

Large contract data files (capability profiles, extension boundaries) are
easier to read, comment, and diff as YAML than as plain JSON. Contributors
edit the `.yaml` source; `check-jsonschema`, `jq`, and every other consumer
in this repo keep reading the generated `.json` sibling, produced here.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import yaml

REPO_ROOT = Path(__file__).resolve().parents[2]

# (yaml source, generated json) pairs, relative to the repo root.
SOURCES = [
    ("infra/stack/runtime-profiles.yaml", "infra/stack/runtime-profiles.json"),
]


def synced_json(yaml_path: Path) -> str:
    data = yaml.safe_load(yaml_path.read_text(encoding="utf-8"))
    return json.dumps(data, indent=2, ensure_ascii=False) + "\n"


def main(argv: list[str] | None = None) -> int:
    check_only = (argv if argv is not None else sys.argv[1:]) == ["--check"]
    stale: list[str] = []

    for yaml_rel, json_rel in SOURCES:
        yaml_path = REPO_ROOT / yaml_rel
        json_path = REPO_ROOT / json_rel
        rendered = synced_json(yaml_path)

        if check_only:
            current = json_path.read_text(encoding="utf-8") if json_path.is_file() else None
            if current != rendered:
                stale.append(json_rel)
            continue

        json_path.write_text(rendered, encoding="utf-8")
        print(f"synced {json_rel} from {yaml_rel}")

    if check_only and stale:
        for json_rel in stale:
            print(f"stale: {json_rel} does not match its .yaml source", file=sys.stderr)
        print("run: python3 infra/scripts/sync_contracts.py", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
