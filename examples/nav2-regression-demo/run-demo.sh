#!/usr/bin/env bash
# One-command Nav2 qualification demo on released infra v0.11.0-rc2.
#
# Offline verdict path: install the published acceptance SDK cohort, build the
# native Nav2 evaluator, admit it with an operator Cosign key-only profile, and
# assess one recorded NavigateToPose capture through five custody cases via the
# public `robotics-acceptance evaluate` path. This path does NOT pull the
# simulation image and does not execute physics; the image is not used to run
# the evaluation. Live reproduction is a separate command: ./run-live.sh
#
# Usage: ./run-demo.sh [--reinstall] [--sensitivity-tolerance M]
#                      [--cosign-profile PATH] [--operator-profile PATH] [--skip-release-env]
#                      [--prepare-only]
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$DEMO_DIR/../nav2-turtlebot3"
RELEASE_TAG="${NAV2_DEMO_RELEASE_TAG:-v0.11.0-rc2}"
REPO="${NAV2_DEMO_REPO:-mmkolpakov/robotics-runtime-infra}"
WORK="$DEMO_DIR/work"
VENV="$DEMO_DIR/.venv"

REINSTALL=0
SENSITIVITY_TOLERANCE=0.10
COSIGN_PROFILE=""
SKIP_RELEASE_ENV=0
PREPARE_ONLY=0
OPERATOR_PROFILE=""
while [ $# -gt 0 ]; do
  case "$1" in
    --reinstall) REINSTALL=1; shift ;;
    --sensitivity-tolerance) SENSITIVITY_TOLERANCE="$2"; shift 2 ;;
    --prepare-only) PREPARE_ONLY=1; shift ;;
    --operator-profile) OPERATOR_PROFILE="$2"; shift 2 ;;
    --cosign-profile) COSIGN_PROFILE="$2"; shift 2 ;;
    --skip-release-env) SKIP_RELEASE_ENV=1; shift ;;
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

# 1. Best-effort release lock for provenance only (released mode, digest-pinned).
#    The offline verdict path never pulls or runs the simulation image.
if [ "$SKIP_RELEASE_ENV" -eq 0 ]; then
  log "Fetching release.env for $RELEASE_TAG (provenance only; no image pull)"
  if command -v gh >/dev/null 2>&1; then
    gh release download "$RELEASE_TAG" --repo "$REPO" --pattern release.env \
      --dir "$WORK" --clobber || log "release.env unavailable; continuing"
  else
    curl -fsSL -o "$WORK/release.env" \
      "https://github.com/$REPO/releases/download/$RELEASE_TAG/release.env" \
      || log "release.env unavailable; continuing"
  fi
fi

# 2. Install the published SDK cohort and build/install the native evaluator.
PY="$VENV/bin/python"
# Cache discovery reads metadata; the evaluator is authenticated before evaluation.
if [ "$REINSTALL" -eq 1 ] || [ ! -x "$PY" ] || ! "$PY" -I - "$EXAMPLE_DIR/evaluator/pyproject.toml" <<'PY' >/dev/null 2>&1
from importlib.metadata import PackageNotFoundError, version
from pathlib import Path
import sys
import tomllib

project = tomllib.loads(Path(sys.argv[1]).read_text())["project"]
try:
    installed = version(project["name"])
except PackageNotFoundError:
    sys.exit(1)
sys.exit(installed != project["version"])
PY
then
  log "Installing published acceptance SDK cohort from requirements.lock"
  if command -v uv >/dev/null 2>&1; then
    uv venv --python 3.12 --seed "$VENV"
  else
    python3.12 -m venv "$VENV"
  fi
  "$PY" -m pip install --disable-pip-version-check --require-hashes \
    --only-binary=:all: -r "$EXAMPLE_DIR/requirements.lock"
  log "Building and installing the native Nav2 evaluator"
  if command -v uv >/dev/null 2>&1; then
    uv build --wheel --out-dir "$DEMO_DIR/dist" "$EXAMPLE_DIR/evaluator"
  else
    "$PY" -m pip wheel --no-deps --wheel-dir "$DEMO_DIR/dist" "$EXAMPLE_DIR/evaluator"
  fi
  "$PY" -m pip install --disable-pip-version-check --no-deps \
    "$DEMO_DIR"/dist/nav2_turtlebot3_evaluator-*-py3-none-any.whl
  "$PY" -m pip check
else
  log "Reusing installed SDK cohort and evaluator"
fi

[ "$PREPARE_ONLY" -eq 0 ] || exit 0

# 3. Assess the recorded capture through the five custody cases.
log "Running the five-case Nav2 qualification assessment"
DRIVER_ARGS=(--work-dir "$WORK" --output "$WORK/results.json"
  --report "$WORK/report.txt" --sensitivity-tolerance "$SENSITIVITY_TOLERANCE")
if [ -n "$COSIGN_PROFILE" ]; then
  DRIVER_ARGS+=(--cosign-profile "$COSIGN_PROFILE")
fi
if [ -n "$OPERATOR_PROFILE" ]; then
  DRIVER_ARGS+=(--operator-profile "$OPERATOR_PROFILE")
fi
"$PY" "$DEMO_DIR/regression_driver.py" "${DRIVER_ARGS[@]}"

log "Done. Report: $WORK/report.txt | Results: $WORK/results.json | Provenance: $WORK/provenance.json"
