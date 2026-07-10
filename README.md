# robotics-simulation-infra

Инфраструктурный контур для проверки робототехнического симуляционного стека в Docker.

## Назначение

Репозиторий фиксирует воспроизводимую базу для локальных и CI-проверок. В состав входят:

- ROS 2 Jazzy на Ubuntu 24.04 Noble;
- Gazebo Sim 8.11.0 через ROS-Gazebo;
- MAVROS и MAVLink;
- MoveIt2 и ros2_control;
- OpenCV для Python через системные пакеты Ubuntu;
- rosbag2 с хранилищем MCAP;
- Docker Compose профили для явных вариантов запуска;
- Docker Buildx Bake для декларативной сборки образов;
- дополнительные профили DDS, связи, медиа, диагностики и ARM64 edge;
- базовый smoke-контроль образов для симуляции и SITL;
- интеграционный smoke-контроль ROS 2, Gazebo и MAVROS через `pytest` + `launch_testing_ros`;
- `pytest-docker` для управления жизненным циклом долгоживущих Compose-сервисов;
- JUnit XML отчеты по каждому прогону + подписанный SLSA Provenance (`slsa-github-generator`) вместо кастомного evidence manifest;
- release workflow для публикации OCI-образа в GHCR;
- SBOM, SARIF, Dockerfile lint и GitHub Actions lint для ревью.

GPU не является обязательным требованием для текущего контура.

Репозиторий не содержит прикладную логику, сценарии продукта или модели восприятия. Внешние проекты должны подключаться через стандартные границы ROS 2, MAVLink/MAVROS, ros2_control, Docker и rosbag2/MCAP.

## Зафиксированный состав

Источник состава стека: `infra/stack/simulation-stack.json`.

| Компонент | Версия или образ |
| --- | --- |
| Базовый ROS-образ | `osrf/ros:jazzy-simulation`, digest `sha256:acb7c427deb2aaa5acd0fdfa5f6cca9ad2055a64102b4667986b70d550dc469d` |
| Локальный образ проекта | `robotics/ros-jazzy-simulation:2026-07-05` |
| Ubuntu | `24.04 Noble` |
| ROS 2 | `Jazzy` |
| Gazebo Sim | `8.11.0` |
| ROS-Gazebo | `ros-jazzy-ros-gz` `1.0.22-1noble.20260616.074726` |
| Gazebo bridge | `ros-jazzy-ros-gz-bridge` `1.0.22-1noble.20260615.142443` |
| Gazebo sim | `ros-jazzy-ros-gz-sim` `1.0.22-1noble.20260615.173223` |
| Sensor messages | `ros-jazzy-sensor-msgs` `5.3.8-1noble.20260615.112429` |
| TF2 messages | `ros-jazzy-tf2-msgs` `0.36.21-1noble.20260615.112712` |
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
| image_transport | `ros-jazzy-image-transport` `5.1.8-1noble.20260615.144252` |
| rosbag2 | `ros-jazzy-rosbag2` `0.26.11-1noble.20260616.084050` |
| rosbag2 MCAP | `ros-jazzy-rosbag2-storage-mcap` `0.26.11-1noble.20260616.074830` |
| Artifact storage CLI | AWS CLI `2.35.17` via official Linux installer |
| ArduPilot base | `ardupilot/ardupilot-dev-base:v0.2.0` |
| PX4 SITL, не блокирует релиз | `px4io/px4-sitl-gazebo:v1.18.0-alpha1-amd64` |
| NVIDIA probe, опционально | `nvidia/cuda:12.9.2-base-ubuntu24.04` |
| NVIDIA PyTorch base, опционально | `nvcr.io/nvidia/pytorch:26.06-py3` |
| NVIDIA inference runtime, опционально | `robotics/accelerated-inference:2026-07-05` |
| ONNX Runtime GPU, опционально | `onnxruntime-gpu` `1.27.0` |
| Zenoh bridge, опционально | `eclipse/zenoh-bridge-ros2dds:1.9.0` |
| Jetson boundary, config-only | `nvcr.io/nvidia/l4t-jetpack:r36.4.0` |

## Профили возможностей

Источник профилей для правки: `infra/stack/runtime-profiles.yaml`
(человекочитаемый YAML). `make sync-contracts` (часть `make validate`)
генерирует из него `infra/stack/runtime-profiles.json`, который читают
`check-jsonschema`, `jq` и остальные потребители -- см.
`infra/scripts/sync_contracts.py`.

