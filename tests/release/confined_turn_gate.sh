#!/usr/bin/env bash
set -euo pipefail

[[ $# == 2 ]] || { echo "Usage: $0 EXPORTED_TREE NVIM" >&2; exit 64; }
tree=$(realpath "$1")
nvim=$(realpath "$2")

# This scratch becomes the overlay's WORKSPACE and LAYER_ROOT
# (bin/yana-overlay --workspace/--upper/--work). run_overlay applies
# `--tmpfs /tmp` while building the bwrap sandbox, so any host path under
# /tmp is masked by the time the later `--ro-bind $WORKSPACE ...` /
# `--bind $LAYER_ROOT ...` args run -- a scratch placed under /tmp binds in
# empty and the confined turn cannot run. Same requirement, same resolution
# order as tests/headless_gate.sh: an explicit YANA_HEADLESS_TMPDIR wins,
# then a TMPDIR that itself is not under /tmp, else refuse rather than hand
# the overlay a root that cannot work.
if [[ -n ${YANA_HEADLESS_TMPDIR:-} ]]; then
	jail_tmpdir=$YANA_HEADLESS_TMPDIR
elif [[ -n ${TMPDIR:-} && $TMPDIR != /tmp && $TMPDIR != /tmp/* ]]; then
	jail_tmpdir=$TMPDIR
else
	echo "confined_turn_gate: refusing -- overlay workspace root needs YANA_HEADLESS_TMPDIR or a TMPDIR outside /tmp (the jail mounts a fresh tmpfs over /tmp)" >&2
	exit 65
fi
mkdir -p "$jail_tmpdir"
scratch=$(mktemp -d "$jail_tmpdir/yana-confined.XXXXXX")

# Every yanad this gate starts runs with --root under $scratch (XDG_STATE_HOME
# is $scratch/turn/state). Empty roots are skipped: an empty root would match
# every yanad on the host. Same process-table approach as fresh_install.sh.
yanad_pids_under() {
	local root pattern
	for root in "$@"; do
		[[ -n "$root" ]] || continue
		pattern=$(printf '%s' "$root" | sed 's/[][\.*^$+?(){}|]/\\&/g')
		pgrep -f -- "-m yanad --root $pattern/" || true
	done
}

signal_yanad_under() {
	local sig=$1 pid=$2 root cmdline
	shift 2
	cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 0
	for root in "$@"; do
		[[ -n "$root" && "$cmdline" == *"-m yanad --root $root/"* ]] || continue
		kill "-$sig" "$pid" 2>/dev/null || true
		return 0
	done
}

wait_yanads_gone() {
	local seconds=$1 deadline
	shift
	deadline=$((SECONDS + seconds))
	while [[ -n "$(yanad_pids_under "$@")" ]]; do
		(( SECONDS < deadline )) || return 1
		sleep 0.1
	done
}

# yanad does not exit when its clients do, so never wait passively: TERM what
# the process table shows under this gate's scratch, KILL what ignores TERM,
# then rescan for a daemon that started meanwhile. Same shape as fresh_install.
stop_yanads_under() {
	local pass pid pids
	for pass in 1 2 3; do
		pids=$(yanad_pids_under "$@")
		[[ -n "$pids" ]] || return 0
		for pid in $pids; do
			signal_yanad_under TERM "$pid" "$@"
		done
		wait_yanads_gone 5 "$@" && continue
		for pid in $(yanad_pids_under "$@"); do
			printf 'confined turn: yanad pid=%s ignored TERM for 5s; sending KILL\n' "$pid" >&2
			signal_yanad_under KILL "$pid" "$@"
		done
		wait_yanads_gone 2 "$@" || {
			printf 'confined turn: yanad survived KILL pids=[%s]\n' "$(yanad_pids_under "$@" | tr '\n' ' ')" >&2
			return 1
		}
	done
	pids=$(yanad_pids_under "$@" | tr '\n' ' ')
	[[ -n "${pids// /}" ]] || return 0
	printf 'confined turn: yanad still starting under harness roots after 3 stop passes pids=[%s]\n' "${pids% }" >&2
	return 1
}

cleanup_confined_gate() {
	local exit_rc=$? shutdown_rc=0 survivors
	stop_yanads_under "$scratch" || shutdown_rc=$?
	survivors=$(yanad_pids_under "$scratch" | tr '\n' ' ')
	if (( shutdown_rc != 0 )) || [[ -n "${survivors// /}" ]]; then
		printf 'CONFINED TURN CLEANUP FAIL: yanad remains alive after gate PASS survivors=[%s] scratch=%s\n' \
			"${survivors% }" "$scratch" >&2
		# Keep scratch for diagnostics when cleanup fails.
		exit 1
	fi
	rm -rf "$scratch"
	exit "$exit_rc"
}
trap cleanup_confined_gate EXIT

run_smoke() {
	# Yanad stores session layers under $XDG_STATE_HOME/yana/…. The smoke forces
	# preview.state_root to $YANA_CONFINED_SCRATCH/state; point XDG at that same
	# tree so layer paths land under the gate scratch the smoke inspects.
	mkdir -p "$scratch/home" "$scratch/turn/state" "$scratch/config" "$scratch/data" "$scratch/cache"
	env -i \
		HOME="$scratch/home" \
		PATH="$(dirname "$nvim"):/usr/bin:/bin:/usr/sbin:/sbin" \
		YANA_CONFINED_SCRATCH="$scratch/turn" \
		XDG_CONFIG_HOME="$scratch/config" \
		XDG_DATA_HOME="$scratch/data" \
		XDG_STATE_HOME="$scratch/turn/state" \
		XDG_CACHE_HOME="$scratch/cache" \
		LC_ALL=C TZ=UTC \
		"$@" \
		"$nvim" --clean --headless -u NONE -i NONE \
		--cmd "set rtp^=$tree" -l "$tree/tests/release/confined_turn_smoke.lua"
}

# Mutation guard first: a harness that runs green while a development checkout
# is injected proves nothing about the exported tree.
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
