#!/usr/bin/env bash
set -euo pipefail

# Candidate public repository: build an orphan-root import from an exported
# tree, and check that a candidate remote carries only allowed public history
# (release test YT-13). `check` runs against a local bare repository before
# operator approval and against the GitHub remote after push; it never writes
# to the remote.
#
# Incremental history policy (check):
#   - Advertised refs: only HEAD, refs/heads/main, and well-formed refs/tags/v*.
#   - main is linear with exactly one root (build()'s orphan import is the
#     degenerate case; multi-commit fast-forward history is also accepted).
#   - Every SemVer tag peels to an ancestor of main; that commit's VERSION
#     file equals the tag without the leading v.
#   - HEAD tree paths (not all historical blobs) must equal HEAD's manifest.
#   - Reachable main history (not rejected side branches) is audited with the
#     shipped path-class + forbidden-byte policy (scripts/release/lib/
#     forbidden_bytes.sh). A path may also appear if some main commit's
#     manifest listed it (historical ship set) — so a retired helper such as
#     bin/yana-ollama-agent in an older tagged release still passes.
#   - verify.sh runs on the HEAD checkout (ships in the export).
#     Do not call tests/release/manifest_coverage_gate.sh — not in the public
#     manifest.
#
# Tag modes for alpha.6 pre-/post-tag checks (explicit, never ambiguous):
#   default / --allow-untagged-head
#     HEAD may lack tag v$VERSION (pre-tag push of a bumped VERSION).
#   --require-version-tag
#     Annotated tag v$VERSION must exist and peel to an ancestor of HEAD
#     (including HEAD). Post-tag doc commits that keep the same VERSION pass.

usage() {
	printf 'Usage: %s build EXPORTED_TREE BARE_DIR\n' "$0" >&2
	printf '       %s check REMOTE_URL [--allow-untagged-head|--require-version-tag]\n' "$0" >&2
	exit 64
}

fail=0
note_fail() { echo "CANDIDATE FAIL: $*" >&2; fail=1; }

build() {
	local tree bare version
	tree=$(realpath "$1")
	bare=$2
	[[ -f "$tree/VERSION" && -f "$tree/scripts/release/manifest.txt" ]] \
		|| { echo "candidate build: not an exported tree: $tree" >&2; exit 1; }
	[[ ! -e "$tree/.git" ]] || { echo "candidate build: tree already has .git" >&2; exit 1; }
	[[ ! -e "$bare" ]] || { echo "candidate build: output already exists: $bare" >&2; exit 1; }
	version=$(tr -d '\r\n' <"$tree/VERSION")
	# Never import an unverified tree: the exporter's own policy must hold on
	# the exact bytes that become the public root commit.
	"$tree/scripts/release/verify.sh" "$tree" >/dev/null
	git init -q -b main "$tree"
	git -C "$tree" -c user.name="Yana Release" -c user.email="release@invalid" add -A
	git -C "$tree" -c user.name="Yana Release" -c user.email="release@invalid" \
		commit -q -m "Yana v$version initial import"
	[[ -z "$(git -C "$tree" log --format=%P -n 1)" ]] \
		|| { echo "candidate build: import commit has a parent" >&2; exit 1; }
	git init -q --bare -b main "$bare"
	git -C "$tree" push -q "$(realpath "$bare")" main
	printf 'CANDIDATE BUILD PASS version=%s commit=%s bare=%s\n' \
		"$version" "$(git -C "$tree" rev-parse HEAD)" "$bare"
}

# True when $1 is a well-formed public SemVer tag name (with leading v).
semver_tag_ok() {
	[[ "$1" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[1-9][0-9]*)?$ ]]
}

# Fail-closed audit of every blob reachable from main: path class / historical
# ship set, then forbidden-byte scan. Side branches are excluded by cloning
# only main after the ls-remote allowlist.
audit_main_history() {
	local clone=$1 scratch=$2
	local lib=$clone/scripts/release/lib/forbidden_bytes.sh
	local patterns=$clone/scripts/release/forbidden-patterns.txt
	local hist_root=$scratch/hist_blob
	local sha path type hits rc c

	[[ -f $lib && -f $patterns ]] || {
		note_fail "clone missing forbidden-byte policy ($lib / $patterns)"
		return
	}
	# shellcheck source=lib/forbidden_bytes.sh
	source "$lib"

	: >"$scratch/ship_paths"
	while IFS= read -r c; do
		git -C "$clone" show "$c:scripts/release/manifest.txt" 2>/dev/null || true
	done < <(git -C "$clone" rev-list main) | LC_ALL=C sort -u >"$scratch/ship_paths"

	mkdir -p "$hist_root"
	while read -r sha path; do
		[[ -n ${path:-} ]] || continue
		type=$(git -C "$clone" cat-file -t "$sha" 2>/dev/null) || continue
		[[ $type == blob ]] || continue

		if ! forbidden_bytes_allowed_path "$path"; then
			if ! grep -Fxq -- "$path" "$scratch/ship_paths"; then
				note_fail "history path outside public classes and historical ship set: $path"
				continue
			fi
		fi

		mkdir -p "$hist_root/$(dirname -- "$path")"
		git -C "$clone" cat-file blob "$sha" >"$hist_root/$path"
		set +e
		hits=$(forbidden_bytes_scan "$hist_root" "$patterns" "$path")
		rc=$?
		set -e
		rm -f "$hist_root/$path"
		if ((rc != 0)); then
			note_fail "forbidden bytes in main history: $path"
		fi
	done < <(git -C "$clone" rev-list --objects main)
}

