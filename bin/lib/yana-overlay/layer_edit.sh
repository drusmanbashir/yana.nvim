# The launch's layer editor: every change this launcher makes to a turn's upper
# layers before its agent runs (panel rules F-ADDENDUM-TURN and F-ADDENDUM-B0;
# follow-up plan, "Execution, failure and recovery").
#
# Puts are the open buffers' copies (--seed) and, on a resumed Turn only,
# --layer-put PATH=FROM so an unopened file matches the selected review view;
# --layer-remove PATH drops a file's upper copy so the real file shows through.
# A resumed Turn's writer is stopped: the daemon answered turn.resume only from
# `reviewing`, so this launcher is the layer's one writer. Text files only (M1):
# an upper entry that is neither a regular file nor a symlink (a whiteout, a
# directory) is refused, never replaced. Every check runs before the first
# mutation, the inverse facts are recorded before it, and a failure restores them.
# Must not call `set` or install traps: it shares the parent's set -euo pipefail.

LAYER_PUTS=()
LAYER_REMOVES=()
LAYER_INVERSE=""
LAYER_EDIT_REASON=""
LAYER_MUTATED=0
CYCLE_FLAG_SHIFT=1
# yana-overlay-inner's final exec shell writes `started` just before the agent
# command's exec and `exec_failed` if that exec fails; mount markers prove no start.
readonly AGENT_START_MARKER=.yana-overlay-started

# One --generation / --resume / --layer-* option of parse_run_args.
cycle_flag() {
	if [[ "$1" == --resume ]]; then
		YANAD_RESUME=1
		CYCLE_FLAG_SHIFT=1
		return 0
	fi
	[[ $# -ge 2 ]] || die_usage "$1 requires a value"
	case "$1" in
		--generation)
			[[ "$2" =~ ^[0-9]+$ ]] || die_usage "--generation must be a non-negative integer"
			YANAD_GENERATION=$2
			;;
		--layer-put) LAYER_PUTS+=("$2") ;;
		--layer-remove) LAYER_REMOVES+=("$2") ;;
		--layer-inverse) LAYER_INVERSE=$2 ;;
		*) die_usage "unknown option: $1" ;;
	esac
	CYCLE_FLAG_SHIFT=2
}

