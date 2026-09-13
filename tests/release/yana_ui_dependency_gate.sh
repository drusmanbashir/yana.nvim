#!/usr/bin/env bash
# The release depends on yana-ui.nvim through ONE pin (scripts/release/yana-ui.pin),
# fetched anonymously by scripts/release/fetch-yana-ui.sh. Proves the pin works
# from a clean identity, and that each way of getting it wrong fails by name:
# a missing or malformed pin, a public surface naming another repo, a commit the
# public repo lacks, a URL anonymous users cannot clone, and a local checkout
# handed to fresh install through YANA_UI_ROOT.
#
# Usage: yana_ui_dependency_gate.sh EXPORTED_TREE NVIM   (needs network)
set -euo pipefail

[[ $# == 2 ]] || { echo "Usage: $0 EXPORTED_TREE NVIM" >&2; exit 64; }
tree=$(realpath "$1")
nvim=$(realpath "$2")
scratch=$(mktemp -d "${TMPDIR:-/tmp}/yana-ui-dependency.XXXXXX")
trap 'rm -rf "$scratch"' EXIT
version=$(tr -d '\r\n' <"$tree/VERSION")
pin_rel=scripts/release/yana-ui.pin
fetch_rel=scripts/release/fetch-yana-ui.sh

[[ -f "$tree/$pin_rel" && -x "$tree/$fetch_rel" ]] || {
	echo "YANA-UI DEPENDENCY GATE FAIL: $pin_rel or executable $fetch_rel missing from $tree" >&2
	exit 1
}
read -r pin_url pin_commit _ <"$tree/$pin_rel"

copy_case() {
	cp -a "$tree" "$scratch/$1"
	printf '%s\n' "$scratch/$1"
}

expect_red() {
	local name=$1 expected=$2
	shift 2
	local output="$scratch/$name.out"
	if "$@" >"$output" 2>&1; then
		echo "YANA-UI DEPENDENCY GATE FAIL: $name stayed green" >&2
		exit 1
	fi
	grep -Fq -- "$expected" "$output" || {
		echo "YANA-UI DEPENDENCY GATE FAIL: $name red for the wrong reason" >&2
		sed 's/^/  /' "$output" >&2
		exit 1
	}
	echo "MUTATION PASS: $name -> $expected"
}

# Control: the shipped tree verifies and the pin clones anonymously.
"$tree/scripts/release/verify.sh" "$tree" "v$version" >/dev/null
"$tree/$fetch_rel" "$scratch/control-ui" >"$scratch/control.out" 2>&1 || {
	sed 's/^/  /' "$scratch/control.out" >&2
	echo "YANA-UI DEPENDENCY GATE FAIL: anonymous fetch of the pin failed" >&2
	exit 1
}
[[ $(git -C "$scratch/control-ui" rev-parse HEAD) == "$pin_commit" \
	&& $(git -C "$scratch/control-ui" config --get remote.origin.url) == "$pin_url" \
	&& -f "$scratch/control-ui/lua/yana_ui/init.lua" ]] || {
	echo "YANA-UI DEPENDENCY GATE FAIL: fetched tree is not $pin_url at $pin_commit with lua/yana_ui" >&2
	exit 1
}
echo "CONTROL PASS: anonymous fetch of $pin_url at $pin_commit"

# Static policy (scripts/release/verify.sh).
case_tree=$(copy_case pin-missing)
rm "$case_tree/$pin_rel"
sed -i "\#^$pin_rel\$#d" "$case_tree/scripts/release/manifest.txt"
expect_red pin-missing "yana-ui pin missing" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case pin-local-url)
printf 'file:///opt/yana-ui %s\n' "$pin_commit" >"$case_tree/$pin_rel"
expect_red pin-local-url "yana-ui pin URL must be an anonymous https://github.com/OWNER/REPO URL" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case pin-branch-not-sha)
printf '%s main\n' "$pin_url" >"$case_tree/$pin_rel"
expect_red pin-branch-not-sha "yana-ui pin commit must be a 40-hex SHA" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

pin_repo=${pin_url#https://github.com/}
case_tree=$(copy_case readme-names-other-repo)
sed -i "s#\"$pin_repo\"#\"drusmanbashir/yana-ui\"#" "$case_tree/README.md"
expect_red readme-names-other-repo "README.md does not name the pinned yana-ui repo $pin_repo" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

case_tree=$(copy_case health-names-other-repo)
sed -i "s#'$pin_repo'#'drusmanbashir/yana-ui'#" "$case_tree/lua/yana/health.lua"
expect_red health-names-other-repo "lua/yana/health.lua does not name the pinned yana-ui repo $pin_repo" \
	"$case_tree/scripts/release/verify.sh" "$case_tree" "v$version"

# Network: the fetch itself (scripts/release/fetch-yana-ui.sh).
case_tree=$(copy_case commit-not-in-public-repo)
printf '%s %s\n' "$pin_url" c18ee3ed9edd3c865abbc1a9c4c64bf5d9cf8e57 >"$case_tree/$pin_rel"
expect_red commit-not-in-public-repo "pinned commit c18ee3ed9edd3c865abbc1a9c4c64bf5d9cf8e57 not found in $pin_url" \
	"$case_tree/$fetch_rel" "$scratch/commit-not-in-public-repo-ui"

case_tree=$(copy_case private-repo-url)
printf '%s %s\n' https://github.com/drusmanbashir/yana-ui "$pin_commit" >"$case_tree/$pin_rel"
expect_red private-repo-url "anonymous clone refused: https://github.com/drusmanbashir/yana-ui" \
	"$case_tree/$fetch_rel" "$scratch/private-repo-url-ui"

# Local fallback: fresh install must refuse a host checkout before using it.
case_tree=$(copy_case local-yana-ui-root)
mkdir -p "$scratch/local-ui/lua/yana_ui"
expect_red local-yana-ui-root "fresh-install: YANA_UI_ROOT is refused" \
	env YANA_UI_ROOT="$scratch/local-ui" "$case_tree/tests/release/fresh_install.sh" "$case_tree" "$nvim"

echo "YANA-UI DEPENDENCY GATE PASS url=$pin_url commit=$pin_commit"
