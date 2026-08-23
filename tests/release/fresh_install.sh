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

# ---------------------------------------------------------------------------
# TURN SMOKE: setup()+panel-open above proves the export installs and loads,
# but it never submits a prompt, so a runtime module reachable only from
# inside a real turn -- direct require() like lua/yana/agent.lua's
# require("yana.vendor_stream"), or a guarded pcall(require, ...) like
# lua/yana/inline_diff.lua's cross-file undo -- is invisible to it. Drive
# ONE turn against the SAME installed tree ($plugin, not $tree/dev) that
# smoke.lua just proved installs, via tests/release/turn_smoke.lua: hunk
# appears, accept it, undo, assert no Lua error AND that undo actually went
# through yana's own handler rather than silently falling back to Neovim's.
#
# Needs real bwrap confinement (mode=inline), same requirement as
# tests/release/confined_turn_gate.sh: the overlay applies `--tmpfs /tmp`
# while building the sandbox, so a scratch under /tmp binds in empty and the
# turn cannot run. Same resolution order as that gate: an explicit
# YANA_HEADLESS_TMPDIR wins, then a TMPDIR that is itself not under /tmp,
# else refuse rather than hand the overlay a root that cannot work.
if [[ -n ${YANA_HEADLESS_TMPDIR:-} ]]; then
	jail_tmpdir=$YANA_HEADLESS_TMPDIR
elif [[ -n ${TMPDIR:-} && $TMPDIR != /tmp && $TMPDIR != /tmp/* ]]; then
	jail_tmpdir=$TMPDIR
else
	echo "fresh-install: refusing the turn smoke -- overlay workspace root needs YANA_HEADLESS_TMPDIR or a TMPDIR outside /tmp (the jail mounts a fresh tmpfs over /tmp)" >&2
	exit 65
fi
mkdir -p "$jail_tmpdir"
turn_scratch=$(mktemp -d "$jail_tmpdir/yana-fresh-turn.XXXXXX")
trap 'rm -rf "$scratch" "$turn_scratch"' EXIT

set +e
env -i \
	HOME="$home" \
	PATH="$(dirname "$nvim"):/usr/bin:/bin:/usr/sbin:/sbin" \
	XDG_CONFIG_HOME="$config" \
	XDG_DATA_HOME="$data" \
	XDG_STATE_HOME="$state" \
	XDG_CACHE_HOME="$cache" \
	YANA_TURN_SMOKE_SCRATCH="$turn_scratch" \
	LC_ALL=C TZ=UTC \
	"$nvim" --clean --headless -u NONE -i NONE \
	--cmd "set rtp^=$plugin" \
	-l "$plugin/tests/release/turn_smoke.lua"
turn_rc=$?
set -e

if [[ $turn_rc == 65 ]]; then
	echo "fresh-install: turn smoke INCONCLUSIVE -- bwrap unavailable" >&2
	exit 65
fi
[[ $turn_rc == 0 ]] || exit "$turn_rc"

printf 'FRESH INSTALL TURN SMOKE PASS nvim=%s root=%s\n' "$($nvim --version | head -1)" "$plugin"
