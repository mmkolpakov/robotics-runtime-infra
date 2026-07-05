# droning-simulation-infra

Инфраструктурный контур для проверки симуляционного стека дронов в Docker.

## Назначение

Репозиторий фиксирует воспроизводимую базу для локальных и CI-проверок:

- ROS 2 Jazzy на Ubuntu 24.04 Noble;
- Gazebo Sim 8.11.0 через ROS-Gazebo;
- MAVROS и MAVLink;
- MoveIt2 и ros2_control;
- OpenCV для Python через системные пакеты Ubuntu;
- rosbag2 с хранилищем MCAP;
- базовый smoke-контроль ArduPilot SITL-образа.

GPU не является обязательным требованием для текущего контура.

## Зафиксированный состав

Источник состава стека: `infra/stack/simulation-stack.json`.

| Компонент | Версия или образ |
| --- | --- |
| Базовый ROS-образ | `osrf/ros:jazzy-simulation`, digest `sha256:acb7c427deb2aaa5acd0fdfa5f6cca9ad2055a64102b4667986b70d550dc469d` |
| Локальный образ проекта | `droning/ros-jazzy-mavros-gazebo:2026-07-05` |
| Ubuntu | `24.04 Noble` |
| ROS 2 | `Jazzy` |
| Gazebo Sim | `8.11.0` |
| ROS-Gazebo | `ros-jazzy-ros-gz` `1.0.22-1noble.20260616.074726` |
| Gazebo bridge | `ros-jazzy-ros-gz-bridge` `1.0.22-1noble.20260615.142443` |
| Gazebo sim | `ros-jazzy-ros-gz-sim` `1.0.22-1noble.20260615.173223` |
| MAVROS | `ros-jazzy-mavros` `2.14.0-1noble.20260615.151804` |
| MAVROS extras | `ros-jazzy-mavros-extras` `2.14.0-1noble.20260615.154428` |
| MAVROS messages | `ros-jazzy-mavros-msgs` `2.14.0-1noble.20260615.130828` |
| MAVLink | `ros-jazzy-mavlink` `2026.3.3-1noble.20260303.233645` |
| MoveIt2 | `ros-jazzy-moveit` `2.12.4-1noble.20260617.161956` |
| MoveIt move_group | `ros-jazzy-moveit-ros-move-group` `2.12.4-1noble.20260617.150300` |
| ros2_control | `ros-jazzy-ros2-control` `4.45.2-1noble.20260615.175135` |
| ros2_controllers | `ros-jazzy-ros2-controllers` `4.40.1-1noble.20260616.074625` |
| controller_manager | `ros-jazzy-controller-manager` `4.45.2-1noble.20260615.164916` |
| joint_trajectory_controller | `ros-jazzy-joint-trajectory-controller` `4.40.1-1noble.20260615.171409` |
| ros2controlcli | `ros-jazzy-ros2controlcli` `4.45.2-1noble.20260615.165650` |
| OpenCV для Python | `python3-opencv` `4.6.0+dfsg-13.1ubuntu1`; в контейнере `cv2` `4.6.0` |
| cv_bridge | `ros-jazzy-cv-bridge` `4.1.0-1noble.20260615.144656` |
| vision_opencv | `ros-jazzy-vision-opencv` `4.1.0-1noble.20260615.154006` |
| rosbag2 | `ros-jazzy-rosbag2` `0.26.11-1noble.20260616.084050` |
| rosbag2 MCAP | `ros-jazzy-rosbag2-storage-mcap` `0.26.11-1noble.20260616.074830` |
| ArduPilot base | `ardupilot/ardupilot-dev-base:v0.2.0` |
| PX4 SITL, не блокирует релиз | `px4io/px4-sitl-gazebo:v1.18.0-alpha1-amd64` |

## Инструменты проверки

| Инструмент | Версия |
| --- | --- |
| check-jsonschema | `0.37.4` |
| yamllint | `1.38.0` |
| Образ Trivy | `aquasec/trivy:0.72.0` |

## Требования

- WSL2 или Linux;
- Docker;
- `make`;
- `python3`;
- `jq`.

Для локальной проверки инструментов:

```bash
python3 -m venv .venv
. .venv/bin/activate
python -m pip install -r requirements-dev.txt
```

## Основные команды

```bash
make validate
make docker-build
make docker-smoke
make docker-update-check
make security-scan
make ci
```

`make ci` выполняет полный локальный прогон: проверку контрактов, сборку образа, smoke-проверки,
сверку зафиксированных пакетов и SARIF-отчет Trivy.

## Структура

```txt
.devcontainer/                       Dev Container
.github/                             CI, update-check, Dependabot
contracts/infra/stack.schema.json    JSON Schema контракта стека
infra/docker/                        Dockerfile симуляционного образа
infra/stack/simulation-stack.json    зафиксированный состав стека
Makefile                             единая точка входа для локальных и CI-проверок
requirements-dev.txt                 инструменты валидации
```

## Артефакты

Локальные отчеты пишутся в `artifacts/` и не попадают в Git.
