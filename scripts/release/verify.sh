#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: %s TREE [TAG]\n' "$0" >&2
	exit 64
}

(( $# == 1 || $# == 2 )) || usage
tree=$(realpath "$1")
tag=${2:-}
manifest="$tree/scripts/release/manifest.txt"
patterns="$tree/scripts/release/forbidden-patterns.txt"
fail=0

die() { echo "VERIFY FAIL: $*" >&2; exit 1; }
note_fail() { echo "VERIFY FAIL: $*" >&2; fail=1; }

[[ -d "$tree" ]] || die "tree not found: $tree"
[[ -f "$manifest" && -f "$patterns" ]] || die "release policy files missing"
LC_ALL=C sort -cu "$manifest" || die "manifest must be sorted and unique"

# Shared with tests/forbidden_bytes_gate.sh (row 62): the path-class classifier and the
# forbidden-byte scan itself both live in scripts/release/lib/forbidden_bytes.sh so the
# exported-tree check here and the working-tree gate can never disagree about what is
# scanned or what is forbidden. Sourced from beside this script, not from "$tree", so
# `verify.sh` keeps working when invoked to check a tree other than its own
# (candidate.sh runs a clone's own copy; either way the copy running carries its own
lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/forbidden_bytes.sh"
[[ -f "$lib" ]] || die "shared forbidden-bytes lib missing: $lib"
# shellcheck source=lib/forbidden_bytes.sh
source "$lib"

# The manifest may narrow the public file set but may not add a class of file
# the release module excludes: every entry must match one of these hard-coded
# classes, so editing the manifest cannot smuggle a new path class into the
# export.
allowed_path() { forbidden_bytes_allowed_path "$1"; }
while IFS= read -r path; do
	allowed_path "$path" || note_fail "manifest path outside the allowed public classes: $path"
done <"$manifest"

required_patterns=(
	"sp""ec/"
	"sp""ecs/"
	"hand""off/"
	"AGENTS\\.md"
	"launch-profile-""design"
	"NEO""CURSOR"
	"neo""cursor"
	"/home/""ub"
	"/s/agent_""rw"
	"sp""ec_v2"
	"CORE""\\.md"
	"BUILD-""SHORTLIST"
	"adversarial[[:space:]]+review"
)
for required in "${required_patterns[@]}"; do
	grep -Fqx "$required" "$patterns" || die "required scanner pattern missing: $required"
done

tmp=${TMPDIR:-/tmp}
expected=$(mktemp "$tmp/yana-verify.expected.XXXXXX")
actual=$(mktemp "$tmp/yana-verify.actual.XXXXXX")
hits=$(mktemp "$tmp/yana-verify.hits.XXXXXX")
trap 'rm -f "$expected" "$actual" "$hits"' EXIT
cp "$manifest" "$expected"
(
	cd "$tree"
	find . -path './.git' -prune -o -type l -print -o -type f -print \
		| sed 's|^\./||' | LC_ALL=C sort
) >"$actual"
if ! diff -u "$expected" "$actual"; then
	note_fail "exported files differ from manifest"
fi

while IFS= read -r link; do
	note_fail "symlink forbidden: ${link#./}"
done < <(cd "$tree" && find . -path './.git' -prune -o -type l -print)

# Every local Markdown link in a shipped .md file must name a file inside the
# exported tree: README sends users to docs/, so a manifest that drops a page
# ships a dead link, and a ../ link points outside what the user installed.
links_lib="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/doc_links.sh"
[[ -f "$links_lib" ]] || die "shared doc-links lib missing: $links_lib"
# shellcheck source=lib/doc_links.sh
source "$links_lib"
while IFS= read -r doc; do
	while IFS= read -r target; do
		resolved=$(doc_links_resolve "$doc" "$target")
		if [[ "$resolved" == ".." || "$resolved" == ../* ]]; then
			note_fail "local link leaves the exported tree in $doc: $target"
		elif [[ ! -f "$tree/$resolved" ]]; then
			note_fail "dead local link in $doc: $target"
		fi
	done < <(doc_links_targets "$tree/$doc")
done < <(grep -E '\.md$' "$manifest")

# yana.nvim's one required dependency has one pin: an anonymous public GitHub
# URL and a commit SHA. Every user-facing install surface must name that repo,
# so a rename or a private fork cannot ship behind a green export.
ui_pin="$tree/scripts/release/yana-ui.pin"
if [[ ! -f "$ui_pin" ]]; then
	note_fail "yana-ui pin missing: scripts/release/yana-ui.pin"
else
	ui_url= ui_commit= ui_extra=
	read -r ui_url ui_commit ui_extra <"$ui_pin" || true
	[[ "$ui_url" =~ ^https://github\.com/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$ ]] \
		|| note_fail "yana-ui pin URL must be an anonymous https://github.com/OWNER/REPO URL: $ui_url"
	[[ "$ui_commit" =~ ^[0-9a-f]{40}$ ]] || note_fail "yana-ui pin commit must be a 40-hex SHA: $ui_commit"
	[[ -z "$ui_extra" && $(wc -l <"$ui_pin") == 1 ]] || note_fail "yana-ui pin must be one line: URL SHA"
	ui_repo=${ui_url#https://github.com/}
	for surface in README.md doc/yana.txt; do
		grep -Fq "dependencies = { \"$ui_repo\" }" "$tree/$surface" \
			|| note_fail "$surface does not name the pinned yana-ui repo $ui_repo"
	done
	grep -Fq "'$ui_repo'" "$tree/lua/yana/health.lua" \
		|| note_fail "lua/yana/health.lua does not name the pinned yana-ui repo $ui_repo"
fi

echo "VERIFY EXEMPT: scripts/release/forbidden-patterns.txt is the scanner registry"
echo "VERIFY EXEMPT: NOTICE's one audited upstream repository URL line"
while IFS= read -r path; do
	if forbidden_bytes_binary_path "$path"; then
		continue
	fi
	# The byte scanner reads text line-wise, so an encoding that splits the
	# identity across NUL bytes (UTF-16) or invalid UTF-8 would slip past it.
	# Shipped binary assets are exempt by path class above; all text files
	# still refuse both outright.
	if [[ $(LC_ALL=C tr -dc '\0' <"$tree/$path" | wc -c) -gt 0 ]]; then
		note_fail "NUL bytes in $path (binary or wide encoding is not scannable)"
	fi
	if ! iconv -f UTF-8 -t UTF-8 "$tree/$path" >/dev/null 2>&1; then
		note_fail "not valid UTF-8: $path"
	fi
	[[ "$path" == "scripts/release/forbidden-patterns.txt" ]] && continue
	: >"$hits"
	forbidden_bytes_scan "$tree" "$patterns" "$path" >"$hits" || true
	if [[ -s "$hits" ]]; then
		note_fail "forbidden bytes in $path"
		sed 's/^/  /' "$hits" >&2
	fi
done <"$manifest"

version=$(tr -d '\r\n' <"$tree/VERSION")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[1-9][0-9]*)?$ ]] \
	|| note_fail "VERSION is not an accepted SemVer prerelease/stable value: $version"
grep -Eqx "## $(sed 's/[.[\\*^$+?{}|()]/\\&/g' <<<"$version") - [0-9]{4}-[0-9]{2}-[0-9]{2}" "$tree/CHANGELOG.md" \
	|| note_fail "CHANGELOG has no dated release heading for $version"
grep -Eq "version $(sed 's/[.[\\*^$+?{}|()]/\\&/g' <<<"$version")([[:space:]]|$)" "$tree/doc/yana.txt" \
	|| note_fail "help version does not equal VERSION"
if [[ -n "$tag" && "$tag" != "v$version" ]]; then
	note_fail "tag $tag does not equal v$version"
fi

# LICENSE is the unmodified Apache 2.0 text; its appendix carries only the licensor's
# own copyright (Yana / Usman Bashir), per the Apache boilerplate. Both checks below
# therefore read NOTICE, not LICENSE.
grep -Fq "Copyright 2026 Usman Bashir" "$tree/LICENSE" \
	|| note_fail "Yana copyright holder missing from LICENSE"
grep -Fqx "Copyright (c) 2026 The Sigillite" "$tree/NOTICE" \
	|| note_fail "upstream copyright holder missing from NOTICE"
grep -Fqx "Copyright 2026 Usman Bashir" "$tree/NOTICE" \
	|| note_fail "Yana copyright notice missing from NOTICE"
grep -Fqx "https://github.com/just-nibble/$(printf neo)$(printf cursor).git" "$tree/NOTICE" \
	|| note_fail "audited upstream URL missing from NOTICE"
grep -Fqx "Recorded fork point: e85d8e077bec53237810fc848f635e4ad440284a" "$tree/NOTICE" \
	|| note_fail "fork point missing from NOTICE"

# Public diagnostic environment surface. Keep this explicit: adding a runtime
# YANA_* dial without adding it here leaves release verification unaware of a
# host-controlled behavior change. Fresh-install still starts under env -i;
# this registry checks declaration/documentation, not inheritance.
public_diagnostic_env=(YANA_DEBUG_EVENTS YANA_LIFECYCLE_LOG)
for env_name in "${public_diagnostic_env[@]}"; do
	grep -Fq "$env_name" "$tree/doc/yana.txt" \
		|| note_fail "public diagnostic variable missing from help: $env_name"
	grep -Rqs "$env_name" "$tree/lua/yana" \
		|| note_fail "public diagnostic variable has no runtime reader: $env_name"
done
while IFS= read -r runtime_path; do
	if ! grep -Fqx -- "- upstream-derived: \`$runtime_path\`" "$tree/NOTICE" \
		&& ! grep -Fqx -- "- post-fork original: \`$runtime_path\`" "$tree/NOTICE"; then
		note_fail "runtime provenance classification missing: $runtime_path"
	fi
done < <(grep -E '^(bin/|lua/|plugin/)' "$manifest")

for helper in "$tree"/bin/yana-*; do
	[[ -x "$helper" ]] || note_fail "helper is not executable: ${helper#$tree/}"
done

python3 "$tree/tests/release/workflow_policy.py" "$tree"
python3 "$tree/tests/release/neovim_matrix_policy.py" "$tree"
(( fail == 0 )) || exit 1
printf 'VERIFY PASS version=%s files=%s\n' "$version" "$(wc -l <"$manifest")"
