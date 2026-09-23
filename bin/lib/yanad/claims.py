import hashlib
import os
from pathlib import Path

from . import daemon_store as store
from . import liveness


# F-CLAIM-KEYS. State identity is (session, turn) plus the ACTUAL path, never a
# derived workspace or repository name.
#
# What this replaces: a key built by walking up from each touched file to the
# nearest `.git` and hashing that directory's (dev, ino). Three things were
# wrong with it. It made identity depend on Git, so one tree keyed differently
# before and after `git init`. It walked the filesystem per item on a path that
# must not walk. And -- measurably -- it COLLIDED: two declared roots inside one
# repository resolved to the same ancestor and therefore to one key, so
# `store.turn_dir` handed them a single shared layer directory instead of one
# each. That is a cross-root bleed the multiroot gate's own premise forbids.
#
# The key is now the real path itself, hashed only to make a safe directory
# name. Distinct paths are distinct keys; no ancestor is consulted; no Git.
def path_key(path):
    """Stable directory-safe key for one absolute path. No Git, no ancestor walk."""
    real = os.path.realpath(os.fspath(path))
    return hashlib.sha256(real.encode("utf-8")).hexdigest()[:16]


def claim_keys(touched):
    return {path_key(item) for item in touched}


def review_files(root, session_id):
    path = Path(root) / "sessions" / session_id / "review" / "files"
    lines = path.read_text().splitlines()
    if not lines or lines[0] != "yana-review-files 1":
        raise ValueError("bad review files schema")
    return lines[1:]


def path_is_within(path, root):
    try:
        Path(path).resolve().relative_to(Path(root).resolve())
        return True
    except ValueError:
        return False


# Claims are per FILE, never per workspace: a claim refuses a FILE under another
# session's open review (the same path or one inside it). Reads, ask turns and an
# agent inside its own overlay never claim; an empty touched set takes no claim;
# `file.claim` arbitrates per file at accept.
def intersects(touched, files):
    candidates = {str(Path(p).resolve()) for p in touched}
    for item in files:
        real = str(Path(item).resolve())
        if real in candidates:
            return True
        for cand in candidates:
            if path_is_within(cand, real) or path_is_within(real, cand):
                return True
    return False


def editor(root, session):
    owner = session.get("owner") or {}
    out = dict(owner)
    out["cwd"] = liveness.cwd_for(owner.get("pid", 0), session.get("workspace"))
    return out


def refusal_for(root, holder, touched):
    session = store.load_session(root, holder["session_id"])
    review = Path(root) / "sessions" / holder["session_id"] / "review" / "open"
    if review.exists():
        try:
            files = review_files(root, holder["session_id"])
        except (OSError, ValueError) as exc:
            return "review_unreadable", {"session_id": holder["session_id"], "editor": editor(root, session), "files": [], "reason": str(exc)}
        if not intersects(touched, files):
            return None, None
        return "review_open", {"session_id": holder["session_id"], "editor": editor(root, session), "files": files, "reason": None}
    return None, None