# Checked before the daemon is asked for the turn, like seed_check: a refused
# edit leaves the reviewing Turn untouched.
LAYER_PUT_PATHS=()
LAYER_PUT_FROMS=()
LAYER_REMOVE_PATHS=()
layer_check() {
	if (( YANAD_RESUME == 1 )); then
		[[ -n "$YANAD_GENERATION" ]] || die_usage "--resume requires --generation"
		# Every resumed launch may rewrite the layer, seeds included: inverse facts are not optional.
		[[ "$LAYER_INVERSE" == /* ]] || die_usage "--resume needs an absolute --layer-inverse"
	fi
	(( ${#LAYER_PUTS[@]} + ${#LAYER_REMOVES[@]} > 0 )) || return 0
	(( YANAD_RESUME == 1 )) \
		|| die_usage "--layer-put/--layer-remove edit a stopped writer's layer and need --resume"
	[[ "$LAYER_INVERSE" == /* ]] || die_usage "--layer-put/--layer-remove need an absolute --layer-inverse"
	local edit path from
	for edit in ${LAYER_PUTS[@]+"${LAYER_PUTS[@]}"}; do
		path=${edit%=*}
		from=${edit##*=}
		[[ "$edit" == *=* && "$path" == /* && "$from" == /* ]] \
			|| die_usage "--layer-put '$edit' must be PATH=FROM, both absolute"
		path=$(realpath_safe "$path")
		[[ -f "$from" && -r "$from" ]] || refuse "layer put source '$from' for '$path' is not a readable file"
		seed_root_of "$path" || refuse "layer put '$path' is outside the turn's roots; it has no upper layer"
		LAYER_PUT_PATHS+=("$path")
		LAYER_PUT_FROMS+=("$from")
	done
	for path in ${LAYER_REMOVES[@]+"${LAYER_REMOVES[@]}"}; do
		[[ "$path" == /* ]] || die_usage "--layer-remove '$path' must be absolute"
		path=$(realpath_safe "$path")
		seed_root_of "$path" || refuse "layer remove '$path' is outside the turn's roots; it has no upper layer"
		LAYER_REMOVE_PATHS+=("$path")
	done
}

# One target, resolved inside its upper and checked; nothing is touched here.
LAYER_T_KIND=()
LAYER_T_PATH=()
LAYER_T_DEST=()
LAYER_T_FROM=()
layer_target() {
	local kind=$1 path=$2 from=$3 dest parent
	if [[ "$path" == *$'\t'* || "$path" == *$'\n'* ]]; then
		LAYER_EDIT_REASON="'$path' has a tab or newline in its name"
		return 1
	fi
	if ! seed_root_of "$path"; then
		LAYER_EDIT_REASON="'$path' is outside the turn's roots"
		return 1
	fi
	dest="$SEED_UPPER/${path#"$SEED_ROOT"/}"
	# An upper can hold symlinks an agent made; never follow one out of it.
	parent=$(realpath_safe "${dest%/*}")
	if ! path_is_prefix "$SEED_UPPER" "$parent"; then
		LAYER_EDIT_REASON="'$path' would be written outside its upper layer (through '$parent')"
		return 1
	fi
	dest="$parent/${dest##*/}"
	if [[ -e "$dest" && ! -L "$dest" && ! -f "$dest" ]]; then
		LAYER_EDIT_REASON="'$path' is not a text file in the layer; whiteout and directory edits are not supported"
		return 1
	fi
	LAYER_T_KIND+=("$kind")
	LAYER_T_PATH+=("$path")
	LAYER_T_DEST+=("$dest")
	LAYER_T_FROM+=("$from")
}

# Inverse facts, one row per target before any mutation: kind, dest, prior
# (absent|file|link), mode, saved (bytes file, link target, or -).
layer_record_inverse() {
	[[ -n "$LAYER_INVERSE" ]] || return 0
	local i dest prior mode saved manifest="$LAYER_INVERSE/manifest.tsv"
	mkdir -p -- "$LAYER_INVERSE/bytes" && : >"$manifest" || return 1
	for i in "${!LAYER_T_DEST[@]}"; do
		dest=${LAYER_T_DEST[$i]}
		prior=absent mode=- saved=-
		if [[ -L "$dest" ]]; then
			prior=link
			saved=$(readlink -- "$dest") || return 1
		elif [[ -f "$dest" ]]; then
			prior=file
			mode=$(stat -c %a -- "$dest") || return 1
			saved=bytes/$i
			cp -- "$dest" "$LAYER_INVERSE/$saved" || return 1
		fi
		printf '%s\t%s\t%s\t%s\t%s\n' "${LAYER_T_KIND[$i]}" "$dest" "$prior" "$mode" "$saved" >>"$manifest" || return 1
	done
}

# Keeps the disk file's mode (644 for a file not on disk), as the seed copy always did.
layer_mutate() {
	local i dest mode
	LAYER_MUTATED=1
	for i in "${!LAYER_T_DEST[@]}"; do
		dest=${LAYER_T_DEST[$i]}
		if [[ "${LAYER_T_KIND[$i]}" == remove ]]; then
			rm -f -- "$dest" || return 1
			continue
		fi
		mode=644
		[[ -f "${LAYER_T_PATH[$i]}" ]] && mode=$(stat -c %a -- "${LAYER_T_PATH[$i]}")
		mkdir -p -- "${dest%/*}" || return 1
		cp --remove-destination -- "${LAYER_T_FROM[$i]}" "$dest" || return 1
		chmod -- "$mode" "$dest" || return 1
	done
}

# The effective view before launch: each put reads back as its bytes, each
# remove leaves no upper entry.
layer_verify() {
	local i dest
	for i in "${!LAYER_T_DEST[@]}"; do
		dest=${LAYER_T_DEST[$i]}
		if [[ "${LAYER_T_KIND[$i]}" == remove ]]; then
			[[ ! -e "$dest" && ! -L "$dest" ]] && continue
			LAYER_EDIT_REASON="'${LAYER_T_PATH[$i]}' is still in the layer after its remove"
			return 1
		fi
		cmp -s -- "${LAYER_T_FROM[$i]}" "$dest" && continue
		LAYER_EDIT_REASON="'${LAYER_T_PATH[$i]}' does not read back as its put bytes"
		return 1
	done
}

# A resumed Turn's layer roots still hold the previous run's mount and start
# markers; this run's evidence must be its own.
layer_clear_mount_markers() {
	local layer
	for layer in "$LAYER_ROOT" ${EXTRA_LAYER_ROOTS[@]+"${EXTRA_LAYER_ROOTS[@]}"}; do
		if [[ -n "$layer" ]]; then
			rm -f -- "$layer/$MOUNT_MARKER" "$layer/$AGENT_START_MARKER"
		fi
	done
}

# The agent command's exec succeeded: the launch transaction is over.
agent_started() {
	[[ -f "$LAYER_ROOT/$AGENT_START_MARKER" && "$(<"$LAYER_ROOT/$AGENT_START_MARKER")" == started ]]
}

# One restored row reads back as its recorded facts.
layer_restored() {
	local dest=$1 prior=$2 mode=$3 saved=$4
	case "$prior" in
		absent) [[ ! -e "$dest" && ! -L "$dest" ]] ;;
		file) [[ ! -L "$dest" && -f "$dest" ]] && cmp -s -- "$LAYER_INVERSE/$saved" "$dest" \
			&& [[ "$(stat -c %a -- "$dest")" == "$mode" ]] ;;
		link) [[ -L "$dest" && "$(readlink -- "$dest")" == "$saved" ]] ;;
		*) return 1 ;;
	esac
}

