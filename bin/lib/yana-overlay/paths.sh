#!/usr/bin/env bash
# shellcheck shell=bash
# Path/identity resolution and pre-mount validation — part of bin/yana-overlay.
# Sourced by bin/yana-overlay only. No shebang exec; do not run directly.
# Must not call `set` or install traps: it shares the parent's set -euo pipefail.

usage() {
	cat <<'EOF'
Usage:
  yana-overlay --workspace DIR --session ID --turn ID --mode MODE
                    --answer-out FILE [--touched FILE]...
                    [--broad-root DIR]
                    [--exec-allow FILE]...
                    [--extra-root DIR --extra-upper DIR --extra-work DIR
                    ]... -- CMD [ARGS...]
  yana-overlay review-abort --session ID [--reason TEXT]
  yana-overlay session-delete --session ID --reason TEXT

Establish a kernel overlay at the workspace's real absolute path inside bwrap,
run CMD confined with an empty capability set, and tear down. Fail closed: if
the layer cannot be established the command never runs.

--broad-root DIR mounts the ONE overlay at DIR instead of at the workspace,
where DIR must be the workspace itself or an ancestor of it
(PLAN-R1-capture.md WI-1). Every write anywhere under DIR then lands as a
hunk — the open repo, a sibling repo, or a brand-new directory — with zero
EROFS, because there is one overlay covering the whole broad root rather than
one overlay per declared root. The overlay is mounted -o volatile (no
per-copy-up fsync); the ~/.cursor exception is mounted by yana-overlay-inner
AFTER the overlay, so the bind is not shadowed by the broad-root mount
covering the path it sits on. Omit --broad-root and this launcher's argv,
mounts and messages are byte-identical to what they have always been: the
single overlay sits at the workspace's own path, and the exception is an
outer bwrap arg, exactly as before this flag existed. --broad-root may not
be combined with --extra-root.

The host tree is read-only with exactly one exception: ~/.cursor is bind-mounted
read-write so cursor-agent can refresh its own credentials. Nothing else under
the home directory is writable, and a symlink placed inside ~/.cursor resolves
through the read-only host bind, so it is not a route out. Adding an exception
is a spec change (the isolation contract). Set YANA_OVERLAY_CURSOR_DIR
to relocate the exception; the gate uses it so probes never touch real
credentials.

An operator-declared write root beyond the workspace is passed as a repeated
group: --extra-root starts a group and --extra-upper/--extra-work attach to the
group before them. Each root is mounted as its own overlay at its own real
absolute path, with its own upper layer and work dir, so its change set is
separate and reviewable on its own. Roots must be disjoint from each other and
from every turn layer. Nothing here infers a root: the set comes from the
caller, which takes it from operator configuration only.

Declared roots are mounted, never claimed separately. The launcher asks yanad
for the turn and receives every layer path in the durable answer file. Refusal
is exit 65 and names the holding session and files. Review cleanup uses the
session-based commands above; the retired file-claim commands are rejected.

Exit codes:
  64  usage error
  65  structural refusal (claim held, path validation)
  66  bwrap unavailable
  67  overlay mount failed — command not run
  other  confined command exit code
EOF
}

die_usage() {
	echo "yana-overlay: $*" >&2
	echo "yana-overlay: run with --help for usage" >&2
	exit "$EXIT_USAGE"
}

refuse() {
	echo "yana-overlay: $*" >&2
	exit "$EXIT_REFUSE"
}

refuse_no_sandbox() {
	echo "yana-overlay: $*" >&2
	exit "$EXIT_NO_SANDBOX"
}

refuse_mount() {
	echo "yana-overlay: overlay mount failed: $*" >&2
	exit "$EXIT_MOUNT"
}

