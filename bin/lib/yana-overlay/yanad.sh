# Launcher-side yanad protocol wrappers.

YANAD_RESPONSE=""

yanad_session_create() {
	local args_json
	args_json=$(PYTHONPATH="$DIR/lib" python3 - "$WORKSPACE" "$$" <<'PY'
import json
import sys

from yanad.client import owner_identity

print(json.dumps({
    "workspace": sys.argv[1],
    "backend": "launcher",
    "kind": "cli",
    "owner": owner_identity(int(sys.argv[2])),
}, separators=(",", ":")))
PY
)
	yanad_client_call launcher "$$" "$TURN_ID:session.create" session.create "$args_json" || return $?
	SESSION_ID=$(python3 - "$YANAD_RESPONSE" <<'PY'
import json
import sys

print(json.loads(sys.argv[1])["result"]["session_id"])
PY
)
	[[ -n "$SESSION_ID" ]] || return 66
}

yanad_safe_component() {
	local value=$1 label=$2
	case "$value" in
		""|.|..|*/*|*$'\n'*) die_usage "$label must be one path component" ;;
	esac
}

yanad_client_call() {
	local kind=$1 owner_pid=$2 request_id=$3 command=$4 args_json=$5 rc
	if YANAD_RESPONSE=$(PYTHONPATH="$DIR/lib" python3 -m yanad.client \
		--root "$STATE_ROOT" --owner-pid "$owner_pid" --id "$request_id" \
		--kind "$kind" "$command" --json "$args_json"); then
		return 0
	else
		rc=$?
		return "$rc"
	fi
}

yanad_turn_args() {
	local mounted_root=$WORKSPACE
	[[ -n "$BROAD_ROOT" ]] && mounted_root=$BROAD_ROOT
	python3 - "$SESSION_ID" "$TURN_ID" "$MODE" "$mounted_root" "$TURN_CGROUP" \
		${TOUCHED_FILES[@]+"${TOUCHED_FILES[@]}"} -- \
		${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"} <<'PY'
import json
import sys

args = sys.argv[1:]
sep = args.index("--")
head, roots = args[:sep], args[sep + 1 :]
session_id, turn_id, mode, mounted_root, cgroup, *files = head
print(json.dumps({
    "session_id": session_id,
    "turn_id": turn_id,
    "mode": mode,
    "mounted_root": mounted_root,
    "roots": roots,
    "cgroup": cgroup,
    "files": files,
}, separators=(",", ":")))
PY
}

yanad_accept_launch() {
	local -a fields=()
	mapfile -d '' -t fields < <(
		PYTHONPATH="$DIR/lib" python3 - "$ANSWER_OUT" "$YANAD_RESPONSE" "$SESSION_ID" \
			${EXTRA_ROOTS[@]+"${EXTRA_ROOTS[@]}"} <<'PY'
import json
import os
import sys

from yanad.slug import workspace_slug

answer_path, encoded, session_id, *declared_roots = sys.argv[1:]
frame = json.loads(encoded)
result = frame["result"]
launch = result["launch"] if "launch" in result else result
with open(answer_path, "w", encoding="utf-8") as stream:
    json.dump({"session_id": session_id, "launch": launch}, stream, separators=(",", ":"))
    stream.write("\n")

layers = launch["layers"]
workspace = layers["workspace"]
values = [os.path.join(workspace, "upper"), os.path.join(workspace, "work")]
for root in declared_roots:
    layer = layers["roots"][workspace_slug(root)]
    values.extend((os.path.join(layer, "upper"), os.path.join(layer, "work")))
sys.stdout.buffer.write(b"\0".join(os.fsencode(value) for value in values) + b"\0")
PY
	)
	(( ${#fields[@]} == 2 + 2 * ${#EXTRA_ROOTS[@]} )) || return 66
	UPPER=${fields[0]}
	WORK=${fields[1]}
	local i offset
	for ((i = 0; i < ${#EXTRA_ROOTS[@]}; i++)); do
		offset=$((2 + 2 * i))
		EXTRA_UPPERS[$i]=${fields[$offset]}
		EXTRA_WORKS[$i]=${fields[$((offset + 1))]}
	done
}

yanad_render_refusal() {
	python3 - "$ANSWER_OUT" "$0" "$YANAD_RESPONSE" <<'PY'
import json
import sys

answer_path, launcher, encoded = sys.argv[1:]
frame = json.loads(encoded)
code = frame["code"]
result = frame["result"]
refuse = dict(result["refuse"] if "refuse" in result else result)
refuse["code"] = code
with open(answer_path, "w", encoding="utf-8") as stream:
    json.dump({"refuse": refuse}, stream, separators=(",", ":"))
    stream.write("\n")

editor = refuse.get("editor") or {}
holder = "%s %s %s" % (
    editor.get("pid", "unknown"),
    editor.get("boot_id", "unknown"),
    editor.get("start_ticks", "unknown"),
)
session_id = refuse.get("session_id", "unknown")
files = ", ".join(refuse.get("files") or [])
# `.get("reason", "unknown")` only falls back when the KEY is absent -- a
# `store.Refused(code)` raised with no reason argument (server.py's own
# `except store.Refused` handler: `{"reason": getattr(exc, "reason", None)}`)
# journals the key PRESENT and set to null, so the fallback here never fires
# and `reason` came back None. `code` not in `templates` then hit
# `templates.get(code, reason).format(...)` with reason itself as the
# template -- `None.format(...)` (measured: row86 case B, code=unknown_session,
# reason=null). Every refuse code the daemon can send must render SOMETHING;
# `code` alone is always a string and is never a worse answer than a crash.
reason = refuse.get("reason") or "unknown"
templates = {
    "review_open": "open overlay review intersects on: {files} (holder: {holder}) — finish or reject that review for the named file(s), or abort it with: {launcher} review-abort --session '{session_id}' --reason 'review intersects incoming files'",
    "review_unreadable": "an open overlay review file set cannot be read ({reason}) (holder: {holder}) — refuse until the record is repaired or the review is aborted with: {launcher} review-abort --session '{session_id}'",
}
print(templates.get(code, "refused: {code} ({reason})").format(
    code=code,
    holder=holder,
    launcher=launcher,
    session_id=session_id,
    files=files,
    reason=reason,
))
PY
}

yanad_turn_request() {
	if ! cgroup_enter "$TURN_ID" >/dev/null; then
		printf 'yana-overlay: %s\n' "$CGROUP_UNAVAILABLE_REASON" >&2
		return 66
	fi
	local args_json rc
	args_json=$(yanad_turn_args)
	if yanad_client_call launcher "$$" "$TURN_ID:turn.request" turn.request "$args_json"; then
		rc=0
	else
		rc=$?
	fi
	case "$rc" in
		0) yanad_accept_launch || return $? ;;
		65)
			yanad_render_refusal >&2
			return 65
			;;
		*) return "$rc" ;;
	esac
}

yanad_turn_end() {
	local outcome=$1 args_json
	args_json=$(python3 - "$SESSION_ID" "$TURN_ID" "$outcome" <<'PY'
import json
import sys
print(json.dumps({
    "session_id": sys.argv[1],
    "turn_id": sys.argv[2],
    "outcome": sys.argv[3],
}, separators=(",", ":")))
PY
)
	yanad_client_call launcher "$$" "$TURN_ID:turn.end" turn.end "$args_json"
}

yanad_file_claim() {
	local session_id=$1 path=$2 args_json
	args_json=$(python3 - "$session_id" "$path" <<'PY'
import json
import sys
print(json.dumps({"session_id": sys.argv[1], "path": sys.argv[2]}, separators=(",", ":")))
PY
)
	yanad_client_call launcher "$$" "$session_id:file.claim:$path" file.claim "$args_json"
}

parse_yanad_admin_args() {
	SESSION_ID=""
	FORCE_REASON=""
	while [[ $# -gt 0 ]]; do
		case "$1" in
			--session)
				[[ $# -ge 2 ]] || die_usage "--session requires an id"
				SESSION_ID=$2
				shift 2
				;;
			--reason)
				[[ $# -ge 2 ]] || die_usage "--reason requires text"
				FORCE_REASON=$2
				shift 2
				;;
			*) die_usage "unknown option: $1" ;;
		esac
	done
	[[ -n "$SESSION_ID" ]] || die_usage "--session is required"
}

# Direct overlay probe: tests and overlay_gate.sh pass explicit layer dirs and only need
# workspace validation + confinement, not a yanad turn.
cmd_run_direct() {
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
	if run_overlay; then
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

cmd_run_yanad() {
	[[ -n "$WORKSPACE" && -n "$TURN_ID" && -n "$MODE" && -n "$ANSWER_OUT" ]] \
		|| die_usage "--workspace, --turn, --mode and --answer-out are required"
	(( ${#CMD[@]} > 0 )) || die_usage "missing command after --"
	ensure_bwrap
	WORKSPACE=$(realpath_safe "$WORKSPACE")
	if [[ -z "$SESSION_ID" ]]; then
		[[ "$AUTO_SESSION" == 1 ]] || die_usage "--session or --session-auto is required"
		yanad_session_create || exit $?
	fi
	yanad_safe_component "$SESSION_ID" "--session"
	yanad_safe_component "$TURN_ID" "--turn"
	local i answer_dir request_rc agent_rc end_rc outcome
	for ((i = 0; i < ${#EXTRA_ROOTS[@]}; i++)); do
		EXTRA_ROOTS[$i]=$(realpath_safe "${EXTRA_ROOTS[$i]}")
	done
	[[ -z "$BROAD_ROOT" ]] || BROAD_ROOT=$(realpath_safe "$BROAD_ROOT")
	answer_dir=${ANSWER_OUT%/*}
	[[ "$answer_dir" == "$ANSWER_OUT" ]] && answer_dir=.
	[[ -d "$answer_dir" && -w "$answer_dir" ]] \
		|| refuse "--answer-out directory '$answer_dir' does not exist or is not writable"
	: >"$ANSWER_OUT"

	set +e
	yanad_turn_request
	request_rc=$?
	set -e
	(( request_rc == 0 )) || exit "$request_rc"

	OPERATOR_HOME=$(operator_home)
	validate_paths
	resolve_cursor_dir
	if run_overlay; then
		agent_rc=0
	else
		agent_rc=$?
	fi
	outcome=ok
	(( agent_rc == 0 )) || outcome=failed
	# Leave the turn cgroup BEFORE turn.end so seal's cgroup.kill cannot
	# SIGKILL this launcher (or its turn.end client child). Failure is
	# deterministic nonzero and skips turn.end.
	set +e
	cgroup_leave_launcher
	leave_rc=$?
	set -e
	if (( leave_rc != 0 )); then
		printf 'yana-overlay: cgroup leave failed: %s\n' "$CGROUP_LEAVE_REASON" >&2
		exit "$EXIT_NO_SANDBOX"
	fi
	set +e
	yanad_turn_end "$outcome"
	end_rc=$?
	set -e
	(( agent_rc == 0 )) || exit "$agent_rc"
	(( end_rc == 0 )) || exit "$end_rc"
	exit 0
}

yanad_admin_command() {
	local command=$1 session_id=$2 reason=${3:-} args_json request_id
	args_json=$(python3 - "$session_id" "$reason" <<'PY'
import json
import sys
args = {"session_id": sys.argv[1]}
if sys.argv[2]:
    args["reason"] = sys.argv[2]
print(json.dumps(args, separators=(",", ":")))
PY
)
	request_id="$session_id:$command"
	PYTHONPATH="$DIR/lib" python3 -m yanad.client --root "$STATE_ROOT" \
		--owner-pid "$$" --id "$request_id" --kind launcher "$command" --json "$args_json"
}
