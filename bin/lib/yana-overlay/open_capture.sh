#!/usr/bin/env bash
# shellcheck shell=bash
# Optional open-capture launcher route for bin/yana-overlay.

write_open_capture_metrics() {
	[[ -n "$ANSWER_OUT" ]] || return 0
	mkdir -p "${ANSWER_OUT%/*}"
	python3 - "$ANSWER_OUT" "$OPEN_CAPTURE_BACKEND" <<'PY'
import json
import os
import sys
path, backend = sys.argv[1:]
tmp = path + ".tmp"
with open(tmp, "w", encoding="utf-8") as stream:
    json.dump({"backend": backend, "metrics": {"startup_ms": 0.0, "preflight_ms": 0.0}}, stream, separators=(",", ":"))
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.replace(tmp, path)
PY
}

prepare_open_capture() {
	local mode validation rc dep refusal read_only copy_up_risk
	if [[ -z "$CAPTURE_PLAN" ]]; then
		mode=${YANA_OPEN_CAPTURE_MODE:-off}
		[[ -n "$mode" && "$mode" != off ]] || return 1
		[[ -n "$SESSION_ID" && -n "$TURN_ID" ]] || refuse "open_capture_storage missing session or turn id"
		CAPTURE_PLAN=$(YANA_CAPTURE_UPPER="$UPPER" capture_plan_build "$WORKSPACE" "$STATE_ROOT" "$mode" "$SESSION_ID" "$TURN_ID") || exit $?
		OPEN_CAPTURE_BACKEND=$(capture_plan_field "$CAPTURE_PLAN" backend)
	else
		[[ -n "$OPEN_CAPTURE_BACKEND" ]] || die_usage "--capture-plan requires --backend"
	fi
	set +e
	validation=$(capture_plan_validate "$CAPTURE_PLAN" "$OPEN_CAPTURE_BACKEND" "$STATE_ROOT" "$SESSION_ID" "$TURN_ID" 2>&1)
	rc=$?
	set -e
	if (( rc != 0 )); then
		echo "yana-overlay: $validation" >&2
		exit "$rc"
	fi
	read_only=$(capture_plan_read_only_refusal "$CAPTURE_PLAN")
	[[ -z "$read_only" ]] || refuse "$read_only"
	copy_up_risk=$(capture_plan_copy_up_risk_refusal "$CAPTURE_PLAN")
	[[ -z "$copy_up_risk" ]] || refuse "$copy_up_risk"
	refusal=$(capture_plan_refusal "$CAPTURE_PLAN")
	[[ -z "$refusal" ]] || refuse "$refusal"
	if [[ "$OPEN_CAPTURE_BACKEND" == fuse-compat ]]; then
		dep=$(capture_plan_fuse_missing_dep)
		[[ -z "$dep" ]] || refuse "$dep"
	fi
	return 0
}

open_capture_userns_stop() {
	local pid=${OPEN_CAPTURE_USERNS_PID:-} fd=${OPEN_CAPTURE_USERNS_FD:-} ready=${OPEN_CAPTURE_USERNS_READY:-}
	if [[ -n "$fd" ]]; then
		eval "exec ${fd}<&-" 2>/dev/null || true
	fi
	if [[ -n "$pid" ]]; then
		kill -TERM "$pid" >/dev/null 2>&1 || true
		for _ in $(seq 1 20); do
			[[ -e "/proc/$pid" ]] || break
			sleep 0.05
		done
		[[ -e "/proc/$pid" ]] && kill -KILL "$pid" >/dev/null 2>&1 || true
		wait "$pid" >/dev/null 2>&1 || true
	fi
	[[ -n "$ready" ]] && python3 - "$ready" <<'PY' || true
import os
import sys
try:
    os.unlink(sys.argv[1])
except FileNotFoundError:
    pass
PY
	OPEN_CAPTURE_USERNS_PID=""
	OPEN_CAPTURE_USERNS_FD=""
	OPEN_CAPTURE_USERNS_READY=""
}

open_capture_userns_refuse() {
	local reason=$1
	open_capture_userns_stop
	refuse "$reason"
}

open_capture_userns_start() {
	local uid gid ready holder_pid groups mapped_groups got_groups want_groups rc
	uid=$(id -u)
	gid=$(id -g)
	ready=$(mktemp "$STATE_ROOT/yana-open-capture-userns.XXXXXX") || open_capture_userns_refuse open_capture_group_map
	: >"$ready"
	unshare --user -- bash -c 'echo ready > "$1"; exec sleep 31536000' _ "$ready" &
	holder_pid=$!
	OPEN_CAPTURE_USERNS_PID=$holder_pid
	OPEN_CAPTURE_USERNS_READY=$ready
	for _ in $(seq 1 100); do
		[[ -s "$ready" ]] && break
		[[ -e "/proc/$holder_pid" ]] || open_capture_userns_refuse open_capture_group_map
		sleep 0.02
	done
	[[ -s "$ready" ]] || open_capture_userns_refuse open_capture_group_map
	newuidmap "$holder_pid" "$uid" "$uid" 1 || open_capture_userns_refuse open_capture_dep_newuidmap
	mapfile -t groups < <(id -G | tr ' ' '\n' | awk -v gid="$gid" 'NF && $1 != 65534 {seen[$1]=1} END{seen[gid]=1; for (g in seen) print g}' | sort -n)
	mapped_groups=()
	for gid in "${groups[@]}"; do
		mapped_groups+=("$gid" "$gid" 1)
	done
	newgidmap "$holder_pid" "${mapped_groups[@]}" || open_capture_userns_refuse open_capture_dep_newgidmap
	exec {OPEN_CAPTURE_USERNS_FD}<"/proc/$holder_pid/ns/user" || open_capture_userns_refuse open_capture_group_map
	want_groups=$(id -G)
	set +e
	got_groups=$("$BWRAP" --die-with-parent --new-session --ro-bind / / --proc /proc --userns "$OPEN_CAPTURE_USERNS_FD" --uid "$uid" --gid "$(id -g)" -- sh -c 'id -G' 2>/dev/null)
	rc=$?
	set -e
	(( rc == 0 )) || open_capture_userns_refuse open_capture_group_map
	[[ "$got_groups" == "$want_groups" ]] || open_capture_userns_refuse open_capture_group_map
}

