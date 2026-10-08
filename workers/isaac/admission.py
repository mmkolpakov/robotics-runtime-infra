"""Admission for the selected native Linux/NVIDIA Isaac deployment profile."""

from __future__ import annotations

from collections.abc import Mapping
from typing import Any


def refuse_unsupported_environment(facts: Mapping[str, Any]) -> None:
    if facts.get("os") != "linux" or facts.get("distribution") != "ubuntu":
        raise ValueError("Isaac OCI profile requires native Ubuntu")
    if facts.get("release") != "24.04":
        raise ValueError("Isaac OCI profile selects Ubuntu 24.04")
    kernel = facts.get("kernel")
    if (
        not isinstance(kernel, str)
        or "microsoft" in kernel.lower()
        or "wsl" in kernel.lower()
    ):
        raise ValueError("this Isaac profile does not qualify WSL")
    if facts.get("nvidia_container_runtime") is not True:
        raise ValueError("native NVIDIA container runtime admission is incomplete")
    if facts.get("compatibility_checker_passed") is not True:
        raise ValueError("Isaac Compatibility Checker evidence is required")


def refuse_unsupported_windows_environment(facts: Mapping[str, Any]) -> None:
    if facts.get("os") != "windows" or facts.get("release") != "11":
        raise ValueError("Isaac standalone profile selects Windows 11")
    if facts.get("architecture") != "amd64":
        raise ValueError("Isaac standalone profile selects Windows amd64")
    if (
        facts.get("artifact_sha256")
        != "dc7cfc966cd0aea105e97bb1b9b30a8e91306a3254f231bca9caa5c97ae74ae9"
    ):
        raise ValueError(
            "Isaac standalone artifact identity is incomplete or mismatched"
        )
    if facts.get("compatibility_checker_passed") is not True:
        raise ValueError("Isaac Compatibility Checker evidence is required")
