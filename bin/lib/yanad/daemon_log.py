"""Small durable logger owned by one yanad state root."""

import os
import time
from pathlib import Path


LEVELS = {"debug": 10, "info": 20, "warn": 30, "error": 40}
NAMES = {value: name.upper() for name, value in LEVELS.items()}


def canonical_level(value):
    name = str(value).strip().lower()
    if name == "warning":
        name = "warn"
    if name not in LEVELS:
        raise ValueError(
            "invalid log level %r -- valid levels: debug, error, info, warn" % value
        )
    return name


class DaemonLogger:
    """Write records at or above a closed-set severity floor."""

    def __init__(self, path, level=None):
        self.path = Path(path)
        if level is None:
            level = os.environ.get("YANA_LOG_LEVEL")
        if level is None:
            level = os.environ.get("YANAD_LOG_LEVEL")
        self.set_level(level or "info")

    def set_level(self, level):
        self.level = canonical_level(level)

    def write(self, level, message):
        name = canonical_level(level)
        if LEVELS[name] < LEVELS[self.level]:
            return True
        line = "%s [%-5s] %s\n" % (
            time.strftime("%Y-%m-%d %H:%M:%S"),
            NAMES[LEVELS[name]],
            str(message).replace("\n", "\n    "),
        )
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            with self.path.open("a", encoding="utf-8") as stream:
                stream.write(line)
                stream.flush()
                # Flush, do not fsync -- EXCEPT at ERROR. The log is diagnostic,
                # not a durability contract: the replay contract lives in the
                # journal (see journal.py's header), and a DEBUG/INFO/WARN line
                # that loses its last page in a crash costs a reader nothing.
                # An fsync here cost 25-45 ms on rotational ext4 PER LINE, on the
                # event loop, for every request the daemon served. ERROR lines
                # are the ones a post-mortem actually needs and are rare enough
                # that their sync never lands on a hot path.
                if LEVELS[name] >= LEVELS["error"]:
                    os.fsync(stream.fileno())
        except OSError:
            return False
        return True
