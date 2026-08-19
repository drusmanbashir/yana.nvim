#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 ]] || { echo "Usage: $0 EXPORTED_TREE NVIM" >&2; exit 64; }
tree=$(realpath "$1")
nvim=$(realpath "$2")
scratch=$(mktemp -d "${TMPDIR:-/s/agent_rw/tmp}/yana-confined.XXXXXX")
trap 'rm -rf "$scratch"' EXIT

run_smoke() {
	env -i \
		HOME="$scratch/home" \
		PATH="$(dirname "$nvim"):/usr/bin:/bin:/usr/sbin:/sbin" \
		YANA_CONFINED_SCRATCH="$scratch/turn" \
		XDG_CONFIG_HOME="$scratch/config" \
		XDG_DATA_HOME="$scratch/data" \
		XDG_STATE_HOME="$scratch/state" \
		XDG_CACHE_HOME="$scratch/cache" \
		LC_ALL=C TZ=UTC \
		"$@" \
		"$nvim" --clean --headless -u NONE -i NONE \
		--cmd "set rtp^=$tree" -l "$tree/tests/release/confined_turn_smoke.lua"
}

# Mutation guard first: a harness that runs green while a development checkout
# is injected proves nothing. Any non-empty YANA_REPO_DIR must be refused
# before the plugin loads.
if run_smoke YANA_REPO_DIR="${DEV_CHECKOUT:-$scratch}"; then
	echo "CONFINED TURN GATE FAIL: contaminated environment was not refused" >&2
	exit 1
fi

rc=0
run_smoke || rc=$?
if [[ $rc == 65 ]]; then
	echo "CONFINED TURN GATE INCONCLUSIVE: bwrap unavailable" >&2
	exit 65
fi
[[ $rc == 0 ]] || exit "$rc"

echo "CONFINED TURN GATE PASS"
