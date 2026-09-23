"""Per-session store for yanad U1."""

import dataclasses
import hashlib
import json
import os
import re
import shutil
import time
import uuid



# Turn states (running -> settling -> reviewing
# -> closed; running -> dead -> sealed | dead_unsealed).
TURN_STATES = frozenset({
    "running", "settling", "reviewing", "closed", "dead", "sealed", "dead_unsealed",
})


class OutsideRoot(Exception):
    """Path would place daemon-owned data outside the state root."""


class Refused(Exception):
    """Store command refusal with a stable code."""

    def __init__(self, code, reason=None):
        self.code = code
        self.reason = reason
        super().__init__(code)


@dataclasses.dataclass
class ReplayRow:
    path: str
    kind: str
    reason: str


class Replay(list):
    """Replay rows."""


def _real(path):
    return os.path.realpath(os.fspath(path))


def _inside_root(root, path):
    root_real = _real(root)
    path_real = _real(path)
    if path_real == root_real or path_real.startswith(root_real + os.sep):
        return path_real
    raise OutsideRoot(path_real)


def _guard_lexical_escape(root, path):
    root_lexical = os.fspath(root)
    path_lexical = os.fspath(path)
    if not os.path.isabs(root_lexical):
        root_lexical = os.path.join(os.getcwd(), root_lexical)
    if not os.path.isabs(path_lexical):
        path_lexical = os.path.join(os.getcwd(), path_lexical)
    root_prefix = root_lexical.rstrip(os.sep) + os.sep
    if path_lexical == root_lexical or path_lexical.startswith(root_prefix):
        _inside_root(root, path)


def _inside_any(roots, path):
    for root in roots:
        try:
            _inside_root(root, path)
            return True
        except OutsideRoot:
            pass
    return False


def _session_dir(root, session_id):
    return _inside_root(root, os.path.join(os.fspath(root), "sessions", session_id))


def _turn_dir(root, session_id, turn_id):
    return _inside_root(root, os.path.join(_session_dir(root, session_id), "turns", turn_id))


def _mkdir(path):
    os.makedirs(path, exist_ok=True)


def write_json_atomic(path, data):
    """Write JSON through tmp + replace + fsync.

    Pure filesystem work over its arguments: no module or daemon state is read
    or written here, so a caller on an event loop may run it (and anything
    built on it, such as `create_session`) in an executor thread to keep the
    loop answering while the two fsyncs land. See server.session_create.
    """
    target = os.fspath(path)
    parent = os.path.dirname(target)
    _mkdir(parent)
    tmp = os.path.join(parent, ".%s.tmp.%s" % (os.path.basename(target), uuid.uuid4()))
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            json.dump(data, fh, sort_keys=True)
            fh.write("\n")
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, target)
        _fsync_dir(parent)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise


def _fsync_dir(path):
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _read_json(path):
    with open(path, "r", encoding="utf-8") as fh:
        return json.load(fh)


def _plan_canonical(plan):
    body = dict(plan)
    body.pop("plan_id", None)
    return json.dumps(body, ensure_ascii=False, sort_keys=True, separators=(",", ":"))


def validate_turn_plan(plan, session_id, turn_id):
    """Reject malformed or foreign plans before allocating turn state.

    The daemon is the plan's validator, not its author: it recomputes the
    `plan_id` under the same canonical rule `lua/yana/turn/turn_plan.lua` used to
    mint it, so a plan edited anywhere between the builder and this call
    refuses here rather than allocating a turn around it.
    """
    required = {
        "plan_version", "plan_id", "session_id", "turn_id", "mode", "anchor", "label",
        "seeds", "layers", "protected", "writable_exceptions", "prompt_boundary",
    }
    if not isinstance(plan, dict) or set(plan) != required or plan["plan_version"] != 1:
        raise Refused("invalid_turn_plan")
    if plan["session_id"] != session_id or plan["turn_id"] != turn_id:
        raise Refused("turn_plan_owner_mismatch")
    if plan["mode"] not in {"inline", "ask"}:
        raise Refused("invalid_turn_plan")
    if any(not isinstance(plan[key], list) for key in ("seeds", "layers", "protected", "writable_exceptions", "prompt_boundary")):
        raise Refused("invalid_turn_plan")
    canonical = _plan_canonical(plan).encode("utf-8")
    if hashlib.sha256(canonical).hexdigest() != plan["plan_id"]:
        raise Refused("plan_id_mismatch")
    return plan


