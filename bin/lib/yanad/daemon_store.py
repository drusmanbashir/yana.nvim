"""U2 daemon API over the authoritative U1 store implementation."""

import hashlib
import os
import time
from pathlib import Path

from . import liveness
from . import store as base


Refused = base.Refused
create_session = base.create_session
turn_dir = base.turn_dir
open_review = base.open_review
close_review = base.close_review
replay = base.replay
atomic_json = base.write_json_atomic
clear_turn_workdirs = base._clear_turn_workdirs


def read_json(path):
    return base._read_json(path)


def load_session(root, session_id):
    path = Path(root) / "sessions" / session_id / "session.json"
    if not path.exists():
        raise Refused("unknown_session")
    return read_json(path)


def _review_files(path):
    lines = path.read_text(encoding="utf-8").splitlines()
    if not lines or lines[0] != "yana-review-files 1":
        raise ValueError("invalid review files header")
    return lines[1:]


def load_recovery(root, session_id):
    session_dir = Path(root) / "sessions" / session_id
    review = session_dir / "review"
    if not (review / "open").exists():
        return None
    try:
        opened = read_json(review / "open")
        turn_id = opened["turn_id"]
        turn_dir = session_dir / "turns" / turn_id
        meta = read_json(turn_dir / "meta.json")
        bundle = read_json(review / "bundle.json")
        tabs = read_json(review / "tabs.json")
        files = _review_files(review / "files")
    except (OSError, KeyError, TypeError, ValueError) as exc:
        raise Refused("review_unreadable", str(exc)) from exc
    if not isinstance(bundle, list) or not bundle:
        raise Refused("review_unreadable", "review bundle is missing or empty")
    root_layers = {}
    roots_dir = turn_dir / "roots"
    if roots_dir.exists():
        root_layers = {path.name: str(path) for path in sorted(roots_dir.iterdir()) if path.is_dir()}
    return {
        "turn_id": turn_id,
        "turn_dir": str(turn_dir),
        "mounted_root": meta.get("mounted_root"),
        "roots": meta.get("roots", []),
        "layers": {"workspace": str(turn_dir / "layer"), "roots": root_layers},
        "files": files,
        "tabs": tabs,
        "bundle": bundle,
    }


def rebind_session(root, session_id, owner):
    session_path = Path(root) / "sessions" / session_id / "session.json"
    session = load_session(root, session_id)
    session["owner"] = owner
    session.pop("dead", None)
    atomic_json(session_path, session)
    return session


def rebind_review(root, session_id, owner, recovery):
    session_dir = Path(root) / "sessions" / session_id
    pointers = sorted((Path(root) / "claims").glob(f"*/reviews/{session_id}"))
    if not pointers:
        raise Refused("review_unreadable", "review claim pointers are missing")
    session = rebind_session(root, session_id, owner)

    opened_path = session_dir / "review" / "open"
    opened = read_json(opened_path)
    opened["owner"] = owner
    atomic_json(opened_path, opened)
    set_turn_state(root, session_id, recovery["turn_id"], "reviewing")

    for pointer in pointers:
        write_claim_row(root, pointer.parent.parent.name, session_id, recovery["turn_id"], "reviewing")
    return session


def set_turn_state(root, session_id, turn_id, state, reason=None, log=None, clear_workdirs=None):
    # Reimplements base.set_turn_state (adds `reason`) rather than calling it,
    # so it carries base's ruling-117 eager work-dir clear itself -- see
    # base._clear_turn_workdirs's docstring for why a transition away from
    # `running` clears the overlay work dirs right here.
    if state not in base.TURN_STATES:
        raise Refused("unknown_state")
    turn_dir = Path(root) / "sessions" / session_id / "turns" / turn_id
    path = turn_dir / "meta.json"
    meta = read_json(path)
    old = meta.get("state")
    meta["state"] = state
    if reason:
        meta["reason"] = reason
    atomic_json(path, meta)
    if log is not None and old != state:
        trigger = reason if reason else "set_turn_state"
        log.write(
            "DEBUG",
            "turn state session=%s turn=%s from=%s to=%s trigger=%s"
            % (session_id, turn_id, old, state, trigger),
        )
    if state != "running":
        (clear_workdirs or clear_turn_workdirs)(str(turn_dir), log)


