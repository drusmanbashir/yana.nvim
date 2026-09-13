#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: SOURCE_DATE_EPOCH=<commit-time> %s TREE OUTPUT_DIR\n' "$0" >&2
	exit 64
}

[[ $# == 2 ]] || usage
[[ ${SOURCE_DATE_EPOCH:-} =~ ^[0-9]+$ ]] || {
	echo "archive: SOURCE_DATE_EPOCH must be the source commit timestamp" >&2
	exit 64
}
tree=$(realpath "$1")
out=$(realpath -m "$2")
version=$(tr -d '\r\n' <"$tree/VERSION")
name="yana.nvim-$version"
archive="$out/$name.tar.gz"
list=$(mktemp)
tarball=$(mktemp)
trap 'rm -f "$list" "$tarball"' EXIT

"$tree/scripts/release/verify.sh" "$tree" "v$version"
mkdir -p "$out"
(
	cd "$tree"
	printf '%s\n' LICENSE NOTICE README.md CHANGELOG.md VERSION
	find assets doc docs lua plugin bin -type f -print
) | LC_ALL=C sort -u >"$list"

# verify.sh proved the export's links; the tarball is a different file set, so
# every local link in an archived .md must also name an archive member.
# shellcheck source=lib/doc_links.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/lib/doc_links.sh"
while IFS= read -r doc; do
	while IFS= read -r target; do
		grep -Fqx -- "$(doc_links_resolve "$doc" "$target")" "$list" \
			|| { echo "archive: dead local link in $doc: $target" >&2; exit 1; }
	done < <(doc_links_targets "$tree/$doc")
done < <(grep -E '\.md$' "$list")

# Archive modes come from the filesystem, so an accidental chmod between
# export and build would ship silently (both comparison builds see the same
# drifted mode). Enforce the Git mode shape while tolerating the checkout
# umask's group-write bit, which tar normalizes away below. Executable
# classes: bin launchers (bin/yana-*, bin/yanad) and overlay shell helpers
# (bin/lib/yana-overlay/*.sh). Non-executable: bin/lib/yanad/*.py and every
# other archive member.
while IFS= read -r member; do
	mode=$(stat -c %a "$tree/$member")
	case $member in
	bin/lib/yanad/*.py)
		[[ "$mode" == 644 || "$mode" == 664 ]] \
			|| { echo "archive: $member must be mode 644, found $mode" >&2; exit 1; }
		;;
	bin/*)
		[[ "$mode" == 755 || "$mode" == 775 ]] \
			|| { echo "archive: $member must be mode 755, found $mode" >&2; exit 1; }
		;;
	*)
		[[ "$mode" == 644 || "$mode" == 664 ]] \
			|| { echo "archive: $member must be mode 644, found $mode" >&2; exit 1; }
		;;
	esac
done <"$list"

LC_ALL=C TZ=UTC tar -C "$tree" --null --files-from=<(tr '\n' '\0' <"$list") \
	--sort=name --format=pax --pax-option=delete=atime,delete=ctime \
	--mtime="@$SOURCE_DATE_EPOCH" --owner=0 --group=0 --numeric-owner --mode=go-w \
	--transform="s,^,$name/," -cf "$tarball"
gzip -n -c "$tarball" >"$archive"
(cd "$out" && sha256sum "$(basename "$archive")" >SHA256SUMS)
printf 'ARCHIVE PASS %s\n' "$archive"
