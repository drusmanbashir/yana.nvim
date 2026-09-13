"""Answer journal for one yanad epoch.

DURABILITY INVARIANT: a request whose answer the client has SEEN is already on
disk. `append` returns only after this frame's line has been fsync'd, and
`server.serve_frame` awaits it before `self.write` -- that ordering is what
lets a re-sent id be answered from the window instead of dispatched twice.
Replay spans one daemon LIFETIME, not a restart: `_replay` keeps only rows
whose `daemon_owner` is this daemon's identity, so a successor pid never
re-serves a dead epoch's answers.

EXACTLY-ONCE INVARIANT: `claim` reserves (owner, id) on the loop thread BEFORE
the caller's first await. Since `append` now yields to an executor -- and
`session.create` yields again inside dispatch -- a plain "is it in the window?"
read would miss an id that is mid-sync, and the product's own client re-sends
the SAME frame on a fresh connection after its 2.0 s socket timeout
(client.py exchange/request). The reservation is an unresolved Future: the
second arrival awaits it and gets the first arrival's answer, so one id is
dispatched once and journaled once.

THREADING INVARIANT: ONLY the blocking write+fsync runs in the loop's default
executor. Every piece of in-memory state (`seq`, `window`) is read and written
on the event-loop thread alone, so the daemon keeps single-threaded ownership
of its state while one frame is syncing and other connections keep being
served. The executor thread is handed an immutable `str` and nothing else.

FSYNC BUDGET: GROUP COMMIT. One fsync per BATCH, not per frame. `append`
queues its line and awaits a waiter; a single `_commit_loop` task drains every
line queued since the last sync into ONE write(2) and ONE fsync, then resolves
every waiter in that batch. A burst of N concurrent creates therefore costs
ceil(N / batch) fsync pairs instead of N: on this box's rotational ext4 one
pair is 25-45 ms, so 72 serialised pairs were 2.1-2.8 s at the 95th percentile -- past the
product client's own 2.0 s socket timeout (client.py), which made every client
in the burst re-send. The durability contract is UNCHANGED: a waiter is
resolved only after the fsync that carried its line returned, so an answer the
client SAW is still on disk before it was sent.

The journal directory is fsync'd exactly once, at open, after the epoch file's
dirent exists -- so the file can never lose its name, and no later batch pays
for a second (25-45 ms on rotational ext4) directory sync.

TORN TAIL: a `kill -9` mid-write can leave the LAST line without its trailing
newline. That line was never fsync'd, so no client ever saw its answer; every
reader (`_replay` here, the gate's checker, tests/lib/yanad_fsync_probe.py)
drops a final newline-less line and logs it, and none of them raises.
"""

import asyncio
import json
import os
import time
from pathlib import Path


