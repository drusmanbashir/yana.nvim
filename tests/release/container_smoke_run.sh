#!/usr/bin/env bash
# Runs inside the release-container image.
# Modes:
#   positive              — smoke.lua (require yana, :Yana, panel)
#   negative              — empty packpath; require("yana") must fail
#   turns-agentic|inline|ask — two real submits for that mode (SIX-TURNS PASS)
#   turns-cross-mode-reuse — red control: share one state root across modes (must FAIL)
set -euo pipefail

mode=${1:-positive}
export_tree=/opt/yana-export
ui_root=/opt/yana-ui
scratch_base=/var/yana/scratch
rm -rf "$scratch_base"/*
mkdir -p "$scratch_base"

run_nvim() {
	local scratch=$1
	shift
	env -i \
		HOME="$scratch/home" \
		PATH="/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" \
		XDG_CONFIG_HOME="$scratch/config" \
		XDG_DATA_HOME="$scratch/data" \
		XDG_STATE_HOME="$scratch/state-xdg" \
		XDG_CACHE_HOME="$scratch/cache" \
		PYTHONPATH="$scratch/data/nvim/site/pack/release/start/yana.nvim/bin/lib" \
		LC_ALL=C TZ=UTC \
		${YANA_SIX_TURNS_MODE:+YANA_SIX_TURNS_MODE="$YANA_SIX_TURNS_MODE"} \
		${YANA_SIX_TURNS_SCRATCH:+YANA_SIX_TURNS_SCRATCH="$YANA_SIX_TURNS_SCRATCH"} \
		nvim --headless -u NONE -i NONE \
		--cmd "set packpath^=$scratch/data/nvim/site" \
		--cmd "set rtp^=$ui_root" \
		--cmd 'packloadall' \
		"$@"
}

install_plugin() {
	local scratch=$1
	local plugin=$scratch/data/nvim/site/pack/release/start/yana.nvim
	mkdir -p "$scratch/home" "$scratch/config/nvim" "$plugin" \
		"$scratch/state-xdg" "$scratch/cache"
	cp -a "$export_tree/." "$plugin/"
	chmod 755 "$plugin/tests/release/six_turns_agent" 2>/dev/null || true
	printf '%s\n' "$plugin"
}

# yanad does not exit when nvim does (same as confined_turn_gate / fresh_install).
yanad_pids_under() {
	local root pattern
	for root in "$@"; do
		[[ -n $root ]] || continue
		pattern=$(printf '%s' "$root" | sed 's/[][\.*^$+?(){}|]/\\&/g')
		pgrep -f -- "-m yanad --root $pattern/" || true
	done
}

signal_yanad_under() {
	local sig=$1 pid=$2 root cmdline
	shift 2
	cmdline=$(tr '\0' ' ' <"/proc/$pid/cmdline" 2>/dev/null) || return 0
	for root in "$@"; do
		[[ -n $root && $cmdline == *"-m yanad --root $root/"* ]] || continue
		kill "-$sig" "$pid" 2>/dev/null || true
		return 0
	done
}

wait_yanads_gone() {
	local seconds=$1 deadline
	shift
	deadline=$((SECONDS + seconds))
	while [[ -n $(yanad_pids_under "$@") ]]; do
		((SECONDS < deadline)) || return 1
		sleep 0.1
	done
}

stop_yanads_under() {
	local pass pid pids
	for pass in 1 2 3; do
		pids=$(yanad_pids_under "$@")
		[[ -n $pids ]] || return 0
		for pid in $pids; do
			signal_yanad_under TERM "$pid" "$@"
		done
		wait_yanads_gone 5 "$@" && continue
		for pid in $(yanad_pids_under "$@"); do
			printf 'container smoke: yanad pid=%s ignored TERM; sending KILL\n' "$pid" >&2
			signal_yanad_under KILL "$pid" "$@"
		done
		wait_yanads_gone 2 "$@" || return 1
	done
	pids=$(yanad_pids_under "$@" | tr '\n' ' ')
	[[ -z ${pids// /} ]] || return 1
	return 0
}

assert_no_yanad() {
	local root=$1
	local survivors shutdown_rc=0
	stop_yanads_under "$root" || shutdown_rc=$?
	survivors=$(yanad_pids_under "$root" | tr '\n' ' ')
	if ((shutdown_rc != 0)) || [[ -n ${survivors// /} ]]; then
		echo "CONTAINER SMOKE FAIL: yanad survivors under $root: ${survivors% }" >&2
		exit 1
	fi
	echo "PASS: zero yanad survivors under $root"
}

case "$mode" in
positive)
	scratch=$scratch_base/positive
	mkdir -p "$scratch"
	plugin=$(install_plugin "$scratch")
	unset YANA_SIX_TURNS_MODE YANA_SIX_TURNS_SCRATCH || true
	run_nvim "$scratch" -l "$plugin/tests/release/smoke.lua"
	echo "CONTAINER SMOKE POSITIVE PASS nvim=$(nvim --version | head -1) plugin=$plugin"
	;;
negative)
	scratch=$scratch_base/negative
	mkdir -p "$scratch/home" "$scratch/config/nvim" \
		"$scratch/data/nvim/site/pack/release/start" \
		"$scratch/state-xdg" "$scratch/cache"
	unset YANA_SIX_TURNS_MODE YANA_SIX_TURNS_SCRATCH || true
	set +e
	out=$(run_nvim "$scratch" -c 'lua local ok=pcall(require,"yana"); if ok then os.exit(11) else os.exit(0) end' -c qa 2>&1)
	rc=$?
	set -e
	if [[ $rc == 0 ]]; then
		echo "CONTAINER SMOKE NEGATIVE PASS: require('yana') refused on empty packpath"
		exit 0
	fi
	echo "CONTAINER SMOKE NEGATIVE FAIL: require('yana') succeeded without the export (rc=$rc)" >&2
	printf '%s\n' "$out" >&2
	exit 1
	;;
turns-agentic | turns-inline | turns-ask)
	turn_mode=${mode#turns-}
	scratch=$scratch_base/turns-$turn_mode
	mkdir -p "$scratch/hl"
	plugin=$(install_plugin "$scratch")
	export YANA_SIX_TURNS_MODE=$turn_mode
	export YANA_SIX_TURNS_SCRATCH=$scratch/hl
	set +e
	out=$(run_nvim "$scratch" -l "$plugin/tests/release/container_six_turns.lua" 2>&1)
	rc=$?
	set -e
	printf '%s\n' "$out"
	assert_no_yanad "$scratch/hl"
	[[ $rc == 0 ]] || exit "$rc"
	grep -qF "SIX-TURNS PASS mode=$turn_mode" <<<"$out" || {
		echo "CONTAINER SMOKE FAIL: missing SIX-TURNS PASS for $turn_mode" >&2
		exit 1
	}
	# Persist state-root marker for the host cross-mode check when logs are mounted…
	# (host compares docker logs / optional marker files via docker cp if needed)
	if [[ -f $scratch/hl/state_root.txt ]]; then
		echo "STATE_ROOT mode=$turn_mode $(cat "$scratch/hl/state_root.txt")"
	fi
	;;
turns-cross-mode-reuse)
	scratch=$scratch_base/cross
	mkdir -p "$scratch"
	plugin=$(install_plugin "$scratch")
	shared=$scratch/shared-hl
	mkdir -p "$shared"
	export YANA_SIX_TURNS_MODE=ask
	export YANA_SIX_TURNS_SCRATCH=$shared
	set +e
	run_nvim "$scratch" -l "$plugin/tests/release/container_six_turns.lua" >/tmp/ask.out 2>&1
	ask_rc=$?
	set -e
	export YANA_SIX_TURNS_MODE=agentic
	set +e
	run_nvim "$scratch" -l "$plugin/tests/release/container_six_turns.lua" >/tmp/agentic.out 2>&1
	agentic_rc=$?
	set -e
	assert_no_yanad "$shared"
	disk=$(cat "$shared/ws/notes.txt" 2>/dev/null || true)
	echo "cross-mode ask_rc=$ask_rc agentic_rc=$agentic_rc disk=<<$disk>>"
	# Shared scratch means agentic edits the same notes.txt ask left seeded —
	# that contamination must be visible so the host treats this mode as red.
	if [[ $disk == *six-turn-* ]]; then
		echo "TURNS CROSS-MODE REUSE DETECTED"
	fi
	echo "TURNS CROSS-MODE REUSE FAIL"
	exit 1
	;;
*)
	echo "container_smoke_run: unknown mode: $mode" >&2
	exit 64
	;;
esac