def create_session(root, workspace, backend, kind, owner, daemon_owner=None, version=None):
    """Create a session row and return its UUID."""
    root_real = _real(root)
    # Canonical workspaces may be external; paths presented under root may not escape it.
    _guard_lexical_escape(root, workspace)
    workspace_real = _real(workspace)
    if not os.path.exists(workspace_real):
        raise OutsideRoot(workspace_real)
    session_id = str(uuid.uuid4())
    session_dir = _inside_root(root_real, os.path.join(root_real, "sessions", session_id))
    row = {
        "schema": "yana-session 1",
        "session_id": session_id,
        "workspace": workspace_real,
        "backend": backend,
        "kind": kind,
        "vendor_session_id": None,
        "owner": owner,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }
    if daemon_owner is not None:
        row["daemon_owner"] = daemon_owner
    if version is not None:
        row["version"] = version
    # ALL OR NOTHING. The session is built in a tmp dir beside its final name and
    # renamed into place as the LAST step, so `sessions/<id>` never exists unless
    # it is complete. Creating the dir first and writing into it published a
    # half-made session on every failure after the mkdir: a burst that exhausted
    # the daemon's fds left 186 empty `sessions/<uuid>/` dirs plus one dir with a
    # COMPLETE session.json whose answer to the client was `internal_error` --
    # durable state for a request that was told it failed.
    parent = os.path.dirname(session_dir)
    _mkdir(parent)
    staging = os.path.join(parent, ".%s.tmp.%s" % (session_id, uuid.uuid4().hex))
    _mkdir(staging)
    try:
        write_json_atomic(os.path.join(staging, "session.json"), row)
        os.rename(staging, session_dir)
        _fsync_dir(parent)
    except BaseException:
        shutil.rmtree(staging, ignore_errors=True)
        raise
    return session_id


def turn_dir(root, session_id, turn_id, cgroup, owner, mounted_root, roots, mode=None, plan=None):
    """Create turn layer dirs and return daemon launch paths.

    `mode` is the per-turn yana mode (ask/inline/agentic/…). Persisted into
    meta.json so recovery can restore confinement without guessing (O8).
    """
    # Validation precedes every allocation below. `plan` stays optional until
    # the turn lifecycle (stage S5) builds one for every turn; a plan that IS
    # supplied is validated completely, and written exactly once.
    if plan is not None:
        plan = validate_turn_plan(plan, session_id, turn_id)
    base = _turn_dir(root, session_id, turn_id)
    plan_path = os.path.join(base, "plan.json")
    if plan is not None:
        if os.path.exists(plan_path):
            raise Refused("turn_plan_exists")
        _mkdir(base)
        write_json_atomic(plan_path, plan)
    workspace_layer = os.path.join(base, "layer")
    _bare_layer(workspace_layer)
    root_layers = {}
    for item in roots:
        key = _path_key(item)
        layer = os.path.join(base, "roots", key)
        _bare_layer(layer)
        root_layers[key] = layer
    _mkdir(os.path.join(base, "private"))
    meta = {
        "state": "running",
        "cgroup": cgroup,
        "owner": owner,
        "mounted_root": _real(mounted_root),
        "roots": [_real(item) for item in roots],
        "mode": mode,
    }
    write_json_atomic(os.path.join(base, "meta.json"), meta)
    return {"turn_dir": base, "layers": {"workspace": workspace_layer, "roots": root_layers}}


def _bare_layer(path):
    _mkdir(os.path.join(path, "upper"))
    _mkdir(os.path.join(path, "work"))


def set_turn_state(root, session_id, turn_id, state, log=None, clear_workdirs=None):
    """Set meta.json state; refuse `unknown_state` before touching the file.

    Ruling 117: any transition away from `running` also eagerly clears this
    turn's overlay `work` dirs -- the bwrap mount namespace that used them
    already died with the confined process by now, so the daemon still KNOWS
    it owns a now-useless mode-000 `work` dir right here, instead of finding
    it later at `delete_session` with no context left. Belt and braces:
    `_force_rmtree`'s chmod-and-retry stays the backstop for a turn that was
    killed, or the daemon crashed, before reaching this call.
    """
    if state not in TURN_STATES:
        raise Refused("unknown_state")
    turn = _turn_dir(root, session_id, turn_id)
    path = os.path.join(turn, "meta.json")
    meta = _read_json(path)
    old = meta.get("state")
    meta["state"] = state
    write_json_atomic(path, meta)
    if log is not None and old != state:
        log.write(
            "DEBUG",
            "turn state session=%s turn=%s from=%s to=%s trigger=%s"
            % (session_id, turn_id, old, state, "set_turn_state"),
        )
    if state != "running":
        (clear_workdirs or _clear_turn_workdirs)(turn, log)


