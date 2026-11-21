"""Independent frozen End recovery records."""

from pathlib import Path

from . import store


def _session(root, sid):  #AI
    path = Path(store._session_dir(root, sid))
    if not (path / "session.json").exists():
        raise store.Refused("unknown_session")
    return path


def load_end_record(root, sid):  #AI
    path = _session(root, sid) / "partial-end.json"
    return store._read_json(path) if path.exists() else None


def _require(condition):  #AI
    if not condition:
        raise ValueError("invalid recovery fields")


def _shape(record):  #AI
    try:
        _require(type(record["schema"]) is int and record["schema"] == 1)
        _require(isinstance(record["turn_id"], str) and record["turn_id"])
        _require(isinstance(record["plan_id"], str) and record["plan_id"])
        items, outcomes = record["plan"]["items"], record["outcomes"]
        _require(isinstance(items, list) and isinstance(outcomes, list))
        _require([row["path"] for row in items] == [row["path"] for row in outcomes])
        _require(len({row["path"] for row in items}) == len(items))
        for row in outcomes:
            _require(isinstance(row["path"], str))
            _require(row["state"] in {"not_started", "failed", "committed", "abandoned"})
            _require(isinstance(row["retry_identity"], (str, dict)) and row["retry_identity"])
            _require(row["receipt"] is None or isinstance(row["receipt"], dict))
            _require(row["reason"] is None or isinstance(row["reason"], str))
    except (ValueError, KeyError, TypeError) as exc:
        raise store.Refused("invalid_recovery_record") from exc


def publish_end_record(root, sid, record):  #AI
    _shape(record)
    previous = load_end_record(root, sid)
    if previous == record:
        return record
    if any(row["state"] == "abandoned" for row in record["outcomes"]):
        raise store.Refused("abandonment_requires_confirmation")
    if previous:
        for key in ("turn_id", "plan_id", "plan"):
            if previous[key] != record[key]:
                raise store.Refused("frozen_plan_changed")
        ranks = {"not_started": 0, "failed": 1, "committed": 2}
        for old, new in zip(previous["outcomes"], record["outcomes"]):
            if old["state"] == "abandoned" or ranks[new["state"]] < ranks[old["state"]]:
                raise store.Refused("recovery_state_regressed")
            if old["retry_identity"] != new["retry_identity"]:
                raise store.Refused("retry_identity_changed")
            if old["receipt"] is not None and old["receipt"] != new["receipt"]:
                raise store.Refused("settlement_receipt_changed")
            if old["state"] == "committed" and old != new:
                raise store.Refused("committed_outcome_changed")
    store.write_json_atomic(_session(root, sid) / "partial-end.json", record)
    return record


def _matching(root, sid, plan_id):  #AI
    record = load_end_record(root, sid)
    if record is None or record["plan_id"] != plan_id:
        raise store.Refused("unknown_end_plan")
    return record


def abandon_end_record(root, sid, plan_id, confirmed):  #AI
    if confirmed is not True:
        raise store.Refused("abandonment_requires_confirmation")
    record = _matching(root, sid, plan_id)
    for row in record["outcomes"]:
        if row["state"] != "committed":
            row["state"] = "abandoned"
    store.write_json_atomic(_session(root, sid) / "partial-end.json", record)
    return record


def clear_end_record(root, sid, plan_id):  #AI
    record = _matching(root, sid, plan_id)
    if any(row["state"] not in {"committed", "abandoned"} for row in record["outcomes"]):
        raise store.Refused("end_recovery_pending")
    path = _session(root, sid) / "partial-end.json"
    path.unlink()
    store._fsync_dir(str(path.parent))
