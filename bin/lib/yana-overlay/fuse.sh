#!/usr/bin/env bash
# shellcheck shell=bash
# FUSE open-capture helper lifecycle for bin/yana-overlay-inner.

fuse_status_dir() {
	printf '%s/fuse\n' "$(dirname "$CAPTURE_PLAN")"
}

fuse_proc_fields() {
	python3 - "$1" <<'PY'
import sys
pid = sys.argv[1]
try:
    stat = open(f"/proc/{pid}/stat", encoding="utf-8").read()
    tail = stat.rsplit(")", 1)[1].split()
    print(f"{tail[2]} {tail[19]}")
except Exception:
    print("0 0")
PY
}

fuse_write_status() {
	local status=$1 final_status=$2 pid=$3 pgrp=$4 ticks=$5 mount_point=$6 startup_ms=$7 preflight_ms=$8
	local dir stdout stderr
	dir=$(fuse_status_dir)
	mkdir -p "$dir"
	stdout="$dir/stdout.log"
	stderr="$dir/stderr.log"
	[[ -e "$stdout" ]] || : >"$stdout"
	[[ -e "$stderr" ]] || : >"$stderr"
	python3 - "$dir/status.json" "$status" "$final_status" "$pid" "$pgrp" "$ticks" "$mount_point" "$stdout" "$stderr" "$startup_ms" "$preflight_ms" <<'PY'
import json
import os
import sys
path, status, final_status, pid, pgrp, ticks, mount_point, stdout, stderr, startup, preflight = sys.argv[1:]
tmp = path + ".tmp"
payload = {
    "pid": int(pid),
    "process_group": int(pgrp),
    "start_ticks": int(ticks),
    "mount_point": mount_point,
    "stdout": stdout,
    "stderr": stderr,
    "status": status,
    "final_status": final_status,
    "metrics": {"startup_ms": float(startup), "preflight_ms": float(preflight)},
}
with open(tmp, "w", encoding="utf-8") as stream:
    json.dump(payload, stream, separators=(",", ":"))
    stream.write("\n")
    stream.flush()
    os.fsync(stream.fileno())
os.replace(tmp, path)
try:
    fd = os.open(os.path.dirname(path), os.O_RDONLY)
    os.fsync(fd)
    os.close(fd)
except OSError:
    pass
PY
}

fuse_mount_present() {
	local pid=$1 mount_point=$2
	python3 - "$pid" "$mount_point" <<'PY'
import sys
pid, mount_point = sys.argv[1:]
try:
    rows = open(f"/proc/{pid}/mountinfo", encoding="utf-8", errors="ignore")
except OSError:
    raise SystemExit(1)
for line in rows:
    fields = line.rstrip("\n").split()
    if "-" not in fields:
        continue
    sep = fields.index("-")
    if fields[4].replace("\\040", " ") == mount_point and "fuse" in fields[sep + 1]:
        raise SystemExit(0)
raise SystemExit(1)
PY
}

fuse_stop_helper() {
	local pid=${FUSE_HELPER_PID:-} pgrp=${FUSE_HELPER_PGRP:-} mount_point=${FUSE_MOUNT_POINT:-}
	[[ -n "$mount_point" ]] && fusermount3 -u "$mount_point" >/dev/null 2>&1 || umount "$mount_point" >/dev/null 2>&1 || true
	[[ -n "$pid" && "$pid" != "$$" ]] || return 0
	if [[ -n "$pgrp" && "$pgrp" != 0 ]]; then
		kill -TERM "-$pgrp" >/dev/null 2>&1 || true
		for _ in $(seq 1 50); do
			[[ -e "/proc/$pid" ]] || break
			sleep 0.1
		done
		[[ -e "/proc/$pid" ]] && kill -KILL "-$pgrp" >/dev/null 2>&1 || true
	fi
	wait "$pid" >/dev/null 2>&1 || true
}

fuse_status_json() {
	printf '%s/status.json\n' "$(fuse_status_dir)"
}