def write_claim_row(root, claim_key, session_id, turn_id, state):
    session = load_session(root, session_id)
    row = {
        "session_id": session_id,
        "turn_id": turn_id,
        "state": state,
        "since": time.time(),
    }
    if session.get("daemon_owner") is not None:
        row["daemon_owner"] = session["daemon_owner"]
    base.write_claim_row(root, claim_key, row)


def iter_sessions(root, log=None):
    sessions = Path(root) / "sessions"
    if not sessions.exists():
        return []
    rows = []
    # pathlib's `*` DOES match a leading dot, so an in-flight or crashed
    # `sessions/.<uuid>.tmp.<hex>` staging dir would otherwise be listed as a
    # session whose directory name is not its session_id.
    for path in sorted(sessions.glob("*/session.json")):
        if path.parent.name.startswith("."):
            continue
        try:
            rows.append(read_json(path))
        except (OSError, ValueError, TypeError) as exc:
            if log is not None:
                log.write("ERROR", "unreadable session path=%s: %s" % (path, exc))
    return rows


def iter_turns(root, session_id):
    turns = Path(root) / "sessions" / session_id / "turns"
    if not turns.exists():
        return []
    rows = []
    for path in sorted(turns.glob("*/meta.json")):
        row = read_json(path)
        row["turn_id"] = path.parent.name
        rows.append(row)
    return rows


def iter_claims(root):
    claims = Path(root) / "claims"
    if not claims.exists():
        return []
    rows = []
    for path in sorted(claims.glob("*/row.json")):
        row = read_json(path)
        row["key"] = path.parent.name
        rows.append(row)
    return rows


def iter_open_review_holders(root):
    """Synthetic holders from claims/<key>/reviews/<session_id> pointers.

    One row.json per claimed path: a later disjoint launch overwrites the
    active claim row. Open-review pointers stay, so arbitration must still
    see every reviewing session (U5 F1 / U2 disjoint co-holders).
    """
    claims = Path(root) / "claims"
    if not claims.exists():
        return []
    rows = []
    seen = set()
    for pointer in sorted(claims.glob("*/reviews/*")):
        if not pointer.is_file():
            continue
        session_id = pointer.name
        if session_id in seen:
            continue
        if not (Path(root) / "sessions" / session_id / "review" / "open").exists():
            continue
        turn_id = None
        for turn in iter_turns(root, session_id):
            if turn.get("state") == "reviewing":
                turn_id = turn["turn_id"]
                break
        if not turn_id:
            continue
        seen.add(session_id)
        rows.append({
            "key": pointer.parent.parent.name,
            "session_id": session_id,
            "turn_id": turn_id,
            "state": "reviewing",
            "since": 0,
        })
    return rows


def iter_arbitration_holders(root):
    """Claim rows plus open-review pointers, unique by session_id."""
    by_sid = {}
    for row in iter_claims(root):
        by_sid[row["session_id"]] = row
    for row in iter_open_review_holders(root):
        by_sid.setdefault(row["session_id"], row)
    return list(by_sid.values())


def clear_claim_rows(root, session_id):
    for row in iter_claims(root):
        if row["session_id"] == session_id:
            base.clear_claim_row(root, row["key"])


def clear_claim_rows_for_turn(root, session_id, turn_id):
    """Remove launch-index rows owned by one turn."""
    for row in iter_claims(root):
        if row["session_id"] == session_id and row["turn_id"] == turn_id:
            base.clear_claim_row(root, row["key"])