class Journal:
    def __init__(self, root, daemon_owner):
        self.root = Path(root)
        self.daemon_owner = daemon_owner
        self.epoch = "%s-%s" % (time.time_ns(), daemon_owner["pid"])
        self.dir = self.root / "journal"
        self.dir.mkdir(parents=True, exist_ok=True)
        self.path = self.dir / f"{self.epoch}.ndjson"
        self.seq = 0
        self.window = {}
        # Group commit: lines queued since the last fsync, and the waiter that
        # each queuing `append` is parked on. Touched on the loop thread only.
        self._pending = []
        self._waiters = []
        self._committer = None
        self.torn_tail = 0
        self.batches = 0
        self.batched_lines = 0
        self._replay()
        # Link the epoch file, then sync the directory ONCE: every later append
        # fsyncs only the file, because the dirent it needs is already durable.
        self.path.touch()
        _fsync_dir(self.dir)
        # ONE fd for the daemon's whole life. Opening per write cost an fd on
        # top of every client socket, and a daemon started with the default
        # RLIMIT_NOFILE of 1024 hit EMFILE at 600 concurrent creates: the journal
        # open raised inside the executor, the span died between its session dir
        # and its row, and 396 of 600 dirs went unjournaled. Nothing about the
        # journal ever needed a second fd.
        self.fd = os.open(self.path, os.O_WRONLY | os.O_APPEND | os.O_CREAT, 0o600)

    def _key(self, owner, frame_id):
        return (int(owner["pid"]), owner["boot_id"], int(owner["start_ticks"]), frame_id)

    def _replay(self):
        for path in sorted(self.dir.glob("*.ndjson")):
            try:
                text = path.read_text()
            except OSError:
                continue
            lines, torn = complete_lines(text)
            if torn:
                self.torn_tail += 1
            for line in lines:
                if not line:
                    continue
                try:
                    row = json.loads(line)
                    if row.get("daemon_owner") != self.daemon_owner:
                        continue
                except (AttributeError, TypeError, ValueError):
                    continue
                self.seq = max(self.seq, int(row["seq"]))
                self.window[self._key(row["owner"], row["id"])] = row["answer"]

    def stored(self, owner, frame_id):
        """The durable answer for this key, or None. A reservation is not one."""
        entry = self.window.get(self._key(owner, frame_id))
        if isinstance(entry, asyncio.Future):
            return None
        return entry

    def claim(self, owner, frame_id):
        """Loop thread, before any await. Returns (answer, pending).

        (answer, None) -- this id already has a durable answer: replay it.
        (None, future) -- another connection owns this id right now: await the
                          future, which resolves to that answer (or to None if
                          the owner never got one).
        (None, None)   -- the caller now OWNS this id and MUST finish it with
                          `append` or release it with `abandon`.
        """
        key = self._key(owner, frame_id)
        entry = self.window.get(key)
        if isinstance(entry, asyncio.Future):
            return None, entry
        if entry is not None:
            return entry, None
        self.window[key] = asyncio.get_running_loop().create_future()
        return None, None

    def abandon(self, owner, frame_id):
        """Release a reservation that produced no answer; wake any waiter."""
        key = self._key(owner, frame_id)
        entry = self.window.get(key)
        if not isinstance(entry, asyncio.Future):
            # Already durable (the span journaled, then its writer was
            # cancelled): the answer stays in the window, or a re-send of an id
            # this daemon HAS answered would be dispatched a second time.
            return
        self.window.pop(key, None)
        if not entry.done():
            entry.set_result(None)

    async def append(self, owner, frame, answer):
        """Make this answer durable, then publish it. Awaited before the write."""
        self.seq += 1
        row = {
            "seq": self.seq,
            "daemon_owner": self.daemon_owner,
            "owner": owner,
            "id": frame["id"],
            "cmd": frame["cmd"],
            "args": frame.get("args", {}),
            "answer": answer,
        }
        line = json.dumps(row, sort_keys=True) + "\n"
        await self._commit(line)
        key = self._key(owner, frame["id"])
        reservation = self.window.get(key)
        self.window[key] = answer
        # Waiters are released only now: the answer they get is already durable.
        if isinstance(reservation, asyncio.Future) and not reservation.done():
            reservation.set_result(answer)

    async def _commit(self, line):
        """Queue one line for the next batch; return when its fsync returned."""
        loop = asyncio.get_running_loop()
        waiter = loop.create_future()
        self._pending.append(line)
        self._waiters.append(waiter)
        if self._committer is None or self._committer.done():
            # Its own task, owned by the journal: a client task cancelled at
            # exit0 must not take the batch its neighbours are parked on with it.
            self._committer = asyncio.ensure_future(self._commit_loop())
        await waiter

    async def _commit_loop(self):
        """One batch at a time: take everything queued, one write, one fsync."""
        loop = asyncio.get_running_loop()
        while self._pending:
            lines, waiters = self._pending, self._waiters
            self._pending, self._waiters = [], []
            self.batches += 1
            self.batched_lines += len(lines)
            try:
                await loop.run_in_executor(None, self._write_durable, "".join(lines))
                error = None
            except Exception as exc:  # noqa: BLE001 -- re-raised into every waiter
                error = exc
            for waiter in waiters:
                if waiter.done():
                    continue
                if error is None:
                    waiter.set_result(None)
                else:
                    waiter.set_exception(error)

    def _write_durable(self, batch):
        """Executor thread: append one batch (O_APPEND) and fsync the file once.

        `os.write` on an O_APPEND fd can return short for a large buffer, so the
        remainder is re-offered; every write lands at the current end of file,
        so a concurrent writer can never interleave INSIDE a line we wrote. The
        fd is the journal's own, opened once at __init__ -- see the note there.
        """
        view = memoryview(batch.encode("utf-8"))
        while view:
            view = view[os.write(self.fd, view):]
        os.fsync(self.fd)

    def sync(self):
        try:
            os.fsync(self.fd)
            _fsync_dir(self.dir)
        except OSError:
            pass


def complete_lines(text):
    """Every line of a journal file that the writer FINISHED.

    THE ONE definition of the torn-tail rule: whatever follows the last newline
    was never fsync'd, so no client ever saw its answer. Both readers in the
    product -- `Journal._replay` here and `startup_reap._journal_owner` -- go
    through this, because a reader that raises on a crash tail either refuses to
    start (replay) or refuses to reap a dead epoch's journal for ever
    (`zombie_journal_unreadable`). Returns (lines, torn) so the caller can say so.
    """
    lines = text.split("\n")
    tail = lines.pop()
    return [line for line in lines if line], bool(tail)


def _fsync_dir(path):
    dfd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(dfd)
    finally:
        os.close(dfd)
