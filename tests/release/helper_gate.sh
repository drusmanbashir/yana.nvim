#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 ]] || { echo "Usage: $0 EXPORTED_TREE NVIM" >&2; exit 64; }
tree=$(realpath "$1")
nvim=$(realpath "$2")
manifest="$tree/scripts/release/manifest.txt"
[[ -f "$manifest" ]] || { echo "HELPER FAIL: manifest missing: $manifest" >&2; exit 1; }
# The helper set is whatever the manifest exports; dev-only helpers in a source tree are not checked.
mapfile -t helpers < <(grep -E '^bin/yana-[^/]+$' "$manifest")
((${#helpers[@]} > 0)) || { echo "HELPER FAIL: manifest exports no bin/yana-* helpers" >&2; exit 1; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/yana-helpers.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

cd "$scratch"
count=0
for entry in "${helpers[@]}"; do
	helper="$tree/$entry"
	[[ -f "$helper" ]] || { echo "HELPER FAIL: manifest helper missing from tree: $helper" >&2; exit 1; }
	[[ -x "$helper" ]] || { echo "HELPER FAIL: not executable: $helper" >&2; exit 1; }
	output=$(env -i HOME="$scratch/home" PATH="$(dirname "$nvim"):/usr/bin:/bin" "$helper" --help 2>&1) || {
		echo "HELPER FAIL: --help refused: $helper" >&2
		exit 1
	}
	grep -Fiq 'usage:' <<<"$output" || {
		echo "HELPER FAIL: no usage text: $helper" >&2
		exit 1
	}
	if grep -Eqi 'module not found|cannot open.*lua|permission denied' <<<"$output"; then
		echo "HELPER FAIL: runtime path or mode error: $helper" >&2
		exit 1
	fi
	count=$((count + 1))
done

set +e
apply_probe=$(env -i HOME="$scratch/home" PATH="$(dirname "$nvim"):/usr/bin:/bin" \
	"$tree/bin/yana-apply" recover 2>&1)
apply_rc=$?
set -e
[[ $apply_rc == 64 ]] || { echo "HELPER FAIL: yana-apply module probe returned $apply_rc" >&2; exit 1; }
grep -Fq 'recover requires --diary DIR' <<<"$apply_probe" \
	|| { echo "HELPER FAIL: yana-apply did not locate its Lua module" >&2; exit 1; }
echo "HELPER GATE PASS count=$count cwd=$scratch"
