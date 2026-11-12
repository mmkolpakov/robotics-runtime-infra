#!/usr/bin/env bash
# One-command Nav2 acceptance regression demo on released infra v0.11.0-rc2.
#
# Pulls the released rc2 simulation image in released mode (no snapshot mirror),
# installs the published acceptance SDK cohort plus the native Nav2 evaluator,
# then assesses one recorded Nav2 run twice - baseline and a broken-commit
# parameter change - and prints a readable verdict report.
#
# Usage: ./run-demo.sh [--skip-pull] [--reinstall] [--broken-tolerance M]
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$DEMO_DIR/../nav2-turtlebot3"
RELEASE_TAG="${NAV2_DEMO_RELEASE_TAG:-v0.11.0-rc2}"
REPO="${NAV2_DEMO_REPO:-mmkolpakov/robotics-runtime-infra}"
WORK="$DEMO_DIR/work"
VENV="$DEMO_DIR/.venv"
RELEASE_ENV="$WORK/release.env"

SKIP_PULL=0
REINSTALL=0
BROKEN_TOLERANCE=0.10
while [ $# -gt 0 ]; do
  case "$1" in
    --skip-pull) SKIP_PULL=1; shift ;;
    --reinstall) REINSTALL=1; shift ;;
    --broken-tolerance) BROKEN_TOLERANCE="$2"; shift 2 ;;
    -h|--help) grep '^#' "$0" | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "unknown option: $1" >&2; exit 2 ;;
  esac
done

log() { printf '\n[demo] %s\n' "$*"; }

if [ ! -d "$EXAMPLE_DIR" ]; then
  echo "missing Nav2 consumer engine: $EXAMPLE_DIR" >&2
  exit 1
fi
mkdir -p "$WORK"

# 1. Fetch the released image lock (released mode, digest-pinned, no snapshot).
log "Fetching release.env for $RELEASE_TAG"
if command -v gh >/dev/null 2>&1; then
  gh release download "$RELEASE_TAG" --repo "$REPO" --pattern release.env \
    --dir "$WORK" --clobber
else
  # gh absent: the release asset endpoint is independent of the REST API quota.
  curl -fsSL -o "$RELEASE_ENV" \
    "https://github.com/$REPO/releases/download/$RELEASE_TAG/release.env"
fi
if ! grep -q '^ROBOTICS_RUNTIME_MODE=released$' "$RELEASE_ENV"; then
  echo "release.env is not in released mode" >&2
  exit 1
fi
set -a
# shellcheck disable=SC1090,SC1091
. "$RELEASE_ENV"
set +a
log "Released mode: ${ROBOTICS_RUNTIME_MODE} (${ROBOTICS_RELEASE_SOURCE_REF})"

# 2. Pull the released simulation image (compose if a provider exists, else the
#    container engine directly). Non-fatal: the verdict demo still runs offline.
PULL_STATUS="skipped"
if [ "$SKIP_PULL" -eq 0 ]; then
  engine=""
  if command -v podman >/dev/null 2>&1; then engine=podman
  elif command -v docker >/dev/null 2>&1; then engine=docker; fi
  if [ -z "$engine" ]; then
    log "No container engine found; skipping image pull"
    PULL_STATUS="no-engine"
  else
    compose=""
    if command -v docker-compose >/dev/null 2>&1; then compose="docker-compose"
    elif command -v podman-compose >/dev/null 2>&1; then compose="podman-compose"
    elif "$engine" compose version >/dev/null 2>&1; then compose="$engine compose"; fi
    log "Pulling released simulation image: $SIMULATION_IMAGE"
    if [ -n "$compose" ] && [ -f "$DEMO_DIR/compose.demo.yaml" ]; then
      # shellcheck disable=SC2086
      if $compose --env-file "$RELEASE_ENV" -f "$DEMO_DIR/compose.demo.yaml" pull simulation; then
        PULL_STATUS="pulled (compose)"
      else
        PULL_STATUS="pull-failed"
      fi
    elif "$engine" pull "$SIMULATION_IMAGE"; then
      PULL_STATUS="pulled ($engine)"
    else
      PULL_STATUS="pull-failed"
    fi
    if [ "$PULL_STATUS" != "pull-failed" ] && [ "$PULL_STATUS" != "no-engine" ]; then
      log "Image pull: $PULL_STATUS"
    else
      log "Image pull unavailable ($PULL_STATUS); continuing with the offline verdict demo"
    fi
  fi
else
  log "Image pull skipped (--skip-pull)"
fi

# 3. Install the published SDK cohort and the native Nav2 evaluator.
PY="$VENV/bin/python"
if [ "$REINSTALL" -eq 1 ] || [ ! -x "$PY" ] || ! "$PY" -c 'import nav2_turtlebot3_evaluator' >/dev/null 2>&1; then
  log "Installing published acceptance SDK cohort (harness 0.23.1 / contracts 0.22.0)"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 --seed "$VENV"
  else
    python3.12 -m venv "$VENV"
  fi
  "$PY" -m pip install --disable-pip-version-check --require-hashes \
    --only-binary=:all: -r "$EXAMPLE_DIR/requirements.lock"
  log "Building and installing the native Nav2 evaluator 0.3.0"
  if command -v uv >/dev/null 2>&1; then
    uv build --wheel --out-dir "$DEMO_DIR/dist" "$EXAMPLE_DIR/evaluator"
  else
    "$PY" -m pip wheel --no-deps --wheel-dir "$DEMO_DIR/dist" "$EXAMPLE_DIR/evaluator"
  fi
  "$PY" -m pip install --disable-pip-version-check --no-deps \
    "$DEMO_DIR/dist/nav2_turtlebot3_evaluator-0.3.0-py3-none-any.whl"
  "$PY" -m pip check
else
  log "Reusing installed SDK cohort and evaluator"
fi

# 4. Assess the recorded Nav2 run twice and print the verdict report.
log "Running baseline and broken-commit Nav2 assessments"
"$PY" "$DEMO_DIR/regression_driver.py" \
  --work-dir "$WORK/run" \
  --output "$WORK/results.json" \
  --report "$WORK/report.txt" \
  --broken-tolerance "$BROKEN_TOLERANCE"

log "Done. Report: $WORK/report.txt | Results: $WORK/results.json | Image pull: $PULL_STATUS"