check() {
	local url=$1
	local tag_mode=${2:---allow-untagged-head}
	case $tag_mode in
	--allow-untagged-head | --require-version-tag) ;;
	*)
		echo "candidate check: unknown tag mode: $tag_mode" >&2
		usage
		;;
	esac

	local clone scratch
	scratch=$(mktemp -d "${TMPDIR:-/tmp}/yana-candidate.XXXXXX")
	trap "rm -rf '$scratch'" EXIT
	clone=$scratch/clone

	# A clone only fetches advertised branch/tag namespaces; a development
	# object can hide on any other ref. Interrogate the remote's full
	# advertisement first and reject anything outside the allowed set
	# (including record/* draft branches).
	while IFS=$'\t ' read -r _ ref; do
		[[ -n "$ref" ]] || continue
		case $ref in
		refs/heads/main | HEAD) ;;
		refs/tags/v[0-9]*) ;;
		*) note_fail "remote advertises a ref outside the public set: $ref" ;;
		esac
	done < <(git ls-remote "$url")

	# Fetch only main (+ reachable tags). Side branches must already have
	# failed ls-remote; --single-branch keeps the clone surface narrow.
	git clone -q --single-branch --branch main "$url" "$clone"

	local head_commit version roots merges
	head_commit=$(git -C "$clone" rev-parse HEAD)
	version=$(tr -d '\r\n' <"$clone/VERSION")

	# Exactly one root on main; no merges (linear public history).
	mapfile -t roots < <(git -C "$clone" rev-list --max-parents=0 main)
	((${#roots[@]} == 1)) || note_fail "main does not have exactly one root (${#roots[@]} found)"
	[[ -z "$(git -C "$clone" log -1 --format=%P "${roots[0]}")" ]] \
		|| note_fail "root commit unexpectedly has a parent"
	mapfile -t merges < <(git -C "$clone" rev-list --min-parents=2 main)
	((${#merges[@]} == 0)) || note_fail "main is non-linear (merge commit present)"

	# Tags: well-formed, on main ancestry, peel VERSION matches tag name.
	local saw_version_tag=0
	while IFS= read -r ref; do
		case $ref in
		refs/heads/main | refs/remotes/origin/HEAD | refs/remotes/origin/main) ;;
		refs/tags/*)
			local tag=${ref#refs/tags/}
			local peel tag_version
			semver_tag_ok "$tag" || note_fail "malformed release tag: $tag"
			peel=$(git -C "$clone" rev-parse "$tag^{commit}")
			git -C "$clone" merge-base --is-ancestor "$peel" "$head_commit" \
				|| note_fail "tag $tag is not an ancestor of main"
			tag_version=$(git -C "$clone" show "$peel:VERSION" | tr -d '\r\n')
			[[ "$tag_version" == "${tag#v}" ]] \
				|| note_fail "tag $tag VERSION mismatch (peel has '$tag_version')"
			if [[ "$tag" == "v$version" ]]; then
				saw_version_tag=1
			fi
			;;
		*) note_fail "unexpected ref: $ref" ;;
		esac
	done < <(git -C "$clone" for-each-ref --format='%(refname)')

	if [[ $tag_mode == --require-version-tag ]]; then
		((saw_version_tag == 1)) \
			|| note_fail "required tag v$version is missing (--require-version-tag)"
	fi

	# The only remote is the checked URL's clone remote.
	[[ "$(git -C "$clone" remote)" == "origin" ]] || note_fail "unexpected remote set"

	# HEAD tree paths vs HEAD manifest — not every historical blob.
	git -C "$clone" ls-tree -r --name-only HEAD | LC_ALL=C sort >"$scratch/head_paths"
	LC_ALL=C sort -u "$clone/scripts/release/manifest.txt" >"$scratch/manifest_paths"
	if ! diff -u "$scratch/manifest_paths" "$scratch/head_paths" >&2; then
		note_fail "HEAD tree paths differ from HEAD manifest"
	fi

	# Content policy on the HEAD checkout (verify.sh ships in the export).
	"$clone/scripts/release/verify.sh" "$clone" || note_fail "verify.sh failed on the fresh clone"

	# Bounded history audit: reachable main only (not side branches).
	audit_main_history "$clone" "$scratch"

	(( fail == 0 )) || exit 1
	printf 'CANDIDATE CHECK PASS url=%s commit=%s tag_mode=%s\n' \
		"$url" "$(git -C "$clone" rev-parse HEAD)" "$tag_mode"
}

case "${1:-}" in
build)
	[[ $# == 3 ]] || usage
	build "$2" "$3"
	;;
check)
	[[ $# == 2 || $# == 3 ]] || usage
	check "$2" "${3:---allow-untagged-head}"
	;;
*) usage ;;
esac
