#!/usr/bin/env bash
# Live reproduction path - separate from the offline verdict demo (run-demo.sh).
#
# Pulls the released rc2 simulation image in released mode (digest-pinned, no
# snapshot mirror) and launches the admitted Nav2 consumer composition. The
# offline verdict demo does not use this image; live execution does.
#
# The headline live A/B pair - two fresh Nav2 recordings under one frozen
# contract with a real goal-checker configuration change - is the gated next
# step and is NOT produced here. This command reproduces the live environment
# and runs the consumer's live composition; see ../nav2-turtlebot3/README.md for
# the admitted native launch and recording recipe.
#
# Usage: ./run-live.sh [--pull-only]
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
RELEASE_TAG="${NAV2_DEMO_RELEASE_TAG:-v0.11.0-rc2}"
REPO="${NAV2_DEMO_REPO:-mmkolpakov/robotics-runtime-infra}"
WORK="$DEMO_DIR/work"
RELEASE_ENV="$WORK/release.env"
PULL_ONLY=0
[ "${1:-}" = "--pull-only" ] && PULL_ONLY=1

log() { printf '\n[live] %s\n' "$*"; }
mkdir -p "$WORK"

log "Fetching release.env for $RELEASE_TAG (released mode)"
if command -v gh >/dev/null 2>&1; then
  gh release download "$RELEASE_TAG" --repo "$REPO" --pattern release.env \
    --dir "$WORK" --clobber
else
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

engine=""
if command -v podman >/dev/null 2>&1; then engine=podman
elif command -v docker >/dev/null 2>&1; then engine=docker; fi
if [ -z "$engine" ]; then
  echo "no container engine (podman/docker) found; live reproduction requires one" >&2
  exit 1
fi

compose=""
if command -v docker-compose >/dev/null 2>&1; then compose="docker-compose"
elif command -v podman-compose >/dev/null 2>&1; then compose="podman-compose"
elif "$engine" compose version >/dev/null 2>&1; then compose="$engine compose"; fi

log "Pulling released simulation image: $SIMULATION_IMAGE"
if [ -n "$compose" ] && [ -f "$DEMO_DIR/compose.demo.yaml" ]; then
  # shellcheck disable=SC2086
  $compose --env-file "$RELEASE_ENV" -f "$DEMO_DIR/compose.demo.yaml" pull simulation
else
  "$engine" pull "$SIMULATION_IMAGE"
fi

if [ "$PULL_ONLY" -eq 1 ]; then
  log "Image pulled (--pull-only). Live Nav2 launch: see ../nav2-turtlebot3/README.md"
  exit 0
fi

log "Image present. The admitted Nav2 live composition and recording recipe are"
log "in ../nav2-turtlebot3/README.md (native launch requires execution admission)."
log "The offline verdict report is produced by ./run-demo.sh, not by this image."