def _clear_turn_workdirs(turn, log=None):
    """Remove the overlay `work` dir under the workspace layer and every root layer.

    Never touches `upper` -- that is the turn's change set, read by review.
    """
    # Test-only delay makes event-loop blocking deterministic.
    delay = os.environ.get("YANAD_TEST_WORKDIR_CLEANUP_DELAY")
    if delay:
        time.sleep(float(delay))
    workdirs = [os.path.join(turn, "layer", "work")]
    roots_dir = os.path.join(turn, "roots")
    if os.path.isdir(roots_dir):
        for name in os.listdir(roots_dir):
            workdirs.append(os.path.join(roots_dir, name, "work"))
    for workdir in workdirs:
        if os.path.lexists(workdir):
            _force_rmtree(workdir, log=log)


def _validated_review_bundle(root, session_id, turn_id, bundle):
    if not isinstance(bundle, list):
        raise Refused("review_unreadable", "bundle is not a list")
    turn = _turn_dir(root, session_id, turn_id)
    allowed_uppers = [os.path.join(turn, "layer", "upper")]
    roots_dir = os.path.join(turn, "roots")
    if os.path.isdir(roots_dir):
        allowed_uppers.extend(
            os.path.join(roots_dir, name, "upper")
            for name in os.listdir(roots_dir)
        )
    required_strings = ("id", "path", "rel", "root", "kind", "base_state", "base_hash")
    kept = []
    for item in bundle:
        if not isinstance(item, dict) or any(not isinstance(item.get(key), str) for key in required_strings):
            raise Refused("review_unreadable", "bundle row has invalid fields")
        if not re.fullmatch(r"[0-9a-f]{64}", item["base_hash"]):
            raise Refused("review_unreadable", "bundle row has invalid base_hash")
        expected = _real(os.path.join(item["root"], item["rel"]))
        if _inside_root(item["root"], item["path"]) != expected:
            raise Refused("review_unreadable", "bundle path does not match root and rel")
        upper_path = item.get("upper_path")
        if item["kind"] != "delete":
            if not isinstance(upper_path, str):
                raise Refused("review_unreadable", "bundle row has no upper_path")
            if not _inside_any(allowed_uppers, upper_path):
                raise Refused("review_unreadable", "bundle upper_path is outside turn layers")
        elif upper_path is not None:
            raise Refused("review_unreadable", "delete bundle row has upper_path")
        home_buffer_only = item.get("home_buffer_only")
        review_before = item.get("review_before")
        if home_buffer_only is not None and home_buffer_only is not True:
            raise Refused("review_unreadable", "bundle row has invalid home_buffer_only marker")
        if home_buffer_only is True and not isinstance(review_before, str):
            raise Refused("review_unreadable", "buffer-only bundle row has no review_before baseline")
        if home_buffer_only is None and review_before is not None:
            raise Refused("review_unreadable", "ordinary bundle row carries a buffer-only baseline")
        kept.append({key: item.get(key) for key in (
            "id", "path", "rel", "root", "root_index", "root_is_primary",
            "kind", "base_state", "base_hash", "base_mode",
            "base_hash_captured_ts", "after_mode", "upper_path",
            "home_buffer_only", "review_before",
        )})
    return kept


