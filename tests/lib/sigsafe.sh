# Canonical, validated process signalling for Yana shell tests.
#
# Shared shell signalling primitive. Target validation and the bash builtin
# avoid the unsafe argument interpretation of an unchecked external kill:
#
#   1. The target is validated as a positive PID above 1 before any signal is
#      sent, so a computed negative value, an arithmetic negation, an empty
#      variable, or a process-group spelling is refused rather than delivered.
#      This is the runtime half of the invariant the static scan cannot prove.
#   2. The signal goes through the bash `kill` BUILTIN. No external
#      implementation ever parses the operand, so procps-ng's reading of a
#      negative operand as PID -1 -- the bug that killed the operator's session
#      twice on 2026-08-17 -- cannot recur even if validation were wrong.
#
# A test that genuinely needs to signal a whole process group must run wholly
# inside a dedicated PID namespace, and must say so in its own header. There is
# no wrapper for it here, because a wrapper would make it easy.
#
# Usage:
#   . "$ROOT/tests/lib/sigsafe.sh"
#   sigsafe_alive "$pid"            # rc 0 when the process exists
#   sigsafe_kill9 "$pid"            # SIGKILL
#   sigsafe_signal 15 "$pid"        # any signal number
#
# Every function returns rc 2 on a refused target, which is deliberately
# distinct from "signal delivered" (0) and "no such process" (1), so a caller
# testing liveness cannot mistake a refusal for a dead process.

sigsafe_signal() {
	local sig="$1" pid="$2"
	if [[ ! "$sig" =~ ^([0-9]|[1-5][0-9]|6[0-4])$ ]]; then
		printf 'sigsafe: refusing signal %q: not a signal number 0-64\n' "$sig" >&2
		return 2
	fi
	if [[ ! "$pid" =~ ^[0-9]+$ ]]; then
		printf 'sigsafe: refusing target %q: not a positive integer PID\n' "$pid" >&2
		return 2
	fi
	if ((pid <= 1)); then
		printf 'sigsafe: refusing target %q: PID must be greater than 1\n' "$pid" >&2
		return 2
	fi
	builtin kill "-${sig}" "$pid" 2>/dev/null
}

sigsafe_alive() {
	sigsafe_signal 0 "$1"
}

sigsafe_kill9() {
	sigsafe_signal 9 "$1"
}

# ---------------------------------------------------------------------------
# REAPING: a signal that is only SIGTERM is not a kill.
#
# Measured 2026-08-21: a suite row wrapped in `timeout 300` outlived it by
# 2 h 54 min because `timeout` sends SIGTERM and then waits forever if the
# child ignores it. `timeout -k` fixed that class for the LAUNCHERS. The same
# defect lives in every hand-written teardown that says "kill $pid" (SIGTERM)
# and then either walks away or blocks in `wait`: if the target ignores TERM --
# which is exactly what the wedged Neovim did -- the process survives holding
# its claim, or the harness hangs on the wait and the leak is silent.
#
# sigsafe_reap is the teardown-side spelling of `timeout -k`: TERM, poll for
# the process to actually go, then KILL, then VERIFY. It never blocks
# unbounded, and it reports whether the process is really gone.
#
#   sigsafe_reap "$pid" [grace_seconds]   rc 0 gone, 1 still alive, 2 refused
#
# Tracking exists for the other half of the same hazard: a background child
# started with `&` whose PID is only signalled on the happy path, so an early
# `exit` -- a failed assertion, or the harness's own SIGTERM -- leaves it
# running. Register the PID once, reap them all from the EXIT trap:
#
#   sigsafe_track "$pid"
#   trap 'sigsafe_reap_tracked; rm -rf "$GATE"' EXIT
#
# A bash EXIT trap does run when the shell is TERMed, so EXIT is enough here
# and is deliberately not widened to `trap ... TERM`: trapping TERM without
# re-raising it would make the harness itself the thing that ignores SIGTERM.
SIGSAFE_TRACKED=()

sigsafe_track() {
	local pid="$1"
	if [[ ! "$pid" =~ ^[0-9]+$ ]] || ((pid <= 1)); then
		printf 'sigsafe: refusing to track %q: not a positive integer PID above 1\n' "$pid" >&2
		return 2
	fi
	SIGSAFE_TRACKED+=("$pid")
}

# sigsafe_children PID -- direct children of PID, one PID per line, read from
# the process table (`ps -eo pid=,ppid=`), never a kill(1) call. Used only to
# find MORE targets to validate-and-signal individually; it does not itself
# signal anything, so it carries none of the process-group hazard above.
sigsafe_children() {
	local ppid="$1"
	[[ "$ppid" =~ ^[0-9]+$ ]] || return 2
	ps -eo pid=,ppid= 2>/dev/null | awk -v p="$ppid" '$2==p{print $1}'
}

# nvim/BUGS.md N1: the reason a fast kill of Neovim orphaned its language
# server is that sigsafe_reap only ever signalled the ONE tracked PID.
# vim.lsp.start gives the server its own process group AND session
# (setsid()), so it is unreachable by process-group addressing in the first
# place -- and this file deliberately never spells `kill -- -$pgid` or a bare
# negative PID (see header: that reading is what killed the operator's
# session twice on 2026-08-17). The fix below stays inside that rule: before
# signalling the tracked PID, snapshot its DIRECT children by validated PID
# (never by group/session), then reap each one the same validated way.
#
# What this covers: a direct child in its own pgid/sid -- exactly the
# measured LSP case (nvim pgid=168657 sid=168650, node pgid=169512
# sid=169512) -- because each child is reaped by its own real PID, not by
# addressing its group or session.
# What this does NOT cover: a grandchild (only one level of ppid is walked,
# matching what was actually measured -- nvim -> lsp direct child, never
# nvim -> wrapper -> lsp); and a child that has ALREADY reparented to init
# before this function runs (the snapshot depends on the ppid link, which the
# kernel rewrites the moment the original parent is gone -- so this cannot
# retroactively recover a leak that happened before the reap call, only
# prevent a new one at this call site).
sigsafe_reap() {
	local pid="$1" grace="${2:-3}" waited=0 limit rc=0 child
	local -a children=()
	sigsafe_alive "$pid"
	case $? in
	2) return 2 ;;
	1) return 0 ;;
	esac
	while IFS= read -r child; do
		[[ -n "$child" ]] && children+=("$child")
	done < <(sigsafe_children "$pid")

	limit=$(awk -v g="$grace" 'BEGIN { printf "%d", g * 10 }')
	sigsafe_signal 15 "$pid"
	while ((waited < limit)); do
		sigsafe_alive "$pid" || break
		sleep 0.1
		waited=$((waited + 1))
	done
	if sigsafe_alive "$pid"; then
		sigsafe_kill9 "$pid"
		waited=0
		while ((waited < 50)); do
			sigsafe_alive "$pid" || break
			sleep 0.1
			waited=$((waited + 1))
		done
	fi
	if sigsafe_alive "$pid"; then
		printf 'sigsafe: pid %s survived SIGTERM and SIGKILL\n' "$pid" >&2
		rc=1
	fi

	for child in ${children[@]+"${children[@]}"}; do
		sigsafe_reap "$child" "$grace" || rc=1
	done
	return "$rc"
}

sigsafe_reap_tracked() {
	local pid rc=0
	for pid in ${SIGSAFE_TRACKED[@]+"${SIGSAFE_TRACKED[@]}"}; do
		sigsafe_reap "$pid" "${1:-3}" || rc=1
	done
	SIGSAFE_TRACKED=()
	return "$rc"
}
