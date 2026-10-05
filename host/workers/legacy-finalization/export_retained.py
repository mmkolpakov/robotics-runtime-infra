"""Copy an admitted finite inventory before release of its source resources.

This worker never decodes contract payloads. The host invokes the existing public
evaluator and qualification tools separately after retained export and cleanup.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import stat
import time
from pathlib import Path, PurePosixPath

CHUNK = 1024 * 1024


def relative(value: str) -> PurePosixPath:
    path = PurePosixPath(value)
    if (
        not value
        or value in (".", "..")
        or path.is_absolute()
        or any(p in ("", ".", "..") for p in path.parts)
    ):
        raise ValueError("unsafe retained relative path")
    if any(ord(c) < 32 or ord(c) == 127 for c in value):
        raise ValueError("control character in retained path")
    return path


def identity(value: os.stat_result) -> tuple[int, int, int, int, int]:
    return (
        value.st_dev,
        value.st_ino,
        value.st_size,
        value.st_mtime_ns,
        value.st_ctime_ns,
    )


def inside(path: Path, root: Path) -> Path:
    resolved = path.resolve(strict=True)
    if not resolved.is_relative_to(root):
        raise ValueError("inventory source escapes its admitted root")
    return resolved


def export(plan: dict[str, object]) -> dict[str, object]:
    if plan.get("version") != 1:
        raise ValueError("unsupported byte inventory")
    source = Path(str(plan["sourceRoot"])).resolve(strict=True)
    destination = Path(str(plan["destinationRoot"]))
    entries = plan["entries"]
    maximum = plan["maximumBytes"]
    if not source.is_dir() or not destination.is_absolute():
        raise ValueError("admitted roots must be absolute directories")
    if not isinstance(entries, list) or not entries or len(entries) > 4096:
        raise ValueError("finite nonempty inventory required")
    if (
        not isinstance(maximum, int)
        or isinstance(maximum, bool)
        or not 0 < maximum <= 1024**4
    ):
        raise ValueError("finite export byte bound required")
    # Check the entire inventory before acquiring a new destination.
    admitted = []
    names = set()
    paths = set()
    total = 0
    for item in entries:
        if not isinstance(item, dict):
            raise TypeError("inventory item must be an object")
        name = item["name"]
        if not isinstance(name, str) or not name or name in names:
            raise ValueError("inventory names must be unique")
        names.add(name)
        output = relative(str(item["relativePath"]))
        if str(output) in paths or str(output) in (
            "export-manifest.json",
            "export-incomplete.json",
        ):
            raise ValueError("inventory output paths must be unique")
        paths.add(str(output))
        declared = source / relative(str(item["source"]))
        # Links are not portable payload files and may redirect between admission and copy.
        cursor = declared
        while cursor != source:
            if cursor.is_symlink():
                raise ValueError("inventory contains a symbolic link")
            cursor = cursor.parent
        actual = inside(declared, source)
        facts = actual.stat()
        if not stat.S_ISREG(facts.st_mode):
            raise ValueError("inventory source is not a regular file")
        if "size_bytes" in item and item["size_bytes"] != facts.st_size:
            raise ValueError("admitted source size differs")
        total += facts.st_size
        if total > maximum:
            raise ValueError("inventory exceeds its byte bound")
        admitted.append((item, actual, output, identity(facts)))
    parent = destination.parent.resolve(strict=True)
    final = parent / destination.name
    if final.is_relative_to(source) or source.is_relative_to(final):
        raise ValueError("source and retained destination must have distinct lifetimes")
    # Never overwrite an earlier attempt: an incomplete attempt is retained for diagnosis.
    final.mkdir(mode=0o750, exist_ok=False)
    completed = []
    started = time.time_ns()
    try:
        for item, actual, output, before in admitted:
            target = final / output
            target.parent.mkdir(mode=0o750, parents=True, exist_ok=True)
            digest = hashlib.sha256()
            count = 0
            with actual.open("rb") as reader, target.open("xb") as writer:
                if identity(os.fstat(reader.fileno())) != before:
                    raise ValueError("source changed after admission")
                while block := reader.read(CHUNK):
                    count += len(block)
                    if count > before[2]:
                        raise ValueError("source grew during export")
                    digest.update(block)
                    writer.write(block)
                writer.flush()
                os.fsync(writer.fileno())
                if (
                    identity(os.fstat(reader.fileno())) != before
                    or identity(actual.stat()) != before
                ):
                    raise ValueError("source changed during export")
            sha = digest.hexdigest()
            if count != before[2] or ("sha256" in item and item["sha256"] != sha):
                raise ValueError("export differs from admitted source bytes")
            # Read the retained bytes independently; they are the artifacts released to consumers.
            with target.open("rb") as retained:
                copied = hashlib.file_digest(retained, "sha256").hexdigest()
            if copied != sha or target.stat().st_size != count:
                raise ValueError("retained bytes differ from source")
            target.chmod(0o440)
            completed.append(
                {
                    "name": item["name"],
                    "relativePath": str(output),
                    "sha256": sha,
                    "size_bytes": count,
                }
            )
        result = {
            "version": 1,
            "status": "complete",
            "runId": plan["runId"],
            "entries": completed,
            "totalBytes": total,
            "startedUnixNs": str(started),
            "completedUnixNs": str(time.time_ns()),
        }
        manifest = final / "export-manifest.json"
        with manifest.open("x", encoding="utf-8") as writer:
            json.dump(result, writer, sort_keys=True, indent=2)
            writer.write("\n")
            writer.flush()
            os.fsync(writer.fileno())
        manifest.chmod(0o440)
        directory = os.open(final, os.O_DIRECTORY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
        return result
    except BaseException as error:
        (final / "export-incomplete.json").write_text(
            json.dumps(
                {
                    "version": 1,
                    "status": "incomplete",
                    "runId": plan.get("runId"),
                    "completedEntries": completed,
                    "error": str(error),
                },
                indent=2,
            )
            + "\n",
            encoding="utf-8",
        )
        raise


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--plan", type=Path, required=True)
    args = parser.parse_args()
    result = export(json.loads(args.plan.read_bytes()))
    print(json.dumps(result, sort_keys=True))


if __name__ == "__main__":
    main()