def open_review(root, session_id, turn_id, files, tabs, bundle=None):
    session_dir = _session_dir(root, session_id)
    row = _read_json(os.path.join(session_dir, "session.json"))
    bundle = _validated_review_bundle(root, session_id, turn_id, [] if bundle is None else bundle)
    file_paths = [_real(item) for item in files]
    if bundle and {item["path"] for item in bundle} != set(file_paths):
        raise Refused("review_unreadable", "bundle paths do not match review files")
    review_dir = os.path.join(session_dir, "review")
    _mkdir(review_dir)
    now = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime())
    file_rows = ["yana-review-files 1", *file_paths]
    _write_text_atomic(os.path.join(review_dir, "files"), "\n".join(file_rows) + "\n")
    write_json_atomic(os.path.join(review_dir, "tabs.json"), tabs)
    write_json_atomic(os.path.join(review_dir, "bundle.json"), bundle)
    for item in file_paths:
        key = _path_key(item)
        pointer_dir = _inside_root(root, os.path.join(os.fspath(root), "claims", key, "reviews"))
        _mkdir(pointer_dir)
        pointer = {"session_id": session_id, "daemon_owner": row.get("daemon_owner")}
        _write_text_atomic(
            os.path.join(pointer_dir, session_id),
            json.dumps(pointer, sort_keys=True) + "\n",
        )
    # The marker publishes the complete manifest; readers ignore partial files.
    write_json_atomic(os.path.join(review_dir, "open"), {
        "owner": row["owner"],
        "daemon_owner": row.get("daemon_owner"),
        "since": now,
        "turn_id": turn_id,
    })


def close_review(root, session_id):
    _remove_review(root, session_id)


def abort_review(root, session_id):
    _remove_review(root, session_id)


def _remove_review(root, session_id):
    """Remove review/ and every claims/*/reviews/<session_id> pointer; return the pointer paths."""
    shutil.rmtree(os.path.join(_session_dir(root, session_id), "review"), ignore_errors=True)
    claims = _inside_root(root, os.path.join(os.fspath(root), "claims"))
    removed = []
    if not os.path.isdir(claims):
        return removed
    for current, _, files in os.walk(claims):
        if session_id in files and os.path.basename(current) == "reviews":
            pointer = os.path.join(current, session_id)
            os.unlink(pointer)
            removed.append(pointer)
    return removed



# F-CLAIM-KEYS: identity is the ACTUAL path, never a workspace or Git slug.
# Imported lazily because `claims` imports `daemon_store`, and a module-level
# import here would close the cycle.
def _path_key(path):
    from . import claims

    return claims.path_key(path)

def write_claim_row(root, claim_key, row):
    path = _inside_root(root, os.path.join(os.fspath(root), "claims", claim_key, "row.json"))
    write_json_atomic(path, row)


def clear_claim_row(root, claim_key):
    path = _inside_root(root, os.path.join(os.fspath(root), "claims", claim_key, "row.json"))
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass



# Plain `shutil.rmtree` raises PermissionError on it.
#
# That one exception, uncaught, took the whole daemon down during the former
# orphan cleanup. Startup zombie reap now calls this remover only after daemon
# ownership is proven dead (review-lifecycle startup-reap ruling).
#
# So the removal has to be able to clear the mode itself. `onexc` is Python
# 3.12+; `onerror` is the older spelling and both are passed, because the
# daemon must not depend on which one this interpreter has.
#
# That escaped `_retry` uncaught (only `OSError` was caught) into the OUTER `except
# TypeError:` below -- which exists ONLY to detect a Python too old to know the `onexc`
# keyword. So the handler's own failure was misread as "wrong keyword", the whole tree
# was retried from scratch with onerror=, hit the identical TypeError again, uncaught
# this time. Deletion died mid-tree.
#
# Fix: never re-invoke `func` blindly -- retry by PATH instead (recurse into
# a directory, unlink anything else) -- and catch every exception `_retry`
# can raise, not just OSError, so nothing can reach the outer `except
# TypeError:` from in here again. That outer clause is now unambiguous: it
# fires only when THIS interpreter's `shutil.rmtree` itself doesn't accept
# `onexc`, never a handler failure.
def _force_rmtree(path, log=None):
    def _retry(func, failed_path, _exc):
        # Restore owner access on the entry AND its parent -- an unreadable
        # directory blocks the unlink of what is inside it, not just itself.
        for target in (os.path.dirname(failed_path), failed_path):
            try:
                os.chmod(target, 0o700)
            except OSError:
                pass
        try:
            if os.path.isdir(failed_path) and not os.path.islink(failed_path):
                shutil.rmtree(failed_path, onexc=_retry)
            else:
                os.unlink(failed_path)
        except FileNotFoundError:
            pass  # already gone -- another retry step got there first
        except Exception as retry_exc:
            # A genuinely stuck entry (OSError) or a bug of ours (anything
            # else) -- either way this function must never raise. Log it so
            # the daemon says so instead of going silent; see the block
            # comment above for why this must not escape.
            level = "WARN" if isinstance(retry_exc, OSError) else "ERROR"
            if log is not None:
                log.write(
                    level,
                    "_force_rmtree: could not remove %r after chmod retry: %s: %s"
                    % (failed_path, type(retry_exc).__name__, retry_exc),
                )

    try:
        shutil.rmtree(path, onexc=_retry)
    except TypeError:
        shutil.rmtree(path, onerror=lambda f, p, e: _retry(f, p, e))


