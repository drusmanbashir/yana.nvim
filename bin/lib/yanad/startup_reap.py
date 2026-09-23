"""One-shot startup reap for sessions whose editor owner is dead.

The candidate tuple is frozen before any ownership decision.  Nothing created
after `_candidates()` returns can enter this daemon lifetime's reap.
"""

import json
import os
import stat
from pathlib import Path

from . import journal
from . import liveness
from . import store as base_store


def is_staging_name(name):
    """True for store.session_dir's staging name `.<uuid>.tmp.<hex>`.

    Session dirs are named by their uuid and never start with a dot, so every
    dot name under `sessions/` is store scaffolding, not a session.
    """
    return name.startswith(".")


def _identity(path):
    try:
        row = path.stat(follow_symlinks=False)
    except OSError:
        return None
    return row.st_dev, row.st_ino


def _same_candidate(path, identity):
    return identity is not None and _identity(path) == identity


def _claim_candidates(root):
    claims = Path(root) / "claims"
    if not claims.exists():
        return ()
    paths = [*claims.glob("*/row.json"), *claims.glob("*/reviews/*")]
    candidates = []
    for path in sorted(paths):
        identity = _identity(path)
        if identity is None:
            continue
        session_id = None
        if path.name == "row.json":
            try:
                session_id = json.loads(path.read_text(encoding="utf-8")).get("session_id")
            except (OSError, AttributeError, TypeError, ValueError):
                pass
        elif path.parent.name == "reviews":
            session_id = path.name
        candidates.append((path, identity, session_id))
    return tuple(candidates)


def _journal_candidates(root):
    journal = Path(root) / "journal"
    if not journal.exists():
        return ()
    return tuple((path, _identity(path)) for path in sorted(journal.glob("*.ndjson")))


def _candidates(root, log):
    sessions = Path(root) / "sessions"
    try:
        entries = tuple(sorted(sessions.iterdir())) if sessions.exists() else ()
    except OSError as exc:
        log.write(
            "WARN",
            "zombie_reap outcome=keep code=zombie_candidate_set_unreadable "
            "path=%s error=%s" % (sessions, type(exc).__name__),
        )
        entries = ()
    session_candidates = []
    staging_candidates = []
    for path in entries:
        identity = _identity(path)
        if identity is None:
            continue
        try:
            mode = path.stat(follow_symlinks=False).st_mode
        except OSError:
            continue
        if not stat.S_ISDIR(mode):
            log.write(
                "WARN",
                "zombie_reap outcome=keep code=zombie_candidate_not_directory path=%s" % path,
            )
            continue
        if is_staging_name(path.name):
            # `sessions/.<uuid>.tmp.<hex>` is store.session_dir's all-or-nothing
            # staging area, never a session. A kill -9 between its mkdir and the
            # session.json write left one with no owner to prove dead, so the
            # zombie pass kept it (zombie_session_missing) at every start for
            # ever. It is reaped on its own terms below.
            staging_candidates.append((path, identity))
            continue
        session_candidates.append((path, identity))
    return (tuple(session_candidates), _claim_candidates(root), _journal_candidates(root),
            tuple(staging_candidates))


def _read_owner(session_path):
    session_json = session_path / "session.json"
    try:
        row = json.loads(session_json.read_text(encoding="utf-8"))
    except FileNotFoundError:
        return None, "zombie_session_missing", session_json, None
    except (OSError, TypeError, ValueError):
        return None, "zombie_session_unreadable", session_json, None
    if not isinstance(row, dict) or "owner" not in row:
        return None, "zombie_owner_missing", session_json, None
    # Session lifetime belongs to the editor, not the daemon that happened to
    # write this row. A daemon restart must therefore not make a live editor's
    # session look like a dead artefact.
    owner = row.get("owner")
    if owner is None:
        return None, "zombie_owner_missing", session_json, row.get("version")
    try:
        pid = int(owner["pid"])
        start = int(owner["start_ticks"])
        boot = str(owner["boot_id"])
        if pid <= 0 or start < 0 or not boot:
            raise ValueError("invalid editor owner")
    except (KeyError, TypeError, ValueError):
        return None, "zombie_owner_unreadable", session_json, row.get("version")
    return {"pid": pid, "boot_id": boot, "start_ticks": start}, None, session_json, row.get("version")


def _same_owner(left, right):
    return all(left.get(key) == right.get(key) for key in ("pid", "boot_id", "start_ticks"))