| Профиль | Compose | Статус | Назначение |
| --- | --- | --- | --- |
| `core_simulation` | default | `ready` | Базовая контейнерная среда ROS 2/Gazebo |
| `developer_workspace` | `dev` | `optional` | Фоновый рабочий контейнер для локальной или серверной разработки |
| `autopilot_sitl` | `autopilot` | `partial` | Готовность MAVLink/MAVROS и SITL-образов |
| `px4_sitl_runtime` | `px4` | `optional` | Проверка доступности среды PX4 SITL |
| `dds_bridge` | `dds` | `optional` | Micro XRCE-DDS Agent и граница DDS-моста |
| `comms_bridge` | `comms` | `optional` | Мост Zenoh для ROS 2/DDS |
| `manipulator_control` | default | `ready` | MoveIt2, ros2_control и контроллеры |
| `perception_runtime` | default | `partial` | OpenCV/cv_bridge и заменяемая граница восприятия |
| `sensor_simulation` | default, `render` | `partial` | Проверяемые интерфейсы камер, глубины, облаков точек и tf |
| `media_sensor_runtime` | `media` | `optional` | Среда GStreamer для потоков камеры и видео |
| `data_recording` | default | `ready` | rosbag2/MCAP, отчеты и артефакты проверки |
| `diagnostics_tools` | `diagnostics` | `optional` | PlotJuggler и локальная диагностика |
| `gpu_runtime_optional` | `nvidia` | `optional` | Проверка доступа контейнера к NVIDIA runtime |
| `accelerated_inference_runtime_optional` | `inference` | `optional` | ONNX Runtime GPU, PyTorch CUDA и TensorRT |
| `edge_nvidia_arm64` | `edge` | `optional` | ARM64 NVIDIA edge boundary, config-only на amd64 |
| `external_stack_extension` | default | `external` | Граница подключения внешних стеков поверх инфраструктуры |

Статус `ready` означает, что профиль входит в текущие обязательные проверки и закрыт на уровне инфраструктуры.
Статус `partial` означает, что проверяемая инфраструктурная граница есть, но прикладное поведение остается за внешним проектом.
Статус `optional` означает, что профиль проверяется отдельной командой и не является обязательным для CPU/WSL2 маршрута.
Статус `external` означает, что репозиторий фиксирует границу интеграции, но не владеет реализацией.

## Развилки запуска

Файл `compose.yaml` является стандартной точкой включения вариантов:

| Вариант | Команда | Блокирует review |
| --- | --- | --- |
| Базовая CPU-среда | `make compose-smoke` | да |
| Интерфейсы датчиков | `make compose-sensor-smoke` | да |
| Инструменты выгрузки артефактов | `make compose-artifact-tooling-smoke` | да |
| Связка ROS 2 + Gazebo + MAVROS | `make integration-smoke` | да |
| Движение сочленения в headless Gazebo | `make joint-motion-smoke` | да |
| Автопилотная базовая проверка | `make compose-autopilot-smoke` | да |
| ArduPilot среда сборки и SITL | `make compose-ardupilot-smoke` | да |
| Среда PX4 SITL | `make compose-px4-smoke` | нет |
| DDS-мост | `make compose-dds-smoke` | нет |
| Мост связи Zenoh | `make compose-comms-smoke` | нет |
| Среда GStreamer | `make compose-media-smoke` | нет |
| Средства диагностики | `make compose-diagnostics-smoke` | нет |
| Локальный рендер через `/dev/dri` | `make compose-render-smoke` | нет |
| NVIDIA runtime | `make compose-gpu-smoke` | нет |
| NVIDIA inference runtime | `make compose-accelerated-inference-smoke` | нет |
| ARM64 edge config | `make compose-edge-config` | нет |

NVIDIA не требуется для базовой проверки. Локальная графика Intel/AMD относится к профилю `render`, CUDA/NVIDIA - к профилю `nvidia`, а проверка ONNX Runtime, PyTorch, TensorRT и доступности CUDA для PyTorch - к профилю `inference`.

## Границы расширения

Внешние проекты подключаются к инфраструктуре через:

- ROS 2 topics, services, actions и parameters;
- MAVLink и MAVROS;
- ros2_control, controller_manager и joint_trajectory_controller;
- image topics, camera_info и адаптер поставщика восприятия;
- rosbag2/MCAP, logs, metrics, manifest и SARIF-отчеты.