def delete_session(root, session_id, log=None, cause=None):
    session_dir = _session_dir(root, session_id)
    if not os.path.exists(os.path.join(session_dir, "session.json")):
        raise Refused("unknown_session")
    for current, _, files in os.walk(os.path.join(session_dir, "turns")):
        if "meta.json" not in files:
            continue
        meta = _read_json(os.path.join(current, "meta.json"))
        if meta["state"] == "running":
            raise Refused("turn_running")
        if meta["state"] == "dead_unsealed":
            raise Refused("dead_unsealed")
    removed = [session_dir, *_remove_review(root, session_id)]
    if log is not None:
        log.write(
            "WARN",
            "deleting session=%s path=%s cause=%s"
            % (session_id, session_dir, cause if cause is not None else "delete_session"),
        )
    _force_rmtree(session_dir, log=log)
    return removed


def replay(root):
    rows = Replay()
    root_path = os.fspath(root)
    sessions = os.path.join(root_path, "sessions")
    if os.path.isdir(sessions):
        for name in sorted(os.listdir(sessions)):
            path = os.path.join(sessions, name)
            if not os.path.isdir(path):
                continue
            if name.startswith("."):
                # `.<uuid>.tmp.<hex>` staging (see session_dir): scaffolding,
                # not a session. startup_reap owns its removal.
                continue
            session_json = os.path.join(path, "session.json")
            if not os.path.exists(session_json):
                rows.append(ReplayRow(path, "orphan", "missing_session_json"))
                continue
            rows.append(_classify_session(path, session_json))
    claims = os.path.join(root_path, "claims")
    if os.path.isdir(claims):
        for current, _, files in os.walk(claims):
            if os.path.basename(current) != "reviews":
                continue
            for name in sorted(files):
                path = os.path.join(current, name)
                target = os.path.join(sessions, name)
                if not os.path.exists(os.path.join(target, "session.json")):
                    rows.append(ReplayRow(path, "orphan", "missing_session_folder"))
    return rows


def _classify_session(path, session_json):
    try:
        row = _read_json(session_json)
    except (OSError, ValueError, TypeError) as exc:
        return ReplayRow(path, "orphan", "session_json_unreadable:%s" % exc.__class__.__name__)
    try:
        owner = row["owner"]
        pid = int(owner["pid"])
        boot_id = str(owner["boot_id"])
        start_ticks = int(owner["start_ticks"])
        current_boot_id = _current_boot_id()
        current_start_ticks = _start_ticks(pid)
    except FileNotFoundError:
        return ReplayRow(path, "dead", "owner_pid_absent")
    except Exception as exc:
        return ReplayRow(path, "unknown", "identity_unreadable:%s" % exc.__class__.__name__)
    if boot_id != current_boot_id:
        return ReplayRow(path, "dead", "boot_id_mismatch")
    if current_start_ticks == start_ticks:
        return ReplayRow(path, "live", "owner_identity_matches")
    return ReplayRow(path, "dead", "start_ticks_mismatch")


def _current_boot_id():
    with open("/proc/sys/kernel/random/boot_id", "r", encoding="utf-8") as fh:
        return fh.read().strip()


def _start_ticks(pid):
    with open("/proc/%d/stat" % pid, "r", encoding="utf-8") as fh:
        fields = fh.read().rsplit(")", 1)[1].split()
    return int(fields[19])


def _write_text_atomic(path, text):
    target = os.fspath(path)
    parent = os.path.dirname(target)
    _mkdir(parent)
    tmp = os.path.join(parent, ".%s.tmp.%s" % (os.path.basename(target), uuid.uuid4()))
    try:
        with open(tmp, "w", encoding="utf-8") as fh:
            fh.write(text)
            fh.flush()
            os.fsync(fh.fileno())
        os.replace(tmp, target)
        _fsync_dir(parent)
    except Exception:
        try:
            os.unlink(tmp)
        except OSError:
            pass
        raise
