#!/usr/bin/env bash
# Claims: the recorder cannot ship; factory configuration never enables it.
set -euo pipefail
root="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
source "$root/scripts/release/lib/forbidden_bytes.sh"
fail=0
for path in lua/yana/debug_buffer_states.lua lua/yana/debug_buffer_states_bundle.lua nvim/lua/user/yana.lua; do
  if forbidden_bytes_allowed_path "$path"; then
    echo "FAIL: development snapshot path allowed in release: $path"; fail=1
  elif grep -Fxq "$path" "$root/scripts/release/manifest.txt"; then
    echo "FAIL: development snapshot path listed in release manifest: $path"; fail=1
  else echo "PASS: release excludes $path"; fi
done
if grep -q 'buffer_states' "$root/lua/yana/configuration/config_defaults.lua"; then
  echo 'FAIL: development snapshot selector leaked into factory defaults'; fail=1
else echo 'PASS: factory defaults contain no snapshot selector'; fi
if (( fail )); then echo 'TEST-RESULT: FAIL snapshot release isolation'; exit 1; fi
echo 'TEST-RESULT: PASS snapshot release isolation'