def remove_turn(root, session_id, turn_id, log=None):
    """Remove one already-dead turn and its private overlay layers."""
    path = Path(root) / "sessions" / session_id / "turns" / turn_id
    if path.exists():
        base._force_rmtree(path, log=log)


def delete_session(root, session_id, log=None, cause=None):
    removed = base.delete_session(root, session_id, log=log, cause=cause)
    clear_claim_rows(root, session_id)
    return removed


def _file_sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(65536), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _bundle_row_stale(row):
    """Return (path, reason) when the row cannot restore, else (None, None)."""
    if not isinstance(row, dict):
        return None, None
    path = row.get("path")
    if not isinstance(path, str) or path == "":
        return None, None
    base_state = row.get("base_state")
    expected = row.get("base_hash")
    if base_state == "absent":
        if os.path.lexists(path):
            return path, "base_hash_mismatch"
        return None, None
    if base_state != "file" or not isinstance(expected, str):
        return path, "base_hash_mismatch"
    if not os.path.isfile(path):
        return path, "base_hash_mismatch"
    try:
        actual = _file_sha256(path)
    except OSError:
        return path, "base_hash_mismatch"
    if actual != expected:
        return path, "base_hash_mismatch"
    return None, None


def _log_recovery_pruned(log, path, turn_id, reason):
    """One DEBUG lifecycle line per silent prune: path, turn_id, reason."""
    if log is None:
        return
    log.write(
        "DEBUG",
        "recovery.pruned path=%s turn_id=%s reason=%s" % (path, turn_id, reason),
    )


def prune_stale_recoveries(root, log=None):
    """Drop open reviews that can never restore (hash drift or missing mode).

    Called at status/discovery so the offer list never names a session that
    would only refuse on accept. Silent: no dialog, one DEBUG `recovery.pruned`
    line per deletion.

    The offer list is scoped by R-b to sessions NOT attached to a LIVE Neovim
    (liveness = the daemon's `pidfd`, never a file), so a review whose owning
    editor is still live is never a recovery candidate and is never pruned:
    deleting it would destroy retained proposal bytes the editor still owns.
    A dead or unknown owner prunes exactly as before.
    """
    pruned = []
    for sess in list(iter_sessions(root, log=log)):
        sid = sess["session_id"]
        review_open = (Path(root) / "sessions" / sid / "review" / "open").exists()
        if not review_open:
            continue
        if liveness.owner_kind(sess.get("owner")) == "live":
            continue
        try:
            recovery = load_recovery(root, sid)
        except Refused:
            continue
        if not recovery:
            continue
        turn_id = recovery.get("turn_id")
        try:
            meta = read_json(Path(recovery["turn_dir"]) / "meta.json")
        except (OSError, ValueError, TypeError):
            meta = {}
        mode = meta.get("mode") if isinstance(meta, dict) else None
        if not isinstance(mode, str) or mode == "":
            try:
                delete_session(root, sid, log=log, cause="missing_mode")
            except Refused as exc:
                if log is not None:
                    log.write(
                        "WARN",
                        "stale recovery prune skipped session=%s turn=%s code=%s"
                        % (sid, turn_id, exc.code),
                    )
                continue
            _log_recovery_pruned(log, None, turn_id, "mode_missing")
            pruned.append({
                "session_id": sid,
                "turn_id": turn_id,
                "path": None,
                "reason": "mode_missing",
            })
            continue
        for row in recovery.get("bundle") or []:
            path, reason = _bundle_row_stale(row)
            if reason is None:
                continue
            try:
                delete_session(root, sid, log=log, cause="base_hash_drift")
            except Refused as exc:
                if log is not None:
                    log.write(
                        "WARN",
                        "stale recovery prune skipped session=%s turn=%s code=%s"
                        % (sid, turn_id, exc.code),
                    )
                continue
            _log_recovery_pruned(log, path, turn_id, reason)
            pruned.append({
                "session_id": sid,
                "turn_id": turn_id,
                "path": path,
                "reason": reason,
            })
            break
    return pruned