fuse_outer_cancel_cleanup() {
	local status_path pid pgrp ticks mount_point startup_ms preflight_ms
	status_path=$(fuse_status_json)
	[[ -f "$status_path" ]] || return 0
	read -r pid pgrp ticks mount_point startup_ms preflight_ms < <(python3 - "$status_path" <<'INNERPY'
import json
import sys
try:
    data = json.load(open(sys.argv[1], encoding="utf-8"))
except Exception:
    raise SystemExit(1)
if str(data.get("status")) not in ("running", "mounted") or str(data.get("final_status", "")):
    raise SystemExit(1)
metrics = data.get("metrics") if isinstance(data.get("metrics"), dict) else {}
print(
    int(data.get("pid", 0)),
    int(data.get("process_group", 0)),
    int(data.get("start_ticks", 0)),
    str(data.get("mount_point", "")),
    float(metrics.get("startup_ms", 0.0)),
    float(metrics.get("preflight_ms", 0.0)),
)
INNERPY
	) || return 0
	[[ -n "$pid" && "$pid" != 0 ]] || return 0
	if [[ -n "$pgrp" && "$pgrp" != 0 ]]; then
		kill -TERM "-$pgrp" >/dev/null 2>&1 || true
		for _ in $(seq 1 20); do
			[[ -e "/proc/$pid" ]] || break
			sleep 0.05
		done
		[[ -e "/proc/$pid" ]] && kill -KILL "-$pgrp" >/dev/null 2>&1 || true
	fi
	FUSE_HELPER_PID=$pid
	FUSE_HELPER_PGRP=$pgrp
	FUSE_HELPER_TICKS=$ticks
	FUSE_MOUNT_POINT=$mount_point
	FUSE_STARTUP_MS=$startup_ms
	FUSE_PREFLIGHT_MS=$preflight_ms
	fuse_write_status closed cancelled "$pid" "$pgrp" "$ticks" "$mount_point" "$startup_ms" "$preflight_ms"
}

fuse_terminal_status() {
	case "${FUSE_TERMINAL_STATUS:-}" in
		ok|cancelled|crashed|setup_failed) printf '%s\n' "$FUSE_TERMINAL_STATUS" ;;
		*) printf 'crashed\n' ;;
	esac
}

fuse_finish_once() {
	local status
	[[ ${FUSE_FINISHED:-0} == 0 ]] || return 0
	FUSE_FINISHED=1
	status=$(fuse_terminal_status)
	trap - EXIT TERM INT HUP
	if [[ -n "${CAPTURE_PLAN:-}" ]]; then
		mount_teardown_reconstructed "$CAPTURE_PLAN" || true
	fi
	fuse_stop_helper
	[[ -n "${FUSE_HELPER_PID:-}" ]] || return 0
	fuse_write_status closed "$status" "$FUSE_HELPER_PID" "$FUSE_HELPER_PGRP" "$FUSE_HELPER_TICKS" "$FUSE_MOUNT_POINT" "${FUSE_STARTUP_MS:-0}" "${FUSE_PREFLIGHT_MS:-0}"
}

fuse_signal_exit() {
	FUSE_TERMINAL_STATUS=cancelled
	fuse_finish_once
	exit 143
}

