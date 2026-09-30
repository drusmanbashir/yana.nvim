#!/usr/bin/env bash
set -euo pipefail

usage() {
	printf 'Usage: %s COMMIT OUTPUT_DIR\n' "$0" >&2
	exit 64
}

[[ $# == 2 ]] || usage
commit=$1
out=$2
root=$(git -C "$(dirname "$0")/../.." rev-parse --show-toplevel)
manifest=$(mktemp)
trap 'rm -f "$manifest"' EXIT

git -C "$root" cat-file -e "$commit^{commit}"
git -C "$root" show "$commit:scripts/release/manifest.txt" >"$manifest" \
	|| { echo "export: manifest missing from commit $commit" >&2; exit 1; }
[[ ! -e "$out" ]] || { echo "export: output already exists: $out" >&2; exit 1; }
mkdir -p "$out"

paths=()
while IFS= read -r path || [[ -n "$path" ]]; do
	[[ -n "$path" && "$path" != /* && "$path" != *'..'* ]] || {
		echo "export: unsafe or empty manifest entry: $path" >&2
		exit 1
	}
	mode_type=$(git -C "$root" ls-tree "$commit" -- "$path" | awk 'NR == 1 { print $1, $2 }')
	[[ "$mode_type" == "100644 blob" || "$mode_type" == "100755 blob" ]] || {
		echo "export: manifest entry is missing, non-file, or symlink: $path ($mode_type)" >&2
		exit 1
	}
	paths+=("$path")
done <"$manifest"

git -C "$root" archive --format=tar "$commit" -- "${paths[@]}" | tar -xf - -C "$out"
"$out/scripts/release/verify.sh" "$out"
printf 'EXPORT PASS commit=%s files=%d output=%s\n' \
	"$(git -C "$root" rev-parse "$commit^{commit}")" "${#paths[@]}" "$out"
