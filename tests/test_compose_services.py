"""`pytest-docker` owns the Docker Compose service lifecycle for the one
long-running, health-checked service in the stack (build, `up --wait`
respecting the service's own `HEALTHCHECK`, and `down` on teardown).

The per-scenario, per-`RUN_ID` `ROS_DOMAIN_ID`-isolated `docker compose run
--rm` smokes (compose-smoke, integration-smoke, ...) stay Makefile-driven:
`pytest-docker`'s session-scoped compose-file model does not fit one-shot
`run --rm` containers with a freshly allocated domain id per invocation.
"""

from __future__ import annotations

import os
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]


@pytest.fixture(scope="session")
def docker_compose_file() -> str:
    return str(ROOT / "compose.yaml")


@pytest.fixture(scope="session")
def docker_compose_project_name() -> str:
    run_id = os.environ.get("RUN_ID", "pytest-docker")
    return f"robotics-{run_id}"


@pytest.fixture(scope="session")
def docker_setup() -> list[str]:
    # `simulation-dev` is the one long-running (`sleep infinity`), health
    # checked service in the stack -- the others are one-shot
    # `docker compose run --rm` smoke commands, which is not the lifecycle
    # `pytest-docker` models. Reuses the image `compose-build` already
    # built earlier in the same CI job (`--no-build`); `IMAGE_TAG` must be
    # set in the environment this pytest process runs in.
    return ["--profile dev up -d --wait --no-build simulation-dev"]


@pytest.fixture(scope="session")
def docker_cleanup() -> list[str]:
    return ["--profile dev down --remove-orphans"]


def test_simulation_dev_service_is_healthy(
    docker_services, docker_compose_project_name: str
) -> None:
    # `docker_services` blocks until `docker_setup` (`up --wait`)
    # completes; `--wait` already fails closed if the compose healthcheck
    # (real `ros2 pkg prefix ros_gz_sim/ros_gz_bridge/mavros` checks) never
    # turns healthy, so reaching this line is itself the assertion that
    # `pytest-docker` correctly manages this service's lifecycle.
    inspected = subprocess.run(
        [
            "docker",
            "compose",
            "-f",
            str(ROOT / "compose.yaml"),
            "-p",
            docker_compose_project_name,
            "--profile",
            "dev",
            "ps",
            "--format",
            "{{.Health}}",
            "simulation-dev",
        ],
        check=True,
        capture_output=True,
        text=True,
    )
    assert "healthy" in inspected.stdout.strip().lower()
