# robotics-simulation-infra

Воспроизводимая среда моделирования робототехнических систем на ROS 2 Jazzy,
Gazebo Harmonic и Ubuntu 24.04. Репозиторий содержит один исполняемый OCI-образ,
один основной Compose-сервис и один профиль приёмочных тестов. Прикладные сцены,
алгоритмы восприятия и бизнес-логика в состав не входят.

## Состав

- ROS 2 Jazzy и Gazebo Harmonic;
- MAVLink и MAVROS;
- MoveIt 2, ros2_control, ros2_controllers и gz_ros2_control;
- OpenCV, cv_bridge, image_transport и vision_msgs;
- rosbag2 с хранилищем MCAP;
- headless-проверки часов моделирования, камеры, записи MCAP и управления
  сочленением.

Логические зависимости заданы в
[`package.xml`](ros_ws/src/robotics_simulation_infra/package.xml). Точные версии
установленных пакетов фиксируются SBOM выпущенного образа, а исходный базовый
образ закреплён digest в [`Dockerfile`](Dockerfile).

## Запуск

Требуется Docker Engine или Docker Desktop с Compose. Файл `.env`, локальная
установка ROS и графический интерфейс не требуются.

```bash
docker compose pull
docker compose up --detach --wait
docker compose exec -T simulation robotics-entrypoint ros2 topic echo /clock --once
docker compose run --rm --no-deps test
docker compose down --volumes --remove-orphans
```

Сервис `simulation` запускает реальный сервер Gazebo и публикует `/clock`.
Сервис `test` выполняет четыре изолированные launch-проверки и сохраняет JUnit
XML в `artifacts/test-results`.

Для проверки изменений исходного образа вместо `pull` выполните:

```bash
docker compose build --pull
```

## Расширение

Прикладной репозиторий наследует выпущенный образ по digest и добавляет свои
ROS-пакеты, сцены, параметры и модели отдельным Dockerfile. Его Compose-файл
может переопределить команду запуска и подключить рабочие каталоги, не меняя
этот репозиторий. Базовый образ рассчитан на CPU и headless-режим; ускорители,
модели и драйверы оборудования добавляются в прикладном образе.

[`foundation.repos`](foundation.repos) закрепляет совместимые ревизии пакета
контрактов и pytest-оснастки. Workflow `foundation-integration` проверяет один
сценарий через все три репозитория и отдельно подтверждает параллельный запуск
двух изолированных Compose-проектов.

## Поставка

CI проверяет Compose, Dockerfile и workflow, собирает образ, выполняет ROS/Gazebo
тесты и применяет блокирующую политику Trivy для исправимых HIGH/CRITICAL
уязвимостей. Выпуск по тегу публикуется в
`ghcr.io/mmkolpakov/droning-simulation-infra`, получает BuildKit SBOM,
provenance и GitHub artifact attestation. Точный digest образа указывается в
соответствующем GitHub Release.

Лицензия: [MIT](LICENSE).