Инфраструктурный слой проверяет наличие runtime, пакетов, команд и артефактов. Выбор поведения, модели, маршрута, планировщика или прикладного сценария остается за внешним проектом.

Для локальных переопределений используйте `compose.override.yaml.example` как шаблон. Рабочий `compose.override.yaml` не попадает в Git и подходит для `ROS_DOMAIN_ID`, монтирования внешнего проекта, путей к данным и переменных окружения прикладного слоя.

## Модель сети

По умолчанию Compose-сервисы foundation используют bridge-сеть проекта `robotics-sim`.
`ROS_DOMAIN_ID` обязателен и выделяется аллокатором на каждый `RUN_ID` в диапазоне `1..100`.
Выходы прогона пишутся в `runs/<run_id>/`.

`network_mode: host` не является default-путём foundation CI и harness runs. Локальные
переопределения через `compose.override.yaml` допустимы для отладки, но не меняют
контракт изоляции foundation.

## Артефакты проверки (июль 2026: pytest + JUnit + SLSA)

Кастомный `evidence-manifest.v1` (JSON manifest + `cosign sign-blob`) заменен на
индустриальный стандарт:

- каждый smoke (`integration-smoke`, `joint-motion-smoke`,
  `cross-repo-graph-smoke`, `pytest-docker-smoke`) пишет отчет в формате
  JUnit XML (`--junitxml=...`) под `runs/<run_id>/reports/`;
- числовые метрики (например длительность и число итераций
  `joint-motion-smoke`) записываются как `<property>` теги внутри JUnit XML
  через `pytest`'s `record_property`, а не отдельным `metrics.json`;
- CI хэширует JUnit-отчеты (и, для cross-repo, digest собранного образа) и
  вызывает переиспользуемый workflow
  `slsa-framework/slsa-github-generator` (`generator_generic_slsa3.yml`),
  который выпускает криптографически подписанный **SLSA Provenance
  Attestation** (in-toto) -- де-факто мировой стандарт evidence для CI в 2026
  году, заменяющий репозиторий-локальную Cosign-подпись кастомного JSON.

Неуспешные запуски разбираются по CI logs, сохраненным JUnit-отчетам и
`runs/` artifacts.

## Проверки безопасности

`make security-scan` создает полный SARIF-отчет Trivy и не блокирует выполнение. В GitHub Actions SARIF всегда сохраняется как artifact. Загрузка в GitHub Code Scanning включается только при `ENABLE_CODE_SCANNING=true` в переменных репозитория.

`make security-gate` является блокирующей проверкой для исправимых `HIGH` и `CRITICAL` уязвимостей. Исключения допускаются только через `.trivyignore` с причиной и сроком пересмотра.

`.trivyignore` не является способом скрыть риск: полный SARIF-отчет сохраняется отдельно, а baseline нужен только для временно принятых исправимых upstream-находок или находок базового образа. Находки без доступной исправленной версии остаются видимыми в отчете, но не блокируют gate до появления исправления.

## Граница поставки

CI собирает локальный Docker image для проверки репозитория. Публикация образа отделена от CI и выполняется workflow `release-image`.

Release workflow запускается вручную через GitHub Actions или автоматически по тегам `v*`. Он публикует `linux/amd64` образ в GHCR, добавляет OCI labels, BuildKit cache, SBOM, provenance attestations и Cosign keyless signature по digest.

Cross-repo integration workflow `cross-repo-integration` поднимает infra image, ставит pinned contracts/harness (проверяя, что `make ci` каждого репозитория зелен на зафиксированном в `infra/cross-repo/stack-lock.json` SHA), запускает `launch_testing_ros`-проверку графа (`cross-repo-graph-smoke`), интеграционные smoke и `pytest-docker-smoke` с загруженным harness-плагином, затем хэширует JUnit-отчеты и вызывает `slsa-github-generator` для подписанного SLSA Provenance по всей комбинации трёх репозиториев.

Локальная сборка для разработки и CI не требует публикации образа.

## Инструменты проверки

| Инструмент | Версия |
| --- | --- |
| check-jsonschema | `0.37.4` |
| yamllint | `1.38.0` |
| Docker Compose | `v2.35.1` или новее |
| Docker Buildx Bake | через Docker Buildx из установленного Docker CLI |
| Hadolint | `2.14.0` |
| actionlint | `1.7.12` |
| pre-commit | `4.6.0` |
| Образ Trivy | `aquasec/trivy:0.72.0` |
| Trivy DB | `ghcr.io/aquasecurity/trivy-db:2` |
| Micro XRCE-DDS Agent | `v3.0.1`, optional source build |
| Zenoh bridge ROS2DDS | `1.9.0`, optional image |
| GStreamer tools | `1.24.2-1ubuntu0.1`, optional image |
| PlotJuggler | `3.17.2`, optional image |

