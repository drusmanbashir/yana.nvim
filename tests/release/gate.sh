#!/usr/bin/env bash
set -euo pipefail

root=$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)
commit=${1:-HEAD}
tmp=${TMPDIR:-/tmp}
work=$(mktemp -d "$tmp/yana-release-gate.XXXXXX")
trap 'rm -rf "$work"' EXIT

"$root/scripts/release/export.sh" "$commit" "$work/export"
epoch=$(git -C "$root" show -s --format=%ct "$commit")
(umask 022; SOURCE_DATE_EPOCH=$epoch "$work/export/scripts/release/archive.sh" "$work/export" "$work/a")
sleep 1
(umask 077; TZ=Pacific/Auckland SOURCE_DATE_EPOCH=$epoch "$work/export/scripts/release/archive.sh" "$work/export" "$work/b")
cmp "$work/a/yana.nvim-"*.tar.gz "$work/b/yana.nvim-"*.tar.gz
"$work/export/tests/release/fresh_install.sh" "$work/export" "$(command -v nvim)"
DEV_CHECKOUT="$root" "$work/export/tests/release/confined_turn_gate.sh" "$work/export" "$(command -v nvim)"
echo "RELEASE GATE PASS"
