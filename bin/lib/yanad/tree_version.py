"""The one reader of this tree's VERSION stamp.

Absence is a value, not a fault. The plugin's client has always read a missing
VERSION as the empty string (`lua/yana/runtime/yanad.lua`), so a daemon that raised on
the same file disagreed with its own client about what the tree's version is.
The disagreement was fatal in both directions: the constructor's uncaught
OSError meant no socket was ever bound, so every `ensure` retry failed and the
operator saw `no_daemon` naming nothing; and `version_changed` reading absence
as "changed" made an already-running daemon exit for a file that had merely
gone missing for a moment -- mid-checkout, mid-rebase, or under a peer wiping
the shared worktree.

Reading absence the same way the client does keeps the staleness rule intact --
a VERSION that really changes still retires the daemon -- while a tree with no
readable VERSION runs a daemon on "" that its clients can talk to.
"""

PATH = "VERSION"


def read(repo):
    """Return the stripped VERSION text of `repo`, or "" if it cannot be read."""
    try:
        return (repo / PATH).read_text(encoding="utf-8").strip()
    except (OSError, UnicodeDecodeError):
        return ""