## Стандарты качества

Репозиторий использует:

- Docker Compose profiles для вариантов запуска;
- Docker Compose healthcheck для сервисов;
- Docker Compose override example для локальных расширений;
- Docker Buildx Bake для декларативной сборки образов;
- Dev Container Specification для воспроизводимой рабочей среды;
- OCI image labels для метаданных образа;
- pre-commit hooks для базовой гигиены файлов, JSON, YAML и Dockerfile;
- GitHub Actions с минимальными правами, pinned actions и `persist-credentials: false`;
- GHCR release workflow с BuildKit cache, SBOM и provenance attestations;
- Hadolint для Dockerfile;
- actionlint для GitHub Actions;
- Trivy SARIF для отчета безопасности;
- Trivy gate для блокировки исправимых `HIGH` и `CRITICAL` findings;
- CycloneDX SBOM для состава образа;
- Dependabot для GitHub Actions, pip, Dockerfile и Compose-образов;
- rosbag2/MCAP для машинно читаемых данных симуляций;
- `pytest` + `launch_testing_ros` для интеграционных ROS-проверок и `pytest-docker` для управления жизненным циклом Compose-сервисов;
- JUnit XML + SLSA Provenance (`slsa-github-generator`) как машинно читаемый, криптографически подписанный результат проверки.

APT-пакеты ROS не закрепляются в Dockerfile через `package=version`.
Их версии фиксируются в `infra/stack/simulation-stack.json` и проверяются командой
`make docker-update-check`. Это сохраняет сборку работоспособной на свежем ROS apt-срезе
и одновременно делает дрейф версий видимым.

## Требования

- WSL2 или Linux;
- Docker;
- `make`;
- `python3`;
- `jq`.

Локальные инструменты проверки ставятся в `.venv` командой:

```bash
make bootstrap
```

Для первого запуска после клонирования репозитория используйте `./setup_dev_env.sh`:
он создает `.env` и `compose.override.yaml` из шаблонов и выделяет dev `RUN_ID`/`ROS_DOMAIN_ID`,
поэтому `docker compose up` работает сразу без ручного чтения Makefile.

## Быстрый старт для работы

Основной путь запуска идет через Docker Compose. Для обычной разработки не нужно запускать весь набор проверок:

```bash
./setup_dev_env.sh
docker buildx bake -f docker-bake.hcl --allow=network.host simulation
docker compose --profile dev up --detach --wait simulation-dev
docker compose --profile dev exec simulation-dev bash
```

Внутри контейнера подключите ROS 2 окружение и проверьте базовые команды:

```bash
source /etc/profile.d/robotics_ros_setup.sh
ros2 pkg list
gz sim --help
```

Остановить рабочий контейнер:

```bash
docker compose --profile dev down --remove-orphans simulation-dev
```

Посмотреть состояние и логи:

```bash
docker compose --profile dev ps simulation-dev
docker compose --profile dev logs --follow simulation-dev
```

Для подключения проектной сцены, ROS-пакетов или данных используйте `compose.override.yaml.example`
как шаблон. Рабочий `compose.override.yaml` не попадает в Git.

Makefile содержит короткие aliases над этими командами:

```bash
make dev-up
make dev-shell
make dev-logs
make dev-ps
make dev-down
```

## Сборка через Docker Buildx Bake

Для декларативной сборки без Compose используйте Docker Buildx Bake:

```bash
docker buildx bake -f docker-bake.hcl --allow=network.host simulation
```

Флаг `-f docker-bake.hcl` обязателен: без него Buildx Bake также подхватывает
`compose.yaml` из той же директории и падает на обязательных переменных
окружения (`${VAR:?...}`) сервисов.

То же через Makefile:

```bash
make bake-build
```

Файл `docker-bake.hcl` описывает основной образ и optional-образы DDS, media, diagnostics и accelerated inference.

## Проверки

Короткий список команд:

```bash
make help
make bootstrap
make validate
make lint
make review
make pre-commit
make ci
```

Короткая справка доступна через `make help`; полный список технических целей описан в `Makefile`.

