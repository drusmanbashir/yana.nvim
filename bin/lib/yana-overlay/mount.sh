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
