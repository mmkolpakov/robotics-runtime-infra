"""Package exact subject bytes from a trusted consumer root.

The caller owns an immutable checkout, frozen producer inputs, and a single-writer
output parent. A successful exit and the final arguments file mark completion;
this helper does not provide a sandbox against concurrent hostile filesystem edits.
"""

from __future__ import annotations

import hashlib
import json
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path


def safe_path(value: str, root: Path, *, exists: bool = True) -> Path:
    path = Path(value).absolute()
    if any(ord(char) < 32 for char in value) or ".." in path.parts:
        raise ValueError(f"unsafe path: {value}")
    if any(parent.is_symlink() for parent in (path, *path.parents)):
        raise ValueError(f"symlink path is not supported: {value}")
    path = path.resolve(strict=exists)
    if not path.is_relative_to(root):
        raise ValueError(f"path is outside the consumer root: {value}")
    return path


def digest(path: Path) -> str:
    with path.open("rb") as stream:
        return hashlib.file_digest(stream, "sha256").hexdigest()


def parser_mode(path: Path) -> str:
    suffix = path.suffix.lower()
    if suffix in {".yaml", ".yml"}:
        return "yaml"
    return "json" if suffix == ".json" else "auto"


def statement(cli: str, arguments: list[str], output: Path) -> None:
    result = subprocess.run(
        [
            cli,
            "--format",
            "json",
            "qualification",
            "statement",
            *arguments,
            "--output",
            str(output),
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    if (
        json.loads(result.stdout).get("output") != str(output)
        or not output.stat().st_size
    ):
        raise ValueError("qualification CLI did not produce its declared statement")


def package(
    output: str, cli: str, schema_count: int, specifications: list[str]
) -> None:
    root = Path.cwd().resolve()
    destination = safe_path(output, root, exists=False)
    if destination.exists() or not destination.parent.is_dir():
        raise ValueError("output must be a new directory under an existing parent")
    entries: list[tuple[str, str, Path, str, str]] = []
    original: list[str] = []
    portable: list[str] = []
    for index, specification in enumerate(specifications):
        label, value = specification.split("=", 1)
        if label.startswith("-") or any(ord(char) < 32 for char in label):
            raise ValueError("unsafe artifact or schema label")
        source = safe_path(value, root)
        if not source.is_file():
            raise ValueError(f"required regular file: {source}")
        sha256 = digest(source)
        schema = index < schema_count
        subject = sha256 if schema else label.split(":", 1)[1]
        if schema:
            target = f"extension-schemas/{subject}/{source.name}"
        else:
            target = f"subjects/{subject}"
            # The public loader selects JSON, YAML, or content detection by suffix.
            # Preserve that mode without changing the logical statement subject.
            if parser_mode(source) != parser_mode(Path(subject)):
                target += source.suffix or ".data"
        option = "--extension-schema" if schema else "--artifact"
        entries.append((option, label, source, target, sha256))
        original.extend([option, f"{label}={source}"])
        portable.extend([option, f"{label}={target}"])
    artifact_targets = [
        target for option, _, _, target, _ in entries if option == "--artifact"
    ]
    if len(artifact_targets) != len(set(artifact_targets)):
        raise ValueError("artifact storage paths collide")
    targets = {target for _, _, _, target, _ in entries}
    if any(
        "/".join(Path(target).parts[:index]) in targets
        for target in targets
        for index in range(1, len(Path(target).parts))
    ):
        raise ValueError("subject file and directory paths collide")
    with tempfile.TemporaryDirectory(prefix="qualification-package-") as work:
        expected, staged = Path(work) / "expected.json", Path(work) / "staged.json"
        statement(cli, original, expected)
        destination.mkdir(mode=0o700)
        complete = False
        try:
            staged_arguments: list[str] = []
            for option, label, source, target, sha256 in entries:
                copied = destination / target
                copied.parent.mkdir(parents=True, exist_ok=True)
                if not copied.exists():
                    with source.open("rb") as incoming, copied.open("xb") as outgoing:
                        shutil.copyfileobj(incoming, outgoing)
                if (
                    digest(copied) != sha256
                    or digest(safe_path(str(source), root)) != sha256
                ):
                    raise ValueError(f"input changed during packaging: {target}")
                staged_arguments.extend([option, f"{label}={copied}"])
            statement(cli, staged_arguments, staged)
            if expected.read_bytes() != staged.read_bytes():
                raise ValueError("copied subjects differ from the validated statement")
            with (destination / "qualification-arguments.txt").open("x") as arguments:
                arguments.write("\n".join(portable) + "\n")
            complete = True
        finally:
            if not complete:
                shutil.rmtree(destination)


if __name__ == "__main__":
    try:
        package(sys.argv[1], sys.argv[2], int(sys.argv[3]), sys.argv[4:])
    except (
        OSError,
        ValueError,
        KeyError,
        AttributeError,
        subprocess.CalledProcessError,
    ) as error:
        print(f"qualification: {error}", file=sys.stderr)
        if isinstance(error, subprocess.CalledProcessError):
            print(error.stderr, file=sys.stderr, end="")
        sys.exit(65)
