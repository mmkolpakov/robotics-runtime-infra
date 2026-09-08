#!/usr/bin/env python3
"""Build the imported foundation packages for installation in runtime images."""

from __future__ import annotations

import argparse
import json
import os
import subprocess
import tomllib
from hashlib import sha256
from pathlib import Path


def build(source: Path, metadata: Path, python: str, output: Path) -> None:
    lock = json.loads(metadata.read_text(encoding="utf-8"))
    expected = lock["workspace"]
    if (
        sha256((source / "uv.lock").read_bytes()).hexdigest()
        != expected["uv_lock_sha256"]
    ):
        raise ValueError("foundation source uv.lock differs from the pinned workspace")
    for package in lock["packages"].values():
        project = tomllib.loads(
            (source / package["path"] / "pyproject.toml").read_text(encoding="utf-8")
        )["project"]
        if (project["name"], project["version"]) != (
            package["distribution"],
            package["version"],
        ):
            raise ValueError(
                "foundation package metadata differs from the pinned workspace"
            )
    if output.exists() and any(output.iterdir()):
        raise ValueError("foundation wheel output must be empty")
    output.mkdir(parents=True, exist_ok=True)
    subprocess.run(
        [
            "uv",
            "build",
            "--project",
            str(source),
            "--all-packages",
            "--wheel",
            "--no-sources",
            "--no-build-isolation",
            "--python",
            python,
            "--out-dir",
            str(output),
        ],
        env={**os.environ, "SOURCE_DATE_EPOCH": str(expected["source_date_epoch"])},
        check=True,
    )
    requirements = {}
    for key, package in lock["packages"].items():
        name = package["distribution"].replace("-", "_")
        wheel = output / f"{name}-{package['version']}-py3-none-any.whl"
        if not wheel.is_file():
            raise ValueError(f"missing foundation wheel: {wheel.name}")
        wheel_digest = sha256(wheel.read_bytes()).hexdigest()
        requirements[key] = f"./{wheel.name} --hash=sha256:{wheel_digest}\n"
    if len(list(output.glob("*.whl"))) != len(requirements):
        raise ValueError("unexpected wheel in foundation build output")
    (output / "contracts.requirements").write_text(
        requirements["contracts"], newline="\n"
    )
    (output / "harness.requirements").write_text(
        "".join(requirements.values()), newline="\n"
    )


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source", type=Path, required=True)
    parser.add_argument("--metadata", type=Path, required=True)
    parser.add_argument("--python", required=True)
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    try:
        build(args.source.resolve(), args.metadata, args.python, args.output.resolve())
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as exc:
        parser.exit(1, f"foundation wheels: {exc}\n")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
