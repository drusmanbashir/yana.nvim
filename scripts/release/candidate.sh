#!/usr/bin/env bash
set -euo pipefail

# Candidate public repository: build an orphan-root import from an exported
# tree, and check that a candidate remote carries only allowed public history
# (release test YT-13). `check` runs against a local bare repository before
# operator approval and against the GitHub remote after push; it never writes
# to the remote.

usage() {
	printf 'Usage: %s build EXPORTED_TREE BARE_DIR\n       %s check REMOTE_URL\n' "$0" "$0" >&2
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
	# ...and the manifest itself must be require()-closed and bin/yana-*
	# reference-closed, or a fresh public install crashes on the first
	# require() the manifest silently dropped (order B4 Part B2).
	"$tree/tests/release/manifest_coverage_gate.sh" "$tree" >/dev/null
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

check() {
	local url clone scratch
	url=$1
	scratch=$(mktemp -d "${TMPDIR:-/tmp}/yana-candidate.XXXXXX")
	trap "rm -rf '$scratch'" EXIT
	clone=$scratch/clone

	# A clone only fetches advertised branch/tag namespaces; a development
	# object can hide on any other ref. Interrogate the remote's full
	# advertisement first and reject anything outside the allowed set.
	while IFS=$'\t ' read -r _ ref; do
		[[ -n "$ref" ]] || continue
		case $ref in
		refs/heads/main | HEAD) ;;
		refs/tags/v[0-9]*) ;;
		*) note_fail "remote advertises a ref outside the public set: $ref" ;;
		esac
	done < <(git ls-remote "$url")

	git clone -q "$url" "$clone"

	# (b) exactly one commit, no parent: the public history is an orphan root.
	[[ "$(git -C "$clone" rev-list --all --count)" == 1 ]] \
		|| note_fail "history is not a single commit"
	[[ -z "$(git -C "$clone" log --all --format=%P | tr -d '[:space:]')" ]] \
		|| note_fail "a commit has a parent (imported development history)"

	# (c) refs are only main plus well-formed release tags, and any tag must
	# be exactly v<VERSION> pointing at the single public commit.
	local version head_commit
	version=$(tr -d '\r\n' <"$clone/VERSION")
	head_commit=$(git -C "$clone" rev-parse HEAD)
	while IFS= read -r ref; do
		case $ref in
		refs/heads/main | refs/remotes/origin/HEAD | refs/remotes/origin/main) ;;
		refs/tags/*)
			local tag=${ref#refs/tags/}
			[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+(-(alpha|beta|rc)\.[1-9][0-9]*)?$ ]] \
				|| note_fail "malformed release tag: $tag"
			[[ "$tag" == "v$version" ]] \
				|| note_fail "tag $tag does not equal v$version"
			[[ "$(git -C "$clone" rev-parse "$tag^{commit}")" == "$head_commit" ]] \
				|| note_fail "tag $tag does not point at the public commit"
			;;
		*) note_fail "unexpected ref: $ref" ;;
		esac
	done < <(git -C "$clone" for-each-ref --format='%(refname)')

	# (d) the only remote is the checked URL.
	[[ "$(git -C "$clone" remote)" == "origin" ]] || note_fail "unexpected remote set"

	# (a) every blob path is in the manifest and vice versa.
	git -C "$clone" rev-list --objects --all \
		| git -C "$clone" cat-file --batch-check='%(objecttype) %(rest)' \
		| awk '$1 == "blob" { $1 = ""; sub(/^ /, ""); print }' \
		| LC_ALL=C sort -u >"$scratch/blobs"
	if ! diff -u "$clone/scripts/release/manifest.txt" "$scratch/blobs" >&2; then
		note_fail "object paths differ from manifest"
	fi

	# (e) content policy: the clone's own verifier scans every manifest file
	# for forbidden bytes and re-checks identity, provenance, and workflows.
	"$clone/scripts/release/verify.sh" "$clone" || note_fail "verify.sh failed on the fresh clone"
	"$clone/tests/release/manifest_coverage_gate.sh" "$clone" \
		|| note_fail "manifest_coverage_gate.sh failed on the fresh clone"

	(( fail == 0 )) || exit 1
	printf 'CANDIDATE CHECK PASS url=%s commit=%s\n' \
		"$url" "$(git -C "$clone" rev-parse HEAD)"
}

case "${1:-}" in
build) [[ $# == 3 ]] || usage; build "$2" "$3" ;;
check) [[ $# == 2 ]] || usage; check "$2" ;;
*) usage ;;
esac
