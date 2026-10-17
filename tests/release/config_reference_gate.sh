#!/usr/bin/env bash
# Read the real Lua defaults; check both independently maintained references.
# Usage: config_reference_gate.sh [TREE] [NVIM] [--list]
set -euo pipefail
root=${1:-$(cd "$(dirname "$0")/../.." && pwd)}
nvim=${2:-nvim}
exec "$nvim" --headless --clean -u NONE -i NONE -l \
  "$(dirname "$0")/config_reference.lua" "$root" "${3:-}"
