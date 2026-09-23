#!/usr/bin/env bash
# shellcheck shell=bash
# Mount-phase functions for bin/yana-overlay-inner.
# Sourced by bin/yana-overlay-inner only, from inside the bwrap jail. No shebang exec; do not run directly.
# Must not call `set` or install traps: it shares the parent's set -eu.

# mount_overlays — one overlay per entry of ROOTS.
mount_overlays() {
	local idx=0 root lower layer
	for root in "${ROOTS[@]}"; do
		idx=$(( idx + 1 ))
		if (( idx == 1 )); then
			lower=$NEUTRAL_LOWER
			layer=$NEUTRAL_LAYER
		else
			lower="/tmp/yana/r$idx/lower"
			layer="/tmp/yana/r$idx/layer"
		fi
		mount -t overlay yana-ovl \
			-o "lowerdir=${lower},upperdir=${layer}/upper,workdir=${layer}/work${VOLATILE_OPT}" \
			"$root" || exit "$EXIT_MOUNT"
		LAYERS+=("$layer")
	done
}

#
mount_cursor_exception() {
	if [[ -n "$CURSOR_DIR" ]]; then
		# The self-bind fallback is for tests/overlay_gate.sh and
		# tests/overlay_broadroot_gate.sh, which drive this helper directly with their own
		# bwrap argv and make no staging bind.
		local cursor_src=$CURSOR_DIR
		[[ -e "$NEUTRAL_CURSOR" ]] && cursor_src=$NEUTRAL_CURSOR
		mount --bind "$cursor_src" "$CURSOR_DIR" || exit "$EXIT_MOUNT"
		# ...AND MAKE IT WRITABLE.
		mount -o bind,remount,rw "$CURSOR_DIR" || exit "$EXIT_MOUNT"
	fi
}

# The vendor CLIs write these at startup; under the outer `--ro-bind / /` they died
# "Read-only file system (os error 30)" and the turn never began.
#
# Mounted HERE, after mount_overlays, for the reason mount_cursor_exception
# already documents: a bind stacked before the overlay at a path under the
# broad root is invisible the instant the overlay covers it.
#
# The SOURCE is the staging bind yana-overlay made at /tmp/yana/state/<i>,
# never "$dir" itself. /tmp is bwrap's own tmpfs and can never be under a
# mounted root, so the staging path still names the REAL host directory,
# where this state belongs -- binding "$dir" onto itself would instead
# capture the overlay's merged view and send the vendor's state into the
# turn's disposable upper layer, to be thrown away at release.
mount_state_dirs() {
	local idx=0 dir
	for dir in ${STATE_DIRS[@]+"${STATE_DIRS[@]}"}; do
		idx=$(( idx + 1 ))
		[[ -e "$NEUTRAL_STATE/$idx" ]] || continue
		# The mountpoint must exist in the mounted-over view, and must be
		# the same KIND as the staged source -- a file cannot be bound onto
		# a directory. yana-overlay created it on the host before entering
		# the namespace, so it is normally already there through the
		# overlay's lower or the ro-bind; this is only for a root whose
		# upper hides it.
		if [[ ! -e "$dir" ]]; then
			if [[ -d "$NEUTRAL_STATE/$idx" ]]; then
				mkdir -p "$dir" || exit "$EXIT_MOUNT"
			else
				mkdir -p "${dir%/*}" || exit "$EXIT_MOUNT"
				: >"$dir" || exit "$EXIT_MOUNT"
			fi
		fi
		mount --bind "$NEUTRAL_STATE/$idx" "$dir" || exit "$EXIT_MOUNT"
		# ...AND MAKE IT WRITABLE, for mount_cursor_exception's reason: a
		# plain bind inherits MS_RDONLY from the `--ro-bind / /` this mount
		# namespace was copied from, so without the remount the exception is
		# an exception in name only and the vendor still dies EROFS.
		mount -o bind,remount,rw "$dir" || exit "$EXIT_MOUNT"
	done
}

mount_reconstruct_capture_plan() {
	local plan=$1 alias source
	RECONSTRUCTED_CAPTURE_MOUNTS=()
	while IFS=$'\t' read -r alias source; do
		[[ -n "$alias" && -n "$source" ]] || continue
		mount --bind "$alias" "$source" || return 1
		mount -o bind,remount,rw "$source" || return 1
		RECONSTRUCTED_CAPTURE_MOUNTS+=("$source")
	done < <(python3 - "$plan" <<'PY'
import json
import sys
with open(sys.argv[1], encoding="utf-8") as stream:
    data = json.load(stream)
project = data.get("project_cwd", "")
rows = []
for row in data.get("aliases", []):
    alias = row.get("alias_prefix", "")
    source = row.get("source_prefix", "")
    if alias and source and alias == project:
        rows.append((alias.count("/"), alias, source))
for _, alias, source in sorted(rows, reverse=True):
    print(f"{alias}\t{source}")
PY
	)
}


mount_decode_alias_proposals() {
	local plan=$1 layer=$2
	python3 - "$plan" "$layer" <<'PY'
import json
import os
import shutil
import sys
plan, layer = sys.argv[1:]
upper = os.path.join(layer, "upper")
if not os.path.isdir(upper):
    raise SystemExit(0)
with open(plan, encoding="utf-8") as stream:
    data = json.load(stream)
project = data.get("project_cwd", "")
for row in data.get("aliases", []):
    alias = row.get("alias_prefix")
    source = row.get("source_prefix")
    decoded_file = row.get("reconstructed_private_abs", "")
    if not alias or not source or alias != project or not decoded_file:
        continue
    host_upper = ""
    targets = data.get("targets", [])
    if targets and isinstance(targets[0], dict):
        host_upper = targets[0].get("private_proposal_abs", "")
    if host_upper and decoded_file == host_upper or (host_upper and decoded_file.startswith(host_upper.rstrip(os.sep) + os.sep)):
        rel_decoded = os.path.relpath(decoded_file, host_upper)
        decoded_file = os.path.join(upper, rel_decoded)
    decoded_root = os.path.dirname(decoded_file)
    os.makedirs(decoded_root, exist_ok=True)
    for name in sorted(os.listdir(upper)):
        if name == ".yana-decoded":
            continue
        src = os.path.join(upper, name)
        dst = os.path.join(decoded_root, name)
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        if os.path.exists(dst):
            if os.path.isdir(dst) and not os.path.islink(dst):
                shutil.rmtree(dst)
            else:
                os.unlink(dst)
        os.replace(src, dst)
PY
}

mount_teardown_reconstructed() {
	local idx path count
	count=0
	if declare -p RECONSTRUCTED_CAPTURE_MOUNTS >/dev/null 2>&1; then
		count=${#RECONSTRUCTED_CAPTURE_MOUNTS[@]}
	fi
	for (( idx=count-1; idx>=0; idx-- )); do
		path=${RECONSTRUCTED_CAPTURE_MOUNTS[$idx]}
		[[ -n "$path" ]] || continue
		umount "$path" >/dev/null 2>&1 || true
	done
	RECONSTRUCTED_CAPTURE_MOUNTS=()
}
