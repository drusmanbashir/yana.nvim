#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 ]] || { echo "Usage: $0 VERSION OUTPUT_DIR" >&2; exit 64; }
version=$1
out=$2
root=$(cd "$(dirname "$0")/../.." && pwd -P)
row=$(awk -v v="$version" '$1 == v { print; exit }' "$root/scripts/release/neovim-matrix.txt")
[[ -n "$row" ]] || { echo "install-neovim: unknown version $version" >&2; exit 1; }
read -r _ url expected <<<"$row"
[[ "$expected" =~ ^[0-9a-f]{64}$ ]] || { echo "install-neovim: unpinned checksum for $version" >&2; exit 1; }
mkdir -p "$out"
archive="$out/nvim-$version.tar.gz"
curl -fL --retry 3 --proto '=https' -o "$archive" "$url"
printf '%s  %s\n' "$expected" "$archive" | sha256sum -c -
tar -xzf "$archive" -C "$out"
printf '%s\n' "$out/nvim-linux-x86_64/bin/nvim"
