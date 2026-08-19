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
	find doc lua plugin bin -type f -print
) | LC_ALL=C sort -u >"$list"

# Archive modes come from the filesystem, so an accidental chmod between
# export and build would ship silently (both comparison builds see the same
# drifted mode). Enforce the Git mode shape — the exact executable set is the
# bin helpers and nothing else — while tolerating the checkout umask's
# group-write bit, which tar normalizes away below.
while IFS= read -r member; do
	mode=$(stat -c %a "$tree/$member")
	case $member in
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