run_open_capture_fuse() {
	local real_uid real_gid state_idx state_dir state_base rc marker marker_dir
	local -A marker_dirs=()
	real_uid=$(id -u)
	real_gid=$(id -g)
	local -a inner_args=("--capture-plan" "$CAPTURE_PLAN" "--backend" "$OPEN_CAPTURE_BACKEND" "--cursor" "$CURSOR_DIR")
	for state_dir in ${STATE_DIRS[@]+"${STATE_DIRS[@]}"}; do
		inner_args+=("--state-dir" "$state_dir")
	done
	for state_dir in ${EXEC_ALLOW[@]+"${EXEC_ALLOW[@]}"}; do
		inner_args+=("--exec-allow" "$state_dir")
	done
	inner_args+=("--")
	local -a bwrap_args=(
		--die-with-parent
		--new-session
		--ro-bind / /
		--tmpfs /tmp
		--ro-bind "$WORKSPACE" "$NEUTRAL_LOWER"
		--bind "$LAYER_ROOT" "$NEUTRAL_LAYER"
		--bind "$CURSOR_DIR" "$NEUTRAL_CURSOR"
		--bind "$STATE_ROOT" "$STATE_ROOT"
		--dir "$WORKSPACE"
	)
	for marker in "${YANA_READY:-}" "${YANA_STOP:-}" "${YANA_CLOSED:-}"; do
		[[ -n "$marker" ]] || continue
		marker_dir=${marker%/*}
		[[ -n "$marker_dir" && -d "$marker_dir" ]] || continue
		[[ -z "${marker_dirs[$marker_dir]+set}" ]] || continue
		marker_dirs[$marker_dir]=1
		bwrap_args+=(--bind "$marker_dir" "$marker_dir")
	done
	state_idx=0
	for state_dir in ${STATE_DIRS[@]+"${STATE_DIRS[@]}"}; do
		state_idx=$(( state_idx + 1 ))
		if [[ ! -e "$state_dir" ]]; then
			state_base=${state_dir##*/}
			if [[ "${state_base#.}" == *.* ]]; then
				mkdir -p "${state_dir%/*}" 2>/dev/null || true
				: >"$state_dir" 2>/dev/null || true
			else
				mkdir -p "$state_dir" 2>/dev/null || true
			fi
		fi
		[[ -e "$state_dir" ]] && bwrap_args+=(--bind "$state_dir" "$NEUTRAL_STATE/$state_idx")
	done
	open_capture_userns_start
	bwrap_args+=(
		--dev /dev
		--dev-bind /dev/fuse /dev/fuse
		--proc /proc
		--unshare-uts
		--userns "$OPEN_CAPTURE_USERNS_FD"
		--uid "$real_uid"
		--gid "$real_gid"
		--cap-add CAP_SYS_ADMIN
		--cap-add CAP_DAC_OVERRIDE
		--cap-add CAP_SETPCAP
		--
		"$INNER"
	)
	set +e
	OPEN_CAPTURE_FUSE_CANCELLED=0
	"$BWRAP" "${bwrap_args[@]}" "${inner_args[@]}" "${CMD[@]}" &
	OPEN_CAPTURE_FUSE_CHILD=$!
	trap 'OPEN_CAPTURE_FUSE_CANCELLED=1; kill -TERM "$OPEN_CAPTURE_FUSE_CHILD" >/dev/null 2>&1 || true; fuse_outer_cancel_cleanup; open_capture_userns_stop' TERM INT HUP
	wait "$OPEN_CAPTURE_FUSE_CHILD"
	rc=$?
	if (( OPEN_CAPTURE_FUSE_CANCELLED )); then
		wait "$OPEN_CAPTURE_FUSE_CHILD" >/dev/null 2>&1 || true
		rc=143
	fi
	trap - TERM INT HUP
	open_capture_userns_stop
	set -e
	return "$rc"
}

cmd_run_direct_open_capture() {
	[[ -n "$WORKSPACE" && -n "$UPPER" && -n "$WORK" ]] \
		|| die_usage "--workspace, --upper and --work are required"
	(( ${#CMD[@]} > 0 )) || die_usage "missing command after --"
	local gi rc
	for (( gi = 0; gi < ${#EXTRA_ROOTS[@]}; gi++ )); do
		[[ -n "${EXTRA_UPPERS[$gi]}" && -n "${EXTRA_WORKS[$gi]}" ]] \
			|| die_usage "--extra-root '${EXTRA_ROOTS[$gi]}' needs its own --extra-upper and --extra-work"
	done
	ensure_bwrap
	OPERATOR_HOME=$(operator_home)
	validate_paths
	resolve_cursor_dir
	if ! prepare_open_capture; then
		cmd_run_direct
		return
	fi
	if [[ "$OPEN_CAPTURE_BACKEND" == fuse-compat ]]; then
		run_open_capture_fuse
		exit $?
	fi
	if run_overlay; then
		write_open_capture_metrics
		rc=0
	else
		rc=$?
	fi
	if (( rc != 0 )); then
		if (( rc == EXIT_MOUNT )) && ! mount_succeeded; then
			refuse_mount "cannot establish overlay at '$WORKSPACE'"
		fi
		exit "$rc"
	fi
	exit 0
}
