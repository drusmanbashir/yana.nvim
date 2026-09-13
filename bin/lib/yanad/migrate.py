"""One-way legacy layers/turns/claims migration (U5 step 5)."""

from __future__ import annotations

import json
import shutil
import time
import uuid
from pathlib import Path

from . import store


def _log(root: Path, message: str) -> None:
    path = root / "yanad.log"
    path.parent.mkdir(parents=True, exist_ok=True)
    with path.open("a", encoding="utf-8") as stream:
        stream.write(f"{time.strftime('%Y-%m-%dT%H:%M:%SZ', time.gmtime())} {message}\n")


def _legacy_session_id(root: Path, turn_id: str) -> str:  #AI U5 step 5
    """Return stable legacy session UUID used to resume a partial move."""
    value = uuid.uuid5(uuid.NAMESPACE_URL, f"yana-legacy:{root}:{turn_id}")
    return f"legacy-{value}"


def _session_row(root: Path, session_id: str) -> dict:
    return {
        "schema": "yana-session 1",
        "session_id": session_id,
        "workspace": str(root),
        "backend": "legacy",
        "kind": "legacy",
        "vendor_session_id": None,
        "owner": None,
        "created": time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime()),
    }


def _prepare_session(root: Path, session_id: str) -> Path | None:  #AI U5 step 5
    """Create legacy session or validate deterministic partial session."""
    session_dir = root / "sessions" / session_id
    row_path = session_dir / "session.json"
    if session_dir.exists():
        if not row_path.is_file():
            return None
        try:
            row = json.loads(row_path.read_text(encoding="utf-8"))
            valid = row["session_id"] == session_id and row["kind"] == "legacy"
        except (OSError, UnicodeError, json.JSONDecodeError, KeyError, TypeError):
            return None
        if not valid:
            return None
        return session_dir
    session_dir.mkdir(parents=True)
    store.write_json_atomic(row_path, _session_row(root, session_id))
    return session_dir


def _write_turn_meta(root: Path, turn_dir: Path) -> None:
    meta = turn_dir / "meta.json"
    if meta.exists():
        return
    store.write_json_atomic(
        meta,
        {
            "state": "closed",
            "cgroup": "",
            "owner": None,
            "mounted_root": str(root),
            "roots": [],
            "migrated_from": "legacy",
        },
    )


def _log_move(root: Path, source: Path, destination: Path) -> None:
    _log(root, f"move source={source} destination={destination}")


def _remove_empty(path: Path) -> None:
    try:
        path.rmdir()
    except OSError:
        pass


def _migrate_pair(root: Path, turn_id: str) -> bool:  #AI U5 step 5
    """Move one valid pair, including resuming after its first move."""
    source_layer = root / "layers" / turn_id
    source_turn = root / "turns" / turn_id
    session_id = _legacy_session_id(root, turn_id)
    session_dir = root / "sessions" / session_id
    destination_turn = session_dir / "turns" / turn_id
    destination_layer = destination_turn / "layer"

    source_layer_exists = source_layer.is_dir()
    source_turn_exists = source_turn.is_dir()
    destination_turn_exists = destination_turn.is_dir()
    destination_layer_exists = destination_layer.is_dir()
    normal = source_layer_exists and source_turn_exists and not destination_turn_exists
    resumable = (
        source_layer_exists
        and not source_turn_exists
        and destination_turn_exists
        and not destination_layer_exists
    )
    if not normal and not resumable:
        return False
    if normal and (source_turn / "layer").exists():
        return False

    session_dir = _prepare_session(root, session_id)
    if session_dir is None:
        return False
    destination_turn = session_dir / "turns" / turn_id
    if normal:
        destination_turn.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(str(source_turn), str(destination_turn))
        _log_move(root, source_turn, destination_turn)

    _write_turn_meta(root, destination_turn)
    destination_layer = destination_turn / "layer"
    shutil.move(str(source_layer), str(destination_layer))
    _log_move(root, source_layer, destination_layer)
    _remove_empty(root / "layers")
    _remove_empty(root / "turns")
    return True


def _migrate_flat_pairs(root: Path) -> int:
    layers = root / "layers"
    if not layers.is_dir():
        return 0
    turn_ids = sorted(path.name for path in layers.iterdir() if path.is_dir())
    return sum(_migrate_pair(root, turn_id) for turn_id in turn_ids)


def _purge_legacy_claim_files(root: Path) -> int:
    claims = root / "claims"
    if not claims.is_dir():
        return 0
    count = 0
    paths = sorted(claims.rglob("*"), key=lambda path: (len(path.parts), str(path)), reverse=True)
    for path in paths:
        if path.is_dir():
            _remove_empty(path)
            continue
        rel = path.relative_to(claims)
        parts = rel.parts
        if path.name == "row.json":
            continue
        if len(parts) >= 2 and parts[1] == "reviews":
            continue
        path.unlink()
        _log(root, f"claim-remove path={path} reason=legacy-claim")
        count += 1
    return count


def migrate_legacy(root) -> dict:  #AI U5 step 5
    """Move complete legacy pairs and purge claim sidecars; retry safely."""
    root = Path(root).resolve()
    moved = _migrate_flat_pairs(root)
    purged = _purge_legacy_claim_files(root)
    if moved or purged:
        _log(root, f"migrate-done moved={moved} purged_claims={purged}")
    return {"moved": moved, "purged_claims": purged}
