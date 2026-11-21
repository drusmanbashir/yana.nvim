"""U2 daemon API over the authoritative U1 store implementation."""

import os
import time
from pathlib import Path

from . import store as base
from .recovery_store import (load_end_record, publish_end_record, abandon_end_record,
                             clear_end_record)


Refused = base.Refused
create_session = base.create_session
turn_dir = base.turn_dir
open_review = base.open_review
close_review = base.close_review
replay = base.replay
atomic_json = base.write_json_atomic
clear_turn_workdirs = base._clear_turn_workdirs
discard_dead_session = base.discard_dead_session


def read_json(path):
    return base._read_json(path)


def run_generation(record):
    """A Turn's run generation (PANEL.md F-ADDENDUM-TURN): the lifecycle pass's,
    never minted here. A meta.json written before generations existed reads as 0."""
    return int(record.get("generation", 0))


def load_session(root, session_id):
    path = Path(root) / "sessions" / session_id / "session.json"
    if not path.exists():
        raise Refused("unknown_session")
    return read_json(path)


def load_recovery(root, session_id):
    """Only a frozen End survives editor death."""
    frozen = load_end_record(root, session_id)
    return {"kind": "frozen_end", "record": frozen} if frozen is not None else None


def rebind_session(root, session_id, owner):
    session_path = Path(root) / "sessions" / session_id / "session.json"
    session = load_session(root, session_id)
    session["owner"] = owner
    session.pop("dead", None)
    atomic_json(session_path, session)
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


def resume_turn(root, session_id, turn_id, owner, cgroup, generation, log=None):
    """PANEL.md F-ADDENDUM-TURN: run `generation` of a reviewing Turn on its own layers.

    Recreates only the disposable overlay work dirs; every upper (the Turn's
    change set), private/ and review/open stay. meta.json names the new writer.
    """
    turn_dir = Path(root) / "sessions" / session_id / "turns" / turn_id
    # A buffer turn has no layer (turn_dir layers=False) and resumes without one.
    has_layer = (turn_dir / "layer").is_dir()
    layers = [turn_dir / "layer"] if has_layer else []
    roots_dir = turn_dir / "roots"
    if roots_dir.is_dir():
        layers.extend(sorted(path for path in roots_dir.iterdir() if path.is_dir()))
    for layer in layers:
        if os.path.lexists(layer / "work"):
            base._force_rmtree(str(layer / "work"), log=log)
        base._bare_layer(str(layer))
    meta = read_json(turn_dir / "meta.json")
    old = meta["state"]
    meta.update({"state": "running", "owner": owner, "cgroup": cgroup, "generation": generation})
    meta.pop("reason", None)
    atomic_json(turn_dir / "meta.json", meta)
    if log is not None:
        log.write("DEBUG", "turn state session=%s turn=%s from=%s to=running trigger=turn.resume generation=%d"
                  % (session_id, turn_id, old, generation))
    if not has_layer:
        return {"turn_dir": str(turn_dir), "layers": None}
    return {
        "turn_dir": str(turn_dir),
        "layers": {"workspace": str(turn_dir / "layer"),
                   "roots": {path.name: str(path) for path in layers[1:]}},
    }


def review_generation(meta):
    """The run whose publication is the open review (review.open records it). It
    stays put when a later resumed launch fails, while `generation` -- every run
    minted so far, monotonic -- never moves back. A meta.json from before the
    field reads as its execution generation."""
    return int(meta["review_generation"]) if "review_generation" in meta else run_generation(meta)


def publish_run(root, session_id, turn_id, generation):
    path = Path(root) / "sessions" / session_id / "turns" / turn_id / "meta.json"
    meta = read_json(path)
    meta["review_generation"] = generation
    atomic_json(path, meta)


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
