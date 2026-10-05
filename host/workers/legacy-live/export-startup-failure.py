"""Export all available immutable startup failure files before owned teardown."""

from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

sys.path.insert(0, "/opt/robotics/finalizer/workers")
from export_retained import export

p = argparse.ArgumentParser()
p.add_argument("--source", type=Path, required=True)
p.add_argument("--destination", type=Path, required=True)
p.add_argument("--run-id", required=True)
a = p.parse_args()
entries = []
for path in sorted(a.source.rglob("*")):
    if path.is_file() and not path.is_symlink():
        rel = path.relative_to(a.source).as_posix()
        entries.append({"name": rel, "source": rel, "relativePath": rel})
result = export(
    {
        "version": 1,
        "runId": a.run_id,
        "sourceRoot": str(a.source),
        "destinationRoot": str(a.destination),
        "maximumBytes": 67108864,
        "entries": entries,
    }
)
print(json.dumps(result))
