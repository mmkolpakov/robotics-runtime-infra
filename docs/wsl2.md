# WSL2

WSL2 is a developer and software-qualification host. It is not a physical
robot or HIL qualification target.

## Supported Paths

| Path | Status | Requirement |
| --- | --- | --- |
| Headless CPU simulation | Supported | Docker Desktop WSL2 integration |
| Playback, recording, evidence, and acceptance | Supported | Repository and run data on the Linux filesystem |
| Intel GPU inference | Qualification-gated | `/dev/dxg` and a dedicated protected runner |
| NVIDIA GPU inference | Qualification-gated | NVIDIA WSL driver and Container Toolkit support |
| Serial, CAN, PTP, HIL, and real observation | Unsupported for qualification | Use a native Ubuntu 24.04 host |

## Preflight

Run these commands inside the WSL2 distribution:

```bash
test "$(stat -f -c %T .)" != 9p
docker compose version
docker info --format '{{.OSType}}/{{.Architecture}}'
docker compose config --quiet
```

Keep the checkout and `runs/` under the WSL2 ext4 filesystem. DrvFS mounts
without POSIX metadata cannot preserve the ownership and modes required for
immutable evidence receipts and therefore fail closed.

Use a unique Compose project name, ROS domain, and Gazebo partition for every
concurrent run:

```bash
export COMPOSE_PROJECT_NAME="robotics-${USER}-$$"
export ROS_DOMAIN_ID=87
export GZ_PARTITION="${COMPOSE_PROJECT_NAME}"
docker compose up --detach --wait simulation
```

The headless path does not require X11, Wayland, or a desktop display. Stop only
the selected Compose project with `docker compose down`; do not use global
Docker cleanup on a shared development host.