def _journal_owner(path):
    try:
        # complete_lines drops a torn last line: a kill -9 mid-write leaves one,
        # and treating that as "unreadable" pinned the dead epoch's journal here
        # for ever, since an unreadable owner is never provably dead.
        rows = [json.loads(line)
                for line in journal.complete_lines(path.read_text(encoding="utf-8"))[0]]
    except (OSError, TypeError, ValueError):
        return None, "zombie_journal_unreadable"
    if not rows or any(not isinstance(row, dict) for row in rows):
        return None, "zombie_journal_unreadable"
    owners = [row.get("daemon_owner") for row in rows]
    if not owners or any(owner is None for owner in owners):
        return None, "zombie_journal_owner_missing"
    first = owners[0]
    if any(owner != first for owner in owners[1:]):
        return None, "zombie_journal_owner_unreadable"
    try:
        owner = {
            "pid": int(first["pid"]),
            "boot_id": str(first["boot_id"]),
            "start_ticks": int(first["start_ticks"]),
        }
        if owner["pid"] <= 0 or owner["start_ticks"] < 0 or not owner["boot_id"]:
            raise ValueError("invalid journal owner")
    except (KeyError, TypeError, ValueError):
        return None, "zombie_journal_owner_unreadable"
    return owner, None


def _log_keep(log, code, path, owner=None):
    suffix = ""
    if owner is not None:
        suffix = " owner_pid=%s owner_start_ticks=%s" % (owner["pid"], owner["start_ticks"])
    level = "INFO" if code in {"zombie_owner_current", "zombie_owner_live"} else "WARN"
    log.write(level, "zombie_reap outcome=keep code=%s path=%s%s" % (code, path, suffix))


def _remove_claim_candidates(claim_candidates, session_id, log):
    for path, identity, owner_session_id in claim_candidates:
        if owner_session_id != session_id or not _same_candidate(path, identity):
            continue
        try:
            path.unlink()
        except FileNotFoundError:
            continue
        except OSError as exc:
            log.write(
                "WARN",
                "zombie_reap outcome=keep code=zombie_claim_delete_failed "
                "path=%s error=%s" % (path, type(exc).__name__),
            )
            continue
        for parent in (path.parent, path.parent.parent):
            try:
                parent.rmdir()
            except OSError:
                pass


def _reap_journals(journal_candidates, current_owner, log, outcomes):
    for path, identity in journal_candidates:
        if not _same_candidate(path, identity):
            _log_keep(log, "zombie_candidate_changed", path)
            outcomes.append((str(path), "keep", "zombie_candidate_changed"))
            continue
        owner, code = _journal_owner(path)
        if code is not None:
            _log_keep(log, code, path)
            outcomes.append((str(path), "keep", code))
            continue
        if _same_owner(owner, current_owner):
            code = "zombie_owner_current"
            _log_keep(log, code, path, owner)
            outcomes.append((str(path), "keep", code))
            continue
        # NO liveness read here. THE LOCK is the proof: this reap runs only
        # after `server.start` has taken `yanad.lock` exclusively (server.py),
        # and a live daemon on this root would be holding it. So a journal in
        # THIS root whose owner is not us belongs to a predecessor that is
        # already past its last fd -- by construction, not by inference.
        #
        # Inference is what kept failing. /proc/<pid> outlives the fds that
        # released the lock: first as a task still running do_exit, then as a
        # ZOMBIE until its parent waits. Both read `live` off a matching
        # start_ticks, and each one made a successor KEEP its predecessor's
        # journal -- the zombie window 2-3 times per suite run, the do_exit
        # window 1-2 times per 20 handovers even after zombies were ruled dead.
        # Sessions and claims still go through liveness: their owners are
        # EDITORS, which hold no lock of ours and can genuinely be alive.
        kind = liveness.owner_kind(owner)
        if kind == "live":
            log.write(
                "INFO",
                "zombie_reap outcome=delete code=zombie_owner_exiting path=%s owner_pid=%s "
                "(identity still readable, but this daemon holds the root lock)"
                % (path, owner.get("pid")),
            )
        try:
            path.unlink()
        except OSError as exc:
            code = "zombie_journal_delete_failed"
            log.write(
                "ERROR",
                "zombie_reap outcome=keep code=%s path=%s error=%s"
                % (code, path, type(exc).__name__),
            )
            outcomes.append((str(path), "keep", code))
            continue
        log.write(
            "INFO",
            "zombie_reap outcome=delete code=zombie_owner_dead path=%s "
            "owner_pid=%s owner_start_ticks=%s"
            % (path, owner["pid"], owner["start_ticks"]),
        )
        outcomes.append((str(path), "delete", "zombie_owner_dead"))


