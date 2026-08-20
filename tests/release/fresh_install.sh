#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 ]] || { echo "Usage: $0 EXPORTED_TREE NVIM" >&2; exit 64; }
tree=$(realpath "$1")
nvim=$(realpath "$2")
tmp=${TMPDIR:-/tmp}
scratch=$(mktemp -d "$tmp/yana-fresh.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

if env | awk -F= '$1 ~ /^YANA_/' | grep -q .; then
	echo "fresh-install: undeclared YANA_* variable reached the harness" >&2
	exit 1
fi

home="$scratch/home"
config="$scratch/config"
data="$scratch/data"
state="$scratch/state"
cache="$scratch/cache"
plugin="$data/nvim/site/pack/release/start/yana.nvim"
mkdir -p "$home" "$config/nvim" "$plugin" "$state" "$cache"
cp -a "$tree/." "$plugin/"

env -i \
	HOME="$home" \
	PATH="$(dirname "$nvim"):/usr/bin:/bin" \
	XDG_CONFIG_HOME="$config" \
	XDG_DATA_HOME="$data" \
	XDG_STATE_HOME="$state" \
	XDG_CACHE_HOME="$cache" \
	LC_ALL=C TZ=UTC \
	"$nvim" --headless -u NONE -i NONE \
	--cmd "set packpath^=$data/nvim/site" \
	--cmd 'packloadall' \
	-l "$plugin/tests/release/smoke.lua"

printf 'FRESH INSTALL PASS nvim=%s root=%s\n' "$($nvim --version | head -1)" "$plugin"