`make ci` выполняет полный локальный прогон: проверку контрактов, сборку образа, smoke-проверки,
интеграционный smoke ROS 2/Gazebo/MAVROS (`pytest` + `launch_testing_ros`, JUnit XML), smoke
инструментов артефактов, headless-проверку движения сочленения Gazebo,
cross-repo graph readiness, `pytest-docker` smoke, сверку зафиксированных пакетов, SARIF-отчет
Trivy, security gate и SBOM. CI дополнительно хэширует JUnit-отчеты и вызывает
`slsa-github-generator` для подписанного SLSA Provenance.

`make review` выполняет локальный набор перед ревью:
контракты, Compose config, линтеры, профили, сборку, smoke образа, интерфейсы датчиков,
инструменты артефактов, интеграционный smoke, движение сочленения Gazebo, cross-repo graph
readiness, `pytest-docker` smoke, автопилотную базу, метаданные образа, SARIF, security gate и SBOM.

`make optional-smoke` выполняет дополнительные проверки, которые не блокируют базовый CPU/WSL2
маршрут: локальный рендер, среду PX4 SITL, DDS-мост, мост Zenoh, GStreamer, диагностику и
конфигурацию ARM64 edge. На холодном Docker cache команда собирает optional-образы DDS,
media и diagnostics, поэтому выполняется дольше базового `make review`.

## Структура

```txt
.devcontainer/                       Dev Container
.github/                             CI, release, update-check, Dependabot
.env.example                         шаблон локальных переменных Compose и Makefile
.pre-commit-config.yaml              pre-commit hooks
.trivyignore                         policy-файл исключений Trivy
compose.override.yaml.example        шаблон локального Compose override
compose.yaml                         Docker Compose профили запуска
docker-bake.hcl                      Docker Buildx Bake targets
config/headless_gazebo.yaml          минимальный headless-конфиг симуляции
contracts/infra/infra-release.v1.schema.json  JSON Schema release manifest инфраструктуры
contracts/infra/runtime-profiles.v1.schema.json  JSON Schema профилей возможностей
contracts/infra/ros-graph-contract.v1.schema.json  JSON Schema ожидаемого ROS graph
contracts/infra/stack.v1.schema.json    JSON Schema контракта стека
infra/docker/                        Dockerfile симуляционного образа
infra/docker/accelerated-inference.Dockerfile  optional NVIDIA inference runtime
infra/docker/dds-agent.Dockerfile    optional DDS bridge runtime
infra/docker/media-runtime.Dockerfile  optional media runtime
infra/docker/diagnostics-runtime.Dockerfile  optional diagnostics runtime
infra/smoke/launch_testing/          pytest + launch_testing_ros: integration, joint-motion, cross-repo graph readiness
infra/smoke/worlds/empty.sdf         минимальный SDF-мир для smoke
infra/smoke/worlds/joint_motion.sdf  минимальный SDF-мир для проверки JointController
infra/cross-repo/                    stack-lock для pinned contracts/harness SHA в cross-repo gate
infra/stack/cross-repo-expected-graph.json  ожидаемый ROS graph для cross-repo gate
infra/stack/infra-release.json        release manifest инфраструктуры
infra/stack/runtime-profiles.json     профили возможностей и границы расширения
infra/stack/simulation-stack.json    зафиксированный состав стека
launch/simulation_smoke.launch.py    минимальный ROS 2 launch для smoke
tests/test_compose_services.py       pytest-docker: жизненный цикл долгоживущих Compose-сервисов
infra/scripts/check_packages.sh      apt-версии внутри осрф/ros:jazzy-simulation для docker-update-check
infra/scripts/allocate_domain_id.py  выделение ROS_DOMAIN_ID на RUN_ID
infra/scripts/sync_contracts.py      генерация *.json контрактов из человекочитаемых *.yaml
infra/stack/runtime-profiles.yaml    источник профилей возможностей для правки людьми
infra/docker/scripts/healthcheck.sh  проверка пакетов/инструментов образа, используется как CMD
Makefile                             единая точка входа для локальных и CI-проверок
setup_dev_env.sh                     one-click генерация .env/override и dev RUN_ID
run_local_test.sh                    запуск make-таргетов под одноразовым самоочищающимся RUN_ID
requirements-dev.txt                 инструменты валидации
```

## Артефакты

Локальные отчеты пишутся в `runs/<run_id>/` и не попадают в Git.
