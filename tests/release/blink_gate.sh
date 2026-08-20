#!/usr/bin/env bash
set -euo pipefail

[[ $# == 3 ]] || { echo "Usage: $0 EXPORTED_TREE NVIM BLINK_TREE" >&2; exit 64; }
tree=$(realpath "$1")
nvim=$(realpath "$2")
blink=$(realpath "$3")
[[ $(git -C "$blink" rev-parse HEAD) == 78336bc89ee5365633bcf754d93df01678b5c08f ]] \
	|| { echo "blink gate: unexpected blink.cmp commit" >&2; exit 1; }
scratch=$(mktemp -d "${TMPDIR:-/tmp}/yana-blink.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

env -i \
	HOME="$scratch/home" \
	PATH="$(dirname "$nvim"):/usr/bin:/bin" \
	RELEASE_BLINK_ROOT="$blink" \
	XDG_CONFIG_HOME="$scratch/config" \
	XDG_DATA_HOME="$scratch/data" \
	XDG_STATE_HOME="$scratch/state" \
	XDG_CACHE_HOME="$scratch/cache" \
	LC_ALL=C TZ=UTC \
	"$nvim" --clean --headless -u NONE -i NONE \
	--cmd "set rtp^=$tree" -l "$tree/tests/release/blink_smoke.lua"

echo "BLINK GATE PASS"