realpath_safe() {
	local target=$1
	if [[ ! -e "$target" ]]; then
		# Parameter expansion, not dirname(1)/basename(1). This function recurses
		# once per missing path component and is called for the workspace, the
		# upper, the work dir, the layer root, the claim and every secret mask
		# candidate, so each fork here is paid many times per launch.
		local dir base
		base=${target##*/}
		dir=${target%/*}
		[[ -z "$dir" ]] && dir=/
		dir=$(realpath_safe "$dir")
		echo "${dir%/}/$base"
		return 0
	fi
	readlink -f -- "$target"
}

path_is_prefix() {
	local parent=$1 child=$2
	[[ "$child" == "$parent" || "$child" == "$parent"/* ]]
}

# Ported from bin/yana-sandbox's components_below_root: counts path segments
# below /, so / itself is 0 and a two-segment path is 2. validate_workspace_sanity
# uses it to refuse a workspace too shallow to be a real project directory.
components_below_root() {
	local p="${1%/}"
	if [[ -z "$p" || "$p" == "/" ]]; then
		echo 0
		return
	fi
	local rest="${p#/}"
	local count=1
	local tail="$rest"
	while [[ "$tail" == */* ]]; do
		count=$((count + 1))
		tail="${tail#*/}"
	done
	echo "$count"
}

# Filesystem identity, not spelling. The launch table is populated once after
# every protected path has been canonicalised. `readlink -f` resolves symlinks;
# it does not resolve bind mounts, so two lexically disjoint pathnames can name
# the same directory and every string comparison above still passes. Device plus
# inode is exactly what a bind mount preserves and a pathname does not.
path_identity() {
	printf '%s' "${LAUNCH_PATH_IDENTITY[$1]:-}"
}

