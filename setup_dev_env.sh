#!/usr/bin/env bash
# One-click local onboarding: creates .env and compose.override.yaml from
# their tracked examples, and allocates a dev RUN_ID/ROS_DOMAIN_ID so a bare
# `docker compose up` works right after cloning, without first reading the
# Makefile to learn about RUN_ID/ROS_DOMAIN_ID allocation.
#
# Safe to re-run: it never overwrites files you already have.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "${repo_root}"

if [[ -f .env ]]; then
  echo "setup_dev_env: .env already exists, leaving it alone"
else
  cp .env.example .env
  echo "setup_dev_env: created .env from .env.example"
fi

if [[ -f compose.override.yaml ]]; then
  echo "setup_dev_env: compose.override.yaml already exists, leaving it alone"
else
  cp compose.override.yaml.example compose.override.yaml
  echo "setup_dev_env: created compose.override.yaml from compose.override.yaml.example"
fi

run_id="${RUN_ID:-dev-$(whoami)}"
make RUN_ID="${run_id}" prepare-run
ros_domain_id="$(cat "runs/${run_id}/ros_domain_id.txt")"

if ! grep -q '^RUN_ID=' .env; then
  printf '\nRUN_ID=%s\nROS_DOMAIN_ID=%s\n' "${run_id}" "${ros_domain_id}" >> .env
  echo "setup_dev_env: appended RUN_ID=${run_id} and ROS_DOMAIN_ID=${ros_domain_id} to .env"
fi

cat <<EOF

Ready. Next steps:
  docker compose build simulation
  docker compose --profile dev up --detach --wait simulation-dev
  docker compose --profile dev exec simulation-dev bash

Or via Makefile shortcuts: make dev-up / make dev-shell / make dev-down
EOF