# Newest first, back to the recorded facts; success only when every row reads back.
layer_restore() {
	[[ -n "$LAYER_INVERSE" && -f "$LAYER_INVERSE/manifest.tsv" ]] || return 1
	local -a rows=()
	local i kind dest prior mode saved rc=0
	mapfile -t rows <"$LAYER_INVERSE/manifest.tsv"
	for (( i = ${#rows[@]} - 1; i >= 0; i-- )); do
		IFS=$'\t' read -r kind dest prior mode saved <<<"${rows[$i]}"
		rm -f -- "$dest" || rc=1
		case "$prior" in
			file) { cp -- "$LAYER_INVERSE/$saved" "$dest" && chmod -- "$mode" "$dest"; } || rc=1 ;;
			link) ln -s -- "$saved" "$dest" || rc=1 ;;
		esac
		layer_restored "$dest" "$prior" "$mode" "$saved" || rc=1
	done
	return "$rc"
}

# After validate_paths has the final uppers, before the overlay is mounted. A
# read-only turn mounts no overlay, so nothing would read an upper copy.
layer_apply() {
	(( READ_ONLY_WORKSPACE == 1 )) && return 0
	local i
	for i in "${!SEED_PATHS[@]}"; do
		layer_target put "${SEED_PATHS[$i]}" "${SEED_FROMS[$i]}" || return 1
	done
	for i in "${!LAYER_PUT_PATHS[@]}"; do
		layer_target put "${LAYER_PUT_PATHS[$i]}" "${LAYER_PUT_FROMS[$i]}" || return 1
	done
	for i in "${!LAYER_REMOVE_PATHS[@]}"; do
		layer_target remove "${LAYER_REMOVE_PATHS[$i]}" "" || return 1
	done
	if ! layer_record_inverse; then
		LAYER_EDIT_REASON="cannot record the inverse facts in '$LAYER_INVERSE'"
		return 1
	fi
	if ! layer_mutate; then
		LAYER_EDIT_REASON="cannot write the turn's upper layer"
		return 1
	fi
	layer_verify
}

# A named launch failure. The refusal evidence and the rollback come first. Only a
# verified rollback (or no mutation) sends launch_failed, which returns a reviewing
# Turn to `reviewing`; a rollback that did not read back sends launch_unrestored,
# which halts the Turn as recovery_required with its inverse facts kept.
layer_launch_failed() {
	set +e
	YANAD_LAUNCH_OPEN=0
	trap - EXIT
	local outcome=launch_failed layer=untouched kept="the prior review is kept"
	if [[ -n "$LAYER_INVERSE" ]] && mkdir -p -- "$LAYER_INVERSE"; then
		printf '%s\n' "$LAYER_EDIT_REASON" >"$LAYER_INVERSE/refusal.txt"
	fi
	if (( LAYER_MUTATED == 1 )); then
		layer=restored
		if ! layer_restore; then
			outcome=launch_unrestored
			layer="NOT restored (inverse facts: ${LAYER_INVERSE:-none recorded})"
			kept="the Turn is halted as recovery_required"
		fi
	fi
	(( YANAD_RESUME == 1 )) || kept="no prior review existed"
	if cgroup_leave_launcher; then
		yanad_finish_turn "$outcome"
	fi
	printf 'yana-overlay: launch failed: %s; layer %s; %s\n' "$LAYER_EDIT_REASON" "$layer" "$kept" >&2
	exit "$EXIT_REFUSE"
}