# Identities of $1 and of every ancestor up to /, one per line, read from the
# launch table. Ancestors matter because an alias of an ancestor exposes
# everything beneath it: if the exception is a bind alias of the workspace's
# parent, writes through exception/<name>/... reach the real workspace without
# the exception and the workspace ever sharing an identity themselves.
path_identity_chain() {
	local p=$1
	local identity
	while :; do
		identity=${LAUNCH_PATH_IDENTITY[$p]:-}
		[[ -n "$identity" ]] || return 1
		printf '%s\n' "$identity"
		[[ "$p" == "/" ]] && break
		p=${p%/*}
		[[ -z "$p" ]] && p=/
	done
}

# True when $1 and $2 are the same directory, or one contains the other, judged
# by identity rather than by pathname.
identity_overlaps() {
	local a=$1 b=$2 ida idb p identity
	ida=${LAUNCH_PATH_IDENTITY[$a]:-}
	idb=${LAUNCH_PATH_IDENTITY[$b]:-}
	[[ -n "$ida" && -n "$idb" ]] || return 2

	p=$b
	while :; do
		identity=${LAUNCH_PATH_IDENTITY[$p]:-}
		[[ -n "$identity" ]] || return 2
		[[ "$identity" == "$ida" ]] && return 0
		[[ "$p" == "/" ]] && break
		p=${p%/*}
		[[ -z "$p" ]] && p=/
	done

	p=$a
	while :; do
		identity=${LAUNCH_PATH_IDENTITY[$p]:-}
		[[ -n "$identity" ]] || return 2
		[[ "$identity" == "$idb" ]] && return 0
		[[ "$p" == "/" ]] && break
		p=${p%/*}
		[[ -z "$p" ]] && p=/
	done
	return 1
}

# True when $1 contains $2, judged by filesystem identity. Equality counts as
# containment, so a bind alias of the broad root is redundant rather than a
# second overlay over the same bytes.
identity_contains() {
	local parent=$1 child=$2 parent_id p identity
	parent_id=${LAUNCH_PATH_IDENTITY[$parent]:-}
	[[ -n "$parent_id" ]] || return 2
	p=$child
	while :; do
		identity=${LAUNCH_PATH_IDENTITY[$p]:-}
		[[ -n "$identity" ]] || return 2
		[[ "$identity" == "$parent_id" ]] && return 0
		[[ "$p" == "/" ]] && break
		p=${p%/*}
		[[ -z "$p" ]] && p=/
	done
	return 1
}

# Build one launch-local fact table for the five protected paths and their
# ancestor closure. The fast path is exactly one readlink batch plus one stat
# batch. A count mismatch discards that whole batch and retries every input
# separately; partial positional results are never trusted. Nothing survives
# this process, so filesystem changes cannot make a later launch use stale data.
build_launch_identity_table() {
	LAUNCH_PATH_IDENTITY=()
	local -a roots=("$WORKSPACE" "$UPPER" "$WORK" "$LAYER_ROOT" "$CURSOR_DIR")
	# Every declared root and its layer join the closure: the alias checks below
	# are only as complete as this table, and a bind alias between two declared
	# roots is exactly the case a pathname comparison cannot see.
	roots+=(${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"})
	roots+=(${EXTRA_UPPERS[@]+"${EXTRA_UPPERS[@]}"})
	roots+=(${EXTRA_WORKS[@]+"${EXTRA_WORKS[@]}"})
	roots+=(${EXTRA_LAYER_ROOTS[@]+"${EXTRA_LAYER_ROOTS[@]}"})
	[[ -n "$BROAD_ROOT" ]] && roots+=("$BROAD_ROOT")
	local -a paths=() real=() ids=()
	local -A seen=()
	local root p r identity

	for root in "${roots[@]}"; do
		p=$root
		while :; do
			if [[ -z "${seen[$p]+set}" ]]; then
				seen[$p]=1
				paths+=("$p")
			fi
			[[ "$p" == "/" ]] && break
			p=${p%/*}
			[[ -z "$p" ]] && p=/
		done
	done

	mapfile -t real < <(readlink -f -- "${paths[@]}" 2>/dev/null)
	if (( ${#real[@]} != ${#paths[@]} )); then
		real=()
		for p in "${paths[@]}"; do real+=("$(realpath_safe "$p")"); done
	fi

	mapfile -t ids < <(stat -c '%d:%i' -- "${real[@]}" 2>/dev/null)
	if (( ${#ids[@]} != ${#real[@]} )); then
		ids=()
		for r in "${real[@]}"; do
			ids+=("$(stat -c '%d:%i' -- "$r" 2>/dev/null || true)")
		done
	fi

	for p in "${!paths[@]}"; do
		r=${real[$p]:-}
		identity=${ids[$p]:-}
		[[ -n "$r" && -n "$identity" ]] || return 1
		LAUNCH_PATH_IDENTITY["${paths[$p]}"]=$identity
	done
}

operator_home() {
	local h
	h=$(getent passwd "${USER:-$(id -un)}" 2>/dev/null | cut -d: -f6 || true)
	printf '%s' "${h:-${HOME:-}}"
}

# The single writable host exception (the isolation contract). cursor-agent
# has no way to hand its refreshed credentials anywhere else, so a turn with a
# read-only ~/.cursor fails the moment a token expires. Everything else on the
# host stays on the read-only bind.
#
# The exception is resolved to a real path so exactly one host directory becomes
# writable, and it must not overlap the confined tree in either direction: a
# workspace inside it would be writable at its real absolute path, and a layer
# root inside it would let the agent rewrite the very upper layer the change set
# is read from.
resolve_cursor_dir() {
	local dir
	dir="${YANA_OVERLAY_CURSOR_DIR:-}"
	if [[ -z "$dir" ]]; then
		if [[ -z "$OPERATOR_HOME" ]]; then
			refuse "cannot resolve the operator home directory for the ~/.cursor exception"
		fi
		dir="$OPERATOR_HOME/.cursor"
	fi
	if ! mkdir -p "$dir" 2>/dev/null; then
		refuse "cannot create the writable-host exception directory '$dir'"
	fi
	dir=$(realpath_safe "$dir")
	if [[ ! -d "$dir" ]]; then
		refuse "writable-host exception '$dir' is not a directory"
	fi
	# A read-only HOME workspace may contain the backend's one writable runtime
	# directory. The reverse direction and equality remain forbidden: either
	# would make the selected workspace writable through the exception.
	local readonly_workspace_runtime=0
	if [[ "$READ_ONLY_WORKSPACE" == 1 && "$dir" != "$WORKSPACE" ]] \
		&& path_is_prefix "$WORKSPACE" "$dir"; then
		readonly_workspace_runtime=1
	fi
	if (( ! readonly_workspace_runtime )) \
		&& { path_is_prefix "$dir" "$WORKSPACE" || path_is_prefix "$WORKSPACE" "$dir"; }; then
		refuse "writable-host exception ($dir) must be disjoint from the workspace ($WORKSPACE)"
	fi
	if path_is_prefix "$dir" "$LAYER_ROOT" || path_is_prefix "$LAYER_ROOT" "$dir"; then
		refuse "writable-host exception ($dir) must be disjoint from the layer root ($LAYER_ROOT)"
	fi
	CURSOR_DIR="$dir"

	# Disjoint pathnames are not disjoint directories. Repeat both checks by
	# filesystem identity so a bind-mount alias cannot slip past the string
	# comparison. Failing to obtain an identity refuses the turn, like any other
	# failure to establish the exception.
	local dir_id ws_id layer_id
	if ! build_launch_identity_table; then
		refuse "cannot establish filesystem identity for the writable-host exception ($dir), the workspace ($WORKSPACE) or the layer root ($LAYER_ROOT)"
	fi
	reduce_capture_set_by_identity
	rebuild_protected_paths
	local protected
	for protected in ${PROTECTED_PATHS[@]+"${PROTECTED_PATHS[@]}"}; do
		[[ -n "$protected" ]] || continue
		if [[ "$protected" == "$WORKSPACE" && "$readonly_workspace_runtime" == 1 ]]; then
			continue
		fi
		if path_is_prefix "$dir" "$protected" || path_is_prefix "$protected" "$dir"; then
			refuse "writable-host exception ($dir) must be disjoint from every declared write root and its layer ($protected)"
		fi
	done
	dir_id=$(path_identity "$dir")
	ws_id=$(path_identity "$WORKSPACE")
	layer_id=$(path_identity "$LAYER_ROOT")
	if [[ -z "$dir_id" || -z "$ws_id" || -z "$layer_id" ]]; then
		refuse "cannot establish filesystem identity for the writable-host exception ($dir), the workspace ($WORKSPACE) or the layer root ($LAYER_ROOT)"
	fi
	if [[ "$readonly_workspace_runtime" != 1 ]] && identity_overlaps "$dir" "$WORKSPACE"; then
		refuse "writable-host exception ($dir, $dir_id) aliases the workspace ($WORKSPACE, $ws_id) — same directory or one contains the other despite disjoint pathnames"
	fi
	if identity_overlaps "$dir" "$LAYER_ROOT"; then
		refuse "writable-host exception ($dir, $dir_id) aliases the layer root ($LAYER_ROOT, $layer_id) — same directory or one contains the other despite disjoint pathnames"
	fi
	for protected in ${PROTECTED_PATHS[@]+"${PROTECTED_PATHS[@]}"}; do
		[[ -n "$protected" ]] || continue
		if [[ "$protected" == "$WORKSPACE" && "$readonly_workspace_runtime" == 1 ]]; then
			continue
		fi
		if identity_overlaps "$dir" "$protected"; then
			refuse "writable-host exception ($dir, $dir_id) aliases a declared write root or its layer ($protected) — same directory or one contains the other despite disjoint pathnames"
		fi
	done
	validate_root_identities
}

# A broad root and a disjoint capture set compose. The editor already removes
# pathname-contained entries; this repeat catches bind aliases, which realpath
# cannot see. An extra containing the broad root would create nested writable
# views with competing change sets, so it refuses by name.
reduce_capture_set_by_identity() {
	[[ -n "$BROAD_ROOT" ]] || return 0
	(( ${#EXTRA_ROOTS[@]} > 0 )) || return 0
	local i root rc
	local -a kept_roots=() kept_uppers=() kept_works=() kept_layers=()
	for (( i = 0; i < ${#EXTRA_ROOTS[@]}; i++ )); do
		root=${EXTRA_ROOTS[$i]}
		set +e
		identity_contains "$BROAD_ROOT" "$root"
		rc=$?
		set -e
		if (( rc == 0 )); then
			continue
		elif (( rc == 2 )); then
			refuse "cannot establish filesystem identity between broad root '$BROAD_ROOT' and declared write root '$root'"
		fi
		set +e
		identity_contains "$root" "$BROAD_ROOT"
		rc=$?
		set -e
		if (( rc == 0 )); then
			refuse "declared write root '$root' contains broad root '$BROAD_ROOT' — remove it or declare a disjoint capture root"
		elif (( rc == 2 )); then
			refuse "cannot establish filesystem identity between broad root '$BROAD_ROOT' and declared write root '$root'"
		fi
		kept_roots+=("$root")
		kept_uppers+=("${EXTRA_UPPERS[$i]}")
		kept_works+=("${EXTRA_WORKS[$i]}")
		kept_layers+=("${EXTRA_LAYER_ROOTS[$i]}")
	done
	EXTRA_ROOTS=("${kept_roots[@]}")
	EXTRA_UPPERS=("${kept_uppers[@]}")
	EXTRA_WORKS=("${kept_works[@]}")
	EXTRA_LAYER_ROOTS=("${kept_layers[@]}")
}

rebuild_protected_paths() {
	PROTECTED_PATHS=("$WORKSPACE" "$LAYER_ROOT")
	local i
	for (( i = 0; i < ${#EXTRA_ROOTS[@]}; i++ )); do
		PROTECTED_PATHS+=("${EXTRA_ROOTS[$i]}" "${EXTRA_LAYER_ROOTS[$i]}")
	done
}

# Declared roots must be disjoint BY IDENTITY as well as by pathname. Two roots
# that are bind aliases of one directory would each be mounted as the writable
# view of the same bytes, and the two change sets could not be told apart at
# review; a root that aliases a layer root would let the agent rewrite the very
# upper layer its own change set is read from. Runs after the launch identity
# table exists, which is why it lives here rather than in validate_paths.
validate_root_identities() {
	(( ${#EXTRA_ROOTS[@]} > 0 )) || return 0
	local i j a b rc
	local -a all_roots=("$WORKSPACE" ${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"})
	for (( i = 0; i < ${#all_roots[@]}; i++ )); do
		a=${all_roots[$i]}
		for (( j = i + 1; j < ${#all_roots[@]}; j++ )); do
			b=${all_roots[$j]}
			set +e
			identity_overlaps "$a" "$b"
			rc=$?
			set -e
			if (( rc == 0 )); then
				refuse "declared write root '$b' aliases '$a' — same directory or one contains the other despite disjoint pathnames"
			fi
			if (( rc == 2 )); then
				refuse "cannot establish filesystem identity for the declared write roots '$a' and '$b'"
			fi
		done
		for (( j = 0; j < ${#EXTRA_LAYER_ROOTS[@]}; j++ )); do
			b=${EXTRA_LAYER_ROOTS[$j]}
			[[ -n "$b" ]] || continue
			set +e
			identity_overlaps "$a" "$b"
			rc=$?
			set -e
			if (( rc == 0 )); then
				refuse "declared write root '$a' aliases a turn layer root ($b) — the agent could rewrite the change set it is reviewed from"
			fi
		done
	done
}


# resolve_state_root — same precedence as bin/yana-turn's $STATE_ROOT and
# lua/yana/shadow/preview.lua's M.state_root(): YANA_STATE_ROOT, then
# XDG_STATE_HOME/yana, then $HOME/.local/state/yana. Used only to place the
# secret mask's own runtime scratch outside the confined tree; the turn's
# chosen state root (upper/work) is already passed in by the caller.
resolve_state_root() {
	if [[ -n "${YANA_STATE_ROOT:-}" ]]; then
		printf '%s' "$YANA_STATE_ROOT"
	elif [[ -n "${XDG_STATE_HOME:-}" ]]; then
		printf '%s' "$XDG_STATE_HOME/yana"
	else
		printf '%s' "$HOME/.local/state/yana"
	fi
}


ensure_bwrap() {
	if [[ ! -x "$BWRAP" ]] && ! command -v "$BWRAP" >/dev/null 2>&1; then
		refuse_no_sandbox "bwrap not found at '$BWRAP'"
	fi
	if [[ ! -x "$BWRAP" ]]; then
		BWRAP=$(command -v "$BWRAP")
	fi
}

# Ported from bin/yana-sandbox's validate_workspace (bin/yana-sandbox:127-152): the four
# refusals that keep an operator from launching a turn whose workspace IS the operator's
# home, the passwd-recorded home, the filesystem root, or a directory too shallow to be
# a real project. Applied only to the primary workspace root (root_noun == "workspace")
# -- an --extra-root or --broad-root is additional write surface inside an
# already-accepted workspace, not a new place the operator could mistake for a project
#
# It runs before resolve_cursor_dir, which is where the writable-host
# exception (~/.cursor) collides with workspace == $HOME and produces the
# "must be disjoint from the workspace" refusal -- a true but misleading
# symptom of the real problem this function names directly. That
# disjointness check stays in place as defence in depth; this function just
# makes sure the operator sees the right refusal first.
validate_workspace_sanity() {
	local ws_real=$1
	local passwd_home env_home depth

	passwd_home=$(getent passwd "${USER:-$(id -un)}" 2>/dev/null | cut -d: -f6 || true)
	if [[ -n "$passwd_home" ]]; then
		passwd_home=$(realpath_safe "$passwd_home")
	fi
	env_home=""
	if [[ -n "${HOME:-}" ]]; then
		env_home=$(realpath_safe "$HOME")
	fi

	if [[ "$ws_real" == "/" ]]; then
		refuse "workspace resolves to / — refusing to sandbox the filesystem root"
	fi
	if [[ -n "$passwd_home" && "$ws_real" == "$passwd_home" ]]; then
		refuse "workspace resolves to the user home directory ($passwd_home, passwd lookup) — pick a project subdirectory"
	fi
	if [[ -n "$env_home" && "$ws_real" == "$env_home" ]]; then
		refuse "workspace resolves to the user home directory ($env_home, \$HOME) — pick a project subdirectory"
	fi
	depth=$(components_below_root "$ws_real")
	if (( depth < 2 )); then
		refuse "workspace '$ws_real' has fewer than 2 path components below root — pick a deeper directory (a project folder inside your home directory)"
	fi
}

# validate_root_triple — one root's (root, upper, work) triple, validated
# exactly as the single-root launcher always validated the workspace's. The
# message nouns are parameters so the primary root's refusals stay word for
# word what they were, while an extra root's refusal says which root it is
# about: an exit-65 that does not name the failing root is unactionable when a
# turn declares several.
#
# Results come back in VALIDATED_* rather than on stdout: a command
# substitution would fork per root, and refuse()'s exit would be the
# subshell's rather than the launcher's.
VALIDATED_ROOT=""
VALIDATED_UPPER=""
VALIDATED_WORK=""
VALIDATED_LAYER_ROOT=""
validate_root_triple() {
	local root_in=$1 upper_in=$2 work_in=$3 root_noun=$4 upper_noun=$5 work_noun=$6
	local ws upper work upper_parent work_parent layer_root

	ws=$(realpath_safe "$root_in")
	upper=$(realpath_safe "$upper_in")
	work=$(realpath_safe "$work_in")

	if [[ ! -d "$ws" ]]; then
		refuse "$root_noun '$root_in' does not exist or is not a directory"
	fi
	# Sanity refusal fires only for the primary workspace root, before
	# resolve_cursor_dir gets a chance to raise the misleading writable-host
	# disjointness refusal for the same underlying mistake (workspace == $HOME).
	# Open capture deliberately allows the primary workspace to be $HOME. Its
	# CapturePlan owns the private upper and keeps the state root mounted after
	# the capture view, so the legacy project-depth guard would reject the
	# supported home-dotfile and cross-project workflow before that plan runs.
	if [[ "$root_noun" == "workspace" && "$READ_ONLY_WORKSPACE" != 1 && -z "$CAPTURE_PLAN" \
		&& "${YANA_OPEN_CAPTURE_MODE:-off}" == off ]]; then
		validate_workspace_sanity "$ws"
	fi
	if [[ -e "$upper" && ! -d "$upper" ]]; then
		refuse "$upper_noun '$upper_in' exists and is not a directory"
	fi
	if [[ -e "$work" && ! -d "$work" ]]; then
		refuse "$work_noun '$work_in' exists and is not a directory"
	fi
	mkdir -p "$upper" "$work"

	# Both parents come off with parameter expansion; the paths are already
	# resolved so the trailing component is all that has to go.
	upper_parent=$(realpath_safe "${upper%/*}")
	work_parent=$(realpath_safe "${work%/*}")
	if [[ "$upper_parent" != "$work_parent" ]]; then
		refuse "$upper_noun and $work_noun must share a parent directory (overlay requires one mount)"
	fi
	layer_root="$upper_parent"
	if [[ "${upper##*/}" != "upper" || "${work##*/}" != "work" ]]; then
		: "nonstandard names allowed; parent mount is what matters"
	fi

	local entry base extra=0
	shopt -s nullglob
	for entry in "$layer_root"/*; do
		base=${entry##*/}
		case "$base" in
			upper | work | "$MOUNT_MARKER") ;;
			*) extra=1; break ;;
		esac
	done
	shopt -u nullglob
	if (( extra )); then
		refuse "layer root '$layer_root' must contain only upper/, work/, and $MOUNT_MARKER (nested turn layers must use separate roots)"
	fi

	VALIDATED_ROOT="$ws"
	VALIDATED_UPPER="$upper"
	VALIDATED_WORK="$work"
	VALIDATED_LAYER_ROOT="$layer_root"
}

