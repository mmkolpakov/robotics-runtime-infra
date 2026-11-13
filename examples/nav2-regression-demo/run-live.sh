#!/usr/bin/env bash
# Capture one admitted Nav2 attempt through the existing consumer owner.
set -euo pipefail

DEMO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXAMPLE_DIR="$(cd "$DEMO_DIR/../nav2-turtlebot3" && pwd)"
IMAGE=""
REQUIREMENTS=""
PYTHON="$EXAMPLE_DIR/.venv/bin/python"
OUTPUT=""
CASE=success
PULL_ONLY=0

usage() {
  cat <<'USAGE'
Usage: run-live.sh --image REFERENCE --requirements FILE --output DIRECTORY
                   [--python EXECUTABLE] [--case CASE]
       run-live.sh --pull-only --image REPOSITORY@sha256:DIGEST

Capture one fresh attempt with an already admitted consumer image and inputs.
REFERENCE is an immutable repository digest or a local sha256 image ID.
FILE, DIRECTORY and EXECUTABLE must be absolute paths. DIRECTORY must be new.
CASE is success, cancel, timeout or server-failure (default: success).
The Python default is ../nav2-turtlebot3/.venv/bin/python.

The existing native owner performs image/input checks, capture and cleanup.
Its evaluation-inputs.json is input to the separate public assessment command.
This entry point does not qualify an image or run the recorded five-case demo.
--pull-only downloads the explicitly selected image without starting an attempt.
USAGE
}

refuse() { printf '%s\n' "$*" >&2; exit 2; }

while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --pull-only) PULL_ONLY=1; shift ;;
    --image|--requirements|--python|--output|--case)
      [ "$#" -ge 2 ] && [ -n "$2" ] || refuse "missing value for $1"
      case "$1" in
        --image) IMAGE="$2" ;;
        --requirements) REQUIREMENTS="$2" ;;
        --python) PYTHON="$2" ;;
        --output) OUTPUT="$2" ;;
        --case) CASE="$2" ;;
      esac
      shift 2 ;;
    *) refuse "unknown option: $1" ;;
  esac
done

[[ "$IMAGE" =~ ^([^[:space:]@]+@)?sha256:[a-f0-9]{64}$ ]] ||
  refuse "--image requires an immutable repository digest or local sha256 ID"
case "$CASE" in
  success|cancel|timeout|server-failure) ;;
  *) refuse "unsupported --case: $CASE" ;;
esac

if [ "$PULL_ONLY" -eq 1 ]; then
  [[ "$IMAGE" == *@sha256:* ]] || refuse "--pull-only requires a repository digest"
  exec podman pull -- "$IMAGE"
fi

[[ "$REQUIREMENTS" == /* ]] && [ -f "$REQUIREMENTS" ] && [ -r "$REQUIREMENTS" ] ||
  refuse "--requirements must name an existing readable absolute file"
[[ "$PYTHON" == /* ]] && [ -x "$PYTHON" ] ||
  refuse "--python must name the installed SDK environment's absolute executable"
[[ "$OUTPUT" == /* ]] || refuse "--output must be an absolute path"
[ ! -e "$OUTPUT" ] && [ ! -L "$OUTPUT" ] || refuse "--output must be a new directory"
mkdir -p -- "$(dirname "$OUTPUT")"

exec node "$EXAMPLE_DIR/native-check.mjs" \
  "$OUTPUT" "$EXAMPLE_DIR" "$IMAGE" "$CASE" "$REQUIREMENTS" "$PYTHON"
