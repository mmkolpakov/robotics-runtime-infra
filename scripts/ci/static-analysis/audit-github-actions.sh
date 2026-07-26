#!/usr/bin/env bash
set -Eeuo pipefail

uvx --from zizmor==1.26.1 zizmor --pedantic --min-severity medium --format github .github/workflows
