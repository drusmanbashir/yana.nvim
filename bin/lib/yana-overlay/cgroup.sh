# yanad launcher cgroup ownership.

# Overridable only for tests (tests/yana_cgroup_root_slash_gate.sh): stubs the
# /proc/self/cgroup input without root or a real cgroup2 mount. Production
# code never sets this, so it always reads the real file.
CGROUP_PROC_SELF_PATH="${CGROUP_PROC_SELF_PATH:-/proc/self/cgroup}"

CGROUP_UNAVAILABLE_REASON=""
cgroup_delegated_base() {
	local fstype uid own
	fstype=$(stat -fc %T "$CGROUP_MOUNT" 2>/dev/null || true)
	if [[ "$fstype" != "cgroup2fs" ]]; then
		printf 'cgroup v2 is not mounted at %s (found: %s)' "$CGROUP_MOUNT" "${fstype:-nothing}"
		return 1
	fi
	uid=$EUID
	# The systemd user manager's own cgroup is delegated to the user and
	# outlives any single shell or scope, so a claim taken in one terminal is
	# still checkable from another.
	own="$CGROUP_MOUNT/user.slice/user-$uid.slice/user@$uid.service"
	if [[ -d "$own" && -w "$own" ]]; then
		printf '%s/%s' "$own" "$CGROUP_SLICE_NAME"
		return 0
	fi
	# Fall back to whatever cgroup this process is already in, if the user has
	# been delegated it.
	# Builtin scan rather than grep(1). /proc/self/cgroup is a handful of lines
	# and this runs on every acquisition.
	local line rel candidate
	line=""
	while read -r candidate; do
		if [[ "$candidate" == '0::'* ]]; then
			line="$candidate"
			break
		fi
	done <"$CGROUP_PROC_SELF_PATH" 2>/dev/null || true
	if [[ -z "$line" ]]; then
		printf 'this process is in no cgroup v2 hierarchy (/proc/self/cgroup has no unified entry)'
		return 1
	fi
	rel=${line#0::}
	if [[ -d "$CGROUP_MOUNT$rel" && -w "$CGROUP_MOUNT$rel" ]]; then
		# /proc/self/cgroup's unified entry is "/" at a delegation root (host or
		# container root alike), so rel is "/" and naive concatenation doubles
		# the separator ("$CGROUP_MOUNT/" + "/$CGROUP_SLICE_NAME"). cgroup_enter's
		# own /proc/self/cgroup re-read is always kernel-reported (single-slash),
		# so a doubled base here is a permanent string-comparison mismatch, not a
		# cosmetic wart: strip rel's trailing slash before joining, the one place
		# the separator can double.
		printf '%s/%s' "$CGROUP_MOUNT${rel%/}" "$CGROUP_SLICE_NAME"
		return 0
	fi
	printf 'no delegated cgroup v2 directory is writable (tried %s and %s)' "$own" "$CGROUP_MOUNT$rel"
	return 1
}

cgroup_enter() {
	local turn_id=$1 base target
	TURN_CGROUP=""
	TURN_CGROUP_PARENT=""
	TURN_CGROUP_TAG="$turn_id"
	if ! base=$(cgroup_delegated_base); then
		CGROUP_UNAVAILABLE_REASON="$base"
		return 1
	fi
	if ! mkdir -p "$base" 2>/dev/null; then
		CGROUP_UNAVAILABLE_REASON="cannot create $base"
		return 1
	fi
	target="$base/turn-$turn_id-$$"
	local stale
	for stale in "$base/turn-$turn_id-"*; do
		[[ -d "$stale" ]] || continue
		rmdir "$stale" 2>/dev/null || true
	done
	if ! mkdir "$target" 2>/dev/null; then
		CGROUP_UNAVAILABLE_REASON="cannot create the turn cgroup $target"
		return 1
	fi
	if ! printf '%s\n' "$$" >"$target/cgroup.procs" 2>/dev/null; then
		rmdir "$target" 2>/dev/null || true
		CGROUP_UNAVAILABLE_REASON="cannot join the turn cgroup $target"
		return 1
	fi
	local now candidate
	now=""
	while read -r candidate; do
		if [[ "$candidate" == '0::'* ]]; then
			now="$candidate"
			break
		fi
	done <"$CGROUP_PROC_SELF_PATH" 2>/dev/null || true
	if [[ "$CGROUP_MOUNT${now#0::}" != "$target" ]]; then
		CGROUP_UNAVAILABLE_REASON="joined $target but /proc/self/cgroup does not agree"
		return 1
	fi
	TURN_CGROUP="$target"
	TURN_CGROUP_PARENT="$base"
	printf '%s' "$target"
	return 0
}

# After the agent exits and before turn.end: move THIS launcher ($$) into the parent
# cgroup so the daemon's cgroup.kill only hits descendants left in TURN_CGROUP.
# TURN_CGROUP path is preserved for the seal.
CGROUP_LEAVE_REASON=""
cgroup_leave_launcher() {
	CGROUP_LEAVE_REASON=""
	if [[ -z "${TURN_CGROUP:-}" || -z "${TURN_CGROUP_PARENT:-}" ]]; then
		CGROUP_LEAVE_REASON="turn cgroup or parent unset"
		return 1
	fi
	if [[ ! -d "$TURN_CGROUP_PARENT" ]]; then
		CGROUP_LEAVE_REASON="parent cgroup missing: $TURN_CGROUP_PARENT"
		return 1
	fi
	if ! printf '%s\n' "$$" >"$TURN_CGROUP_PARENT/cgroup.procs" 2>/dev/null; then
		CGROUP_LEAVE_REASON="cannot move launcher $$ into $TURN_CGROUP_PARENT"
		return 1
	fi
	local now candidate
	now=""
	while read -r candidate; do
		if [[ "$candidate" == '0::'* ]]; then
			now="$candidate"
			break
		fi
	done <"$CGROUP_PROC_SELF_PATH" 2>/dev/null || true
	if [[ "$CGROUP_MOUNT${now#0::}" != "$TURN_CGROUP_PARENT" ]]; then
		CGROUP_LEAVE_REASON="moved to $TURN_CGROUP_PARENT but /proc/self/cgroup is ${CGROUP_MOUNT}${now#0::}"
		return 1
	fi
	# TURN_CGROUP unchanged — daemon seals that path.
	return 0
}
