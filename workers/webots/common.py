"""Finite worker evidence files; no contract or signed subject serialization."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path


def write_json(path: Path, value: object) -> None:
    raw = (json.dumps(value, indent=2, allow_nan=False) + "\n").encode()
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("wb") as stream:
        stream.write(raw)
        stream.flush()
        os.fsync(stream.fileno())
    os.replace(temporary, path)


def reference(path: Path) -> dict[str, object]:
    with path.open("rb") as stream:
        digest = hashlib.file_digest(stream, "sha256").hexdigest()
    return {
        "uri": path.resolve().as_uri(),
        "sha256": digest,
        "size_bytes": path.stat().st_size,
    }