validate_paths() {
	validate_root_triple "$WORKSPACE" "$UPPER" "$WORK" workspace upper work
	WORKSPACE="$VALIDATED_ROOT"
	UPPER="$VALIDATED_UPPER"
	WORK="$VALIDATED_WORK"
	LAYER_ROOT="$VALIDATED_LAYER_ROOT"
	PROTECTED_PATHS=("$WORKSPACE" "$LAYER_ROOT")

	# The broad root (WI-1): an ancestor of the workspace, or the workspace
	# itself, resolved and validated here so every later stage (the identity
	# table, run_overlay) sees a canonical absolute path or
	# an empty string -- never the raw, unresolved --broad-root argument.
	if [[ -n "$BROAD_ROOT" ]]; then
		BROAD_ROOT=$(realpath_safe "$BROAD_ROOT")
		if [[ ! -d "$BROAD_ROOT" ]]; then
			refuse "broad root '$BROAD_ROOT' does not exist or is not a directory"
		fi
		if ! path_is_prefix "$BROAD_ROOT" "$WORKSPACE"; then
			refuse "broad root '$BROAD_ROOT' must be an ancestor of the workspace '$WORKSPACE', or the workspace itself"
		fi
	fi

	# Extra roots are validated in the order given, and each one is checked
	# against everything already accepted. Overlap in either direction is
	# refused: two overlays whose mountpoints nest would each claim to be the
	# writable view of the same bytes, and a root containing a layer root would
	# hand the agent its own change set to rewrite.
	local i j protected
	local -a kept_roots=() kept_uppers=() kept_works=() kept_layers=()
	for (( i = 0; i < ${#EXTRA_ROOTS[@]}; i++ )); do
		validate_root_triple "${EXTRA_ROOTS[$i]}" "${EXTRA_UPPERS[$i]}" "${EXTRA_WORKS[$i]}" \
			"declared write root" "extra upper" "extra work"
		if [[ -n "$BROAD_ROOT" ]]; then
			if path_is_prefix "$BROAD_ROOT" "$VALIDATED_ROOT"; then
				continue
			fi
			if path_is_prefix "$VALIDATED_ROOT" "$BROAD_ROOT"; then
				refuse "declared write root '$VALIDATED_ROOT' contains broad root '$BROAD_ROOT' — remove it or declare a disjoint capture root"
			fi
		fi
		for (( j = 0; j < ${#PROTECTED_PATHS[@]}; j++ )); do
			protected=${PROTECTED_PATHS[$j]}
			[[ -n "$protected" ]] || continue
			if path_is_prefix "$protected" "$VALIDATED_ROOT" || path_is_prefix "$VALIDATED_ROOT" "$protected"; then
				refuse "declared write root '$VALIDATED_ROOT' overlaps '$protected' — every declared root must be disjoint from the workspace, from the other roots and from every turn layer"
			fi
		done
		kept_roots+=("$VALIDATED_ROOT")
		kept_uppers+=("$VALIDATED_UPPER")
		kept_works+=("$VALIDATED_WORK")
		kept_layers+=("$VALIDATED_LAYER_ROOT")
		PROTECTED_PATHS+=("$VALIDATED_ROOT" "$VALIDATED_LAYER_ROOT")
	done
	EXTRA_ROOTS=("${kept_roots[@]}")
	EXTRA_UPPERS=("${kept_uppers[@]}")
	EXTRA_WORKS=("${kept_works[@]}")
	EXTRA_LAYER_ROOTS=("${kept_layers[@]}")
}