fuse_run() {
	local mount_point lower layer start_ns now_ns rc setup_pid dir stdout stderr payload_pid uid_map gid_map gid seen_gids
	mount_point=$(capture_plan_field "$CAPTURE_PLAN" project_cwd)
	lower=$NEUTRAL_LOWER
	layer=$NEUTRAL_LAYER
	dir=$(fuse_status_dir)
	mkdir -p "$dir"
	stdout="$dir/stdout.log"
	stderr="$dir/stderr.log"
	: >"$stdout"
	: >"$stderr"
	start_ns=$(date +%s%N)
	FUSE_MOUNT_POINT=$mount_point
	FUSE_STARTUP_MS=0
	FUSE_PREFLIGHT_MS=0
	FUSE_TERMINAL_STATUS=crashed
	FUSE_FINISHED=0
	trap fuse_finish_once EXIT
	trap fuse_signal_exit TERM INT HUP
	if [[ ${YANA_OPEN_CAPTURE_FORCE_SETUP_FAILURE:-0} == 1 ]]; then
		setup_pid=$$
		read -r FUSE_HELPER_PGRP FUSE_HELPER_TICKS < <(fuse_proc_fields "$setup_pid")
		FUSE_HELPER_PID=$setup_pid
		FUSE_TERMINAL_STATUS=setup_failed
		fuse_write_status failed setup_failed "$setup_pid" "$FUSE_HELPER_PGRP" "$FUSE_HELPER_TICKS" "$mount_point" 0 0
		echo "open_capture_backend_unavailable forced setup failure" >&2
		fuse_finish_once
		return 65
	fi
	mkdir -p "$layer/upper" "$layer/work"
	uid_map="0:0:1:$(id -u):$(id -u):1"
	gid_map="0:0:1"
	seen_gids=" 0 "
	for gid in $(id -G) $(id -g); do
		[[ " $seen_gids " == *" $gid "* ]] && continue
		seen_gids+="$gid "
		gid_map+=":$gid:$gid:1"
	done
	setsid fuse-overlayfs -f -o "lowerdir=$lower,upperdir=$layer/upper,workdir=$layer/work,uidmapping=$uid_map,gidmapping=$gid_map" "$mount_point" >"$stdout" 2>"$stderr" &
	FUSE_HELPER_PID=$!
	for _ in $(seq 1 100); do
		if fuse_mount_present "$FUSE_HELPER_PID" "$mount_point"; then
			break
		fi
		[[ -e "/proc/$FUSE_HELPER_PID" ]] || break
		sleep 0.05
	done
	read -r FUSE_HELPER_PGRP FUSE_HELPER_TICKS < <(fuse_proc_fields "$FUSE_HELPER_PID")
	if ! fuse_mount_present "$FUSE_HELPER_PID" "$mount_point"; then
		FUSE_TERMINAL_STATUS=setup_failed
		fuse_write_status failed setup_failed "$FUSE_HELPER_PID" "$FUSE_HELPER_PGRP" "$FUSE_HELPER_TICKS" "$mount_point" 0 0
		echo "open_capture_backend_unavailable fuse-overlayfs setup failed" >&2
		fuse_finish_once
		return 65
	fi
	now_ns=$(date +%s%N)
	FUSE_STARTUP_MS=$(awk -v a="$start_ns" -v b="$now_ns" 'BEGIN{printf "%.3f", (b-a)/1000000}')
	FUSE_PREFLIGHT_MS=0.000
	if ! mount_reconstruct_capture_plan "$CAPTURE_PLAN"; then
		FUSE_TERMINAL_STATUS=setup_failed
		fuse_write_status failed setup_failed "$FUSE_HELPER_PID" "$FUSE_HELPER_PGRP" "$FUSE_HELPER_TICKS" "$mount_point" "$FUSE_STARTUP_MS" "$FUSE_PREFLIGHT_MS"
		echo "open_capture_backend_unavailable alias reconstruction failed" >&2
		fuse_finish_once
		return 65
	fi
	fuse_write_status running "" "$FUSE_HELPER_PID" "$FUSE_HELPER_PGRP" "$FUSE_HELPER_TICKS" "$mount_point" "$FUSE_STARTUP_MS" "$FUSE_PREFLIGHT_MS"
	"$@" &
	payload_pid=$!
	if wait "$payload_pid"; then
		rc=0
		if ! mount_decode_alias_proposals "$CAPTURE_PLAN" "$layer"; then
			rc=65
			FUSE_TERMINAL_STATUS=crashed
		else
			FUSE_TERMINAL_STATUS=ok
		fi
	else
		rc=$?
		FUSE_TERMINAL_STATUS=crashed
	fi
	fuse_finish_once
	return "$rc"
}
