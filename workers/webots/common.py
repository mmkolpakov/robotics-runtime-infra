"""Finite worker evidence files; no contract or signed subject serialization."""

from __future__ import annotations

import hashlib
import json
import os
from pathlib import Path


def write_json(path: Path, value: object) -> None:
    raw = (json.dumps(value, indent=2, allow_nan=False) + "\n").encode()
    write_bytes(path, raw)


def write_bytes(path: Path, raw: bytes) -> None:
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


MODEL_MANIFEST_SHA256 = (
    "539138daf0df5112d15bafe6834da027ea8b6c78295635cd1c17183ca2f78d54"
)


def model_inputs(
    root: Path, world_sha: str, proto_sha: str
) -> dict[str, dict[str, object]]:
    """Only the byte-reviewed native probe's two local inputs are supported."""
    raw = (root / "upstream.json").read_bytes()
    if hashlib.sha256(raw).hexdigest() != MODEL_MANIFEST_SHA256:
        raise ValueError("selected worker asset manifest bytes differ")
    selected = json.loads(raw)["model_inputs"]
    observed = {}
    for name, path, requested in (
        ("world", "worlds/native.wbt", world_sha),
        ("proto", "protos/NativeProbe.proto", proto_sha),
    ):
        expected = selected[name]
        actual = reference(root / path)
        if (
            expected["path"] != path
            or actual["sha256"] != expected["sha256"]
            or actual["size_bytes"] != expected["size_bytes"]
            or requested != expected["sha256"]
        ):
            raise ValueError(
                "native model input bytes differ from the reviewed fixture"
            )
        observed[name] = actual
    return observed
