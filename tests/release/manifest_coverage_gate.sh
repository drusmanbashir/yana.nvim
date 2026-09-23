#!/usr/bin/env bash
# manifest_coverage_gate.sh — the public export manifest must be
# require()-closed and bin/yana-* reference-closed. A pcall'd require counts
# too: a module missing behind one never errors, it degrades silently.
#
# CLAIM
#   Every require("yana.X")/require("blink_yana.X") in a listed lua file,
#   direct or under pcall, resolves to a listed lua/<mod>.lua or
#   lua/<mod>/init.lua; every bin/yana-* name in a listed lua/ or bin/ file is
#   itself listed.
#
# Usage: manifest_coverage_gate.sh [TREE] [MANIFEST]
#   TREE      repo root to read sources from (default: this repo).
#   MANIFEST  manifest to check against (default:
#             TREE/scripts/release/manifest.txt); overridable for mutation.
#
# EXIT CODES: 0 pass, 1 not closed, 2 environment unusable.
set -uo pipefail

ROOT="${1:-$(cd "$(dirname "$0")/../.." && pwd)}"
MANIFEST="${2:-$ROOT/scripts/release/manifest.txt}"

if [[ ! -f "$MANIFEST" ]]; then
	echo "manifest_coverage_gate: no manifest at $MANIFEST" >&2
	exit 2
fi

fail=0
note_fail() { echo "MANIFEST COVERAGE FAIL: $*" >&2; fail=1; }

declare -A in_manifest=()
count=0
while IFS= read -r path || [[ -n "$path" ]]; do
	[[ -n "$path" ]] || continue
	in_manifest["$path"]=1
	count=$((count + 1))
done <"$MANIFEST"

# ---- require() closure ----
# Two-stage extraction on purpose: match the whole call in either shape, then
# pull the module id out, so one step serves both.
while IFS= read -r manifest_lua; do
	[[ -f "$ROOT/$manifest_lua" ]] || continue
	while IFS= read -r mod; do
		[[ -n "$mod" ]] || continue
		rel="lua/${mod//./\/}"
		direct="${rel}.lua"
		pkg="${rel}/init.lua"
		if [[ -z "${in_manifest[$direct]:-}" && -z "${in_manifest[$pkg]:-}" ]]; then
			note_fail "$manifest_lua requires '$mod' -> missing from manifest ($direct or $pkg)"
		fi
	done < <(grep -ohE \
		"require\(['\"](yana|blink_yana)\.[A-Za-z0-9_.]+['\"]\)|pcall\([[:space:]]*require[[:space:]]*,[[:space:]]*['\"](yana|blink_yana)\.[A-Za-z0-9_.]+['\"][[:space:]]*\)" \
		"$ROOT/$manifest_lua" \
		| grep -ohE "(yana|blink_yana)\.[A-Za-z0-9_.]+" \
		| sort -u)
done < <(grep -E '^lua/(yana|blink_yana)/.*\.lua$' "$MANIFEST")

# ---- bin/yana-* reference closure ----
while IFS= read -r manifest_file; do
	[[ -f "$ROOT/$manifest_file" ]] || continue
	while IFS= read -r bin_ref; do
		[[ -n "$bin_ref" ]] || continue
		if [[ -z "${in_manifest[$bin_ref]:-}" ]]; then
			note_fail "$manifest_file references $bin_ref -> missing from manifest"
		fi
	done < <(grep -ohE "bin/yana-[a-zA-Z0-9_-]+" "$ROOT/$manifest_file" | sort -u)
done < <(grep -E '^(lua|bin)/' "$MANIFEST")

if ((fail != 0)); then
	exit 1
fi
printf 'manifest coverage gate: scanned %d manifest-listed file(s)\n' "$count"
echo "MANIFEST COVERAGE GATE: PASS"
