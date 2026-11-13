#!/usr/bin/env bash
set -euo pipefail

demo_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
if [[ "${1:-}" == -h || "${1:-}" == --help ]]; then
  cat <<'EOF'
Usage: run-export.sh --operator-profile PATH --publisher-key PATH --output DIRECTORY
                     [--bootstrap --public-key PATH [--cosign-profile PATH]]
                     [--case baseline|criterion-sensitivity|insufficient-observation|missing-coverage]
                     [--work-dir DIRECTORY]

With --bootstrap, PATH must name operator-profile.json in a new directory outside
the evidence/output directories. Supply your own Cosign keypair. Without it, the
existing profile must approve that publisher key and the installed evaluator wheel.
See EXPORT.md for key generation, trust distribution, and independent verification.
EOF
  exit 0
fi
"$demo_dir/run-demo.sh" --prepare-only --skip-release-env
exec "$demo_dir/.venv/bin/python" "$demo_dir/export_bundle.py" "$@"