def _reap_staging(staging_candidates, current_owner, log, outcomes):
    """Delete leftover `sessions/.<uuid>.tmp.<hex>` staging dirs.

    This runs under the root's exclusive `yanad.lock`, so no other daemon is
    mid-create here: a staging dir with no session.json is a crash remnant with
    nothing to own, and one whose written owner is dead belongs to a dead epoch.
    """
    for path, identity in staging_candidates:
        if not _same_candidate(path, identity):
            _log_keep(log, "zombie_candidate_changed", path)
            outcomes.append((str(path), "keep", "zombie_candidate_changed"))
            continue
        owner, code, _owner_path, _version = _read_owner(path)
        if code == "zombie_session_missing":
            reason = "zombie_staging_incomplete"
        elif code is not None:
            reason = "zombie_staging_unreadable"
        elif _same_owner(owner, current_owner):
            _log_keep(log, "zombie_owner_current", path, owner)
            outcomes.append((str(path), "keep", "zombie_owner_current"))
            continue
        elif liveness.owner_kind(owner) == "live":
            _log_keep(log, "zombie_owner_live", path, owner)
            outcomes.append((str(path), "keep", "zombie_owner_live"))
            continue
        else:
            reason = "zombie_staging_owner_dead"
        try:
            base_store._force_rmtree(path, log=log)
            if os.path.lexists(path):
                raise OSError("staging tree remains after removal")
        except Exception as exc:
            log.write(
                "ERROR",
                "zombie_reap outcome=keep code=zombie_staging_delete_failed path=%s error=%s"
                % (path, type(exc).__name__),
            )
            outcomes.append((str(path), "keep", "zombie_staging_delete_failed"))
            continue
        log.write("INFO", "zombie_reap outcome=delete code=%s path=%s" % (reason, path))
        outcomes.append((str(path), "delete", reason))


def reap(root, current_owner, log, version=None):
    """Delete dead-editor sessions and records from older release epochs."""
    (session_candidates, claim_candidates, journal_candidates,
     staging_candidates) = _candidates(root, log)
    outcomes = []
    for session_path, identity in session_candidates:
        if not _same_candidate(session_path, identity):
            _log_keep(log, "zombie_candidate_changed", session_path)
            outcomes.append((str(session_path), "keep", "zombie_candidate_changed"))
            continue
        owner, code, owner_path, session_version = _read_owner(session_path)
        if code is not None:
            _log_keep(log, code, owner_path)
            outcomes.append((str(session_path), "keep", code))
            continue
        if version is not None and session_version != version:
            try:
                base_store._force_rmtree(session_path, log=log)
                if os.path.lexists(session_path):
                    raise OSError("session tree remains after epoch removal")
            except Exception as exc:
                code = "zombie_epoch_delete_failed"
                log.write(
                    "ERROR",
                    "zombie_reap outcome=keep code=%s path=%s error=%s"
                    % (code, session_path, type(exc).__name__),
                )
                outcomes.append((str(session_path), "keep", code))
                continue
            _remove_claim_candidates(claim_candidates, session_path.name, log)
            log.write(
                "INFO",
                "zombie_reap outcome=delete code=zombie_version_epoch path=%s"
                % session_path,
            )
            outcomes.append((str(session_path), "delete", "zombie_version_epoch"))
            continue
        if _same_owner(owner, current_owner):
            code = "zombie_owner_current"
            _log_keep(log, code, owner_path, owner)
            outcomes.append((str(session_path), "keep", code))
            continue
        kind = liveness.owner_kind(owner)
        if kind != "dead":
            code = "zombie_owner_live" if kind == "live" else "zombie_owner_unreadable"
            _log_keep(log, code, owner_path, owner)
            outcomes.append((str(session_path), "keep", code))
            continue
        try:
            base_store._force_rmtree(session_path, log=log)
            if os.path.lexists(session_path):
                raise OSError("session tree remains after removal")
        except Exception as exc:
            code = "zombie_session_delete_failed"
            log.write(
                "ERROR",
                "zombie_reap outcome=keep code=%s path=%s error=%s"
                % (code, session_path, type(exc).__name__),
            )
            outcomes.append((str(session_path), "keep", code))
            continue
        _remove_claim_candidates(claim_candidates, session_path.name, log)
        log.write(
            "INFO",
            "zombie_reap outcome=delete code=zombie_owner_dead path=%s "
            "owner_pid=%s owner_start_ticks=%s"
            % (session_path, owner["pid"], owner["start_ticks"]),
        )
        outcomes.append((str(session_path), "delete", "zombie_owner_dead"))
    _reap_staging(staging_candidates, current_owner, log, outcomes)
    _reap_journals(journal_candidates, current_owner, log, outcomes)
    return outcomes
