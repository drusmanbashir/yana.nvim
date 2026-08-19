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

# The manifest may narrow the public file set but may not add a class of file
# the release module excludes: every entry must match one of these hard-coded
# classes, so editing the manifest cannot smuggle a new path class into the
# export.
allowed_path() {
	case $1 in
	.github/workflows/ci.yml | .github/workflows/release.yml) return 0 ;;
	.gitignore | .stylua.toml | CHANGELOG.md | LICENSE | NOTICE | README.md | VERSION) return 0 ;;
	doc/yana.txt | plugin/yana.lua) return 0 ;;
	lua/yana/*.lua | lua/yana/*/*.lua | lua/blink_yana/*.lua) return 0 ;;
	bin/yana-[a-z]*) return 0 ;;
	scripts/release/*) return 0 ;;
	tests/release/*) return 0 ;;
	esac
	return 1
}
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
	"sp""ec_v2"
	"CORE""\\.md"
	"BUILD-""SHORTLIST"
	"adversarial[[:space:]]+review"
)
for required in "${required_patterns[@]}"; do
	grep -Fqx "$required" "$patterns" || die "required scanner pattern missing: $required"
done

tmp=${TMPDIR:-/s/agent_rw/tmp}
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

echo "VERIFY EXEMPT: scripts/release/forbidden-patterns.txt is the scanner registry"
echo "VERIFY EXEMPT: NOTICE:4 is the audited upstream repository URL"
while IFS= read -r path; do
	# The byte scanner reads text line-wise, so an encoding that splits the
	# identity across NUL bytes (UTF-16) or invalid UTF-8 would slip past it.
	# No shipped file is binary; refuse both outright.
	if [[ $(LC_ALL=C tr -dc '\0' <"$tree/$path" | wc -c) -gt 0 ]]; then
		note_fail "NUL bytes in $path (binary or wide encoding is not scannable)"
	fi
	if ! iconv -f UTF-8 -t UTF-8 "$tree/$path" >/dev/null 2>&1; then
		note_fail "not valid UTF-8: $path"
	fi
	[[ "$path" == "scripts/release/forbidden-patterns.txt" ]] && continue
	: >"$hits"
	LC_ALL=C grep -aEin -f "$patterns" "$tree/$path" >"$hits" || true
	if [[ "$path" == "NOTICE" ]]; then
		legacy=neo
		legacy+=cursor
		grep -Ev "^4:https://github\\.com/just-nibble/${legacy}\\.git$" "$hits" >"$hits.filtered" || true
		mv "$hits.filtered" "$hits"
	fi
	if [[ -s "$hits" ]]; then
		note_fail "forbidden bytes in $path"
		sed 's/^/  /' "$hits" >&2
	fi
done <"$manifest"

version=$(tr -d '\r\n' <"$tree/VERSION")
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-rc\.[1-9][0-9]*)?$ ]] \
	|| note_fail "VERSION is not an accepted SemVer candidate/stable value: $version"
grep -Eqx "## $(sed 's/[.[\\*^$+?{}|()]/\\&/g' <<<"$version") - [0-9]{4}-[0-9]{2}-[0-9]{2}" "$tree/CHANGELOG.md" \
	|| note_fail "CHANGELOG has no dated release heading for $version"
grep -Eq "version $(sed 's/[.[\\*^$+?{}|()]/\\&/g' <<<"$version")([[:space:]]|$)" "$tree/doc/yana.txt" \
	|| note_fail "help version does not equal VERSION"
if [[ -n "$tag" && "$tag" != "v$version" ]]; then
	note_fail "tag $tag does not equal v$version"
fi

grep -Fqx "Copyright (c) 2026 The Sigillite" "$tree/LICENSE" \
	|| note_fail "upstream copyright holder missing from LICENSE"
grep -Fqx "https://github.com/just-nibble/$(printf neo)$(printf cursor).git" "$tree/NOTICE" \
	|| note_fail "audited upstream URL missing from NOTICE"
grep -Fqx "Recorded fork point: e85d8e077bec53237810fc848f635e4ad440284a" "$tree/NOTICE" \
	|| note_fail "fork point missing from NOTICE"
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
(( fail == 0 )) || exit 1
printf 'VERIFY PASS version=%s files=%s\n' "$version" "$(wc -l <"$manifest")"
