"""Lifecycle, startup inventory, status, and shutdown methods for yanad."""

import asyncio
import hashlib
import os
import time
from pathlib import Path

from . import claims, daemon_store as store, liveness, migrate, protocol, startup_reap


class LifecycleMixin:
    def loop_exception_handler(self, loop, context):
        exc = context.get("exception")
        if exc is not None:
            self.log_unhandled(context.get("message", "asyncio"), exc)
        else:
            self.log.write("ERROR", "unhandled asyncio error: %s" % context.get("message"))

    def watch_done(self, task):
        self.watch_tasks.discard(task)
        if task.cancelled():
            return
        exc = task.exception()
        if exc is not None:
            self.log_unhandled("watch", exc)

    def socket_path(self):
        digest = hashlib.sha256(str(self.root).encode()).hexdigest()[:8]
        name = f"{digest}.sock"
        base = os.environ.get("XDG_RUNTIME_DIR")
        if base:
            return Path(base) / "yana" / name
        return Path(f"/tmp/yana-{os.getuid()}") / name

    async def root_watch(self):
        poll = float(os.environ.get("YANAD_ROOT_POLL_SECONDS", "5"))
        while not self.exiting:
            await asyncio.sleep(poll)
            try:
                if os.stat(self.root / "yanad.lock").st_ino != self.lock_inode:
                    await self.exit0()
            except OSError:
                await self.exit0()

    # Every accepted `hello` of kind nvim/cli is watched by pidfd under a
    # ("client:<pid>:<start_ticks>", None, "client") key; when that set empties and no
    # turn is running/reviewing, it exits.
    def register_client(self, kind, owner):
        if kind not in {"nvim", "cli"} or not owner:
            return
        try:
            pid = int(owner["pid"])
        except (KeyError, TypeError, ValueError):
            return
        key = ("client:%d:%s" % (pid, owner.get("start_ticks")), None, "client")
        if key in self.pidfds:
            return
        try:
            fd = liveness.pidfd_open(pid)
        except OSError:
            # The process died between the identity check and here; it never
            # counted as a client, so the registry is unchanged.
            return
        self.pidfds[key] = fd
        self.had_client = True
        self.register_pidfd_reader(fd, key, key[0], None, "client")
        self.log.write(
            "DEBUG",
            "client registered kind=%s pid=%d clients=%d" % (kind, pid, self.client_count()),
        )

    def client_count(self):
        return sum(1 for key in self.pidfds if key[2] == "client")

    def maybe_exit(self, after_answer=None, gone_pid=None):
        """Exit when the last registered client process is gone and no row is live.

        A daemon that never registered a client is not subject to this rule.
        `after_answer` is the FRAME ID whose answer must go out first, never a
        bool: `server.serve_frame` acts on the flag only when it names its own
        answer, so a bystander connection can never exit the daemon out from
        under the frame that asked for it.
        """
        if self.exiting or not self.had_client:
            return False
        clients = self.client_count()
        live = self.live_row_count()
        if clients == 0 and live == 0:
            self.log.write("DEBUG", "exit decision clients=0 live_rows=0 action=exit")
            if after_answer is not None:
                self.exit_after_answer = after_answer
            else:
                asyncio.create_task(self.exit0())
            return True
        if gone_pid is not None:
            self.log.write(
                "DEBUG",
                "client gone pid=%s clients=%d live_rows=%d action=stay"
                % (gone_pid, clients, live),
            )
        return False

    def live_row_count(self):
        # Ledger row 127 (daemon decision logging): the exit decision line
        # reports the count, so count with the same state set live_rows uses.
        return sum(
            1
            for session in store.iter_sessions(self.root, log=self.log)
            for turn in store.iter_turns(self.root, session["session_id"])
            if turn["state"] in {"running", "reviewing"}
        )

    def live_rows(self):
        return self.live_row_count() > 0

    def defer_workdir_cleanup(self, turn_dir, log):
        async def cleanup():
            try:
                await asyncio.get_running_loop().run_in_executor(
                    None, store.clear_turn_workdirs, turn_dir, log
                )
            except Exception as exc:
                self.log_unhandled("workdir_cleanup", exc)

        task = asyncio.create_task(cleanup())
        self.workdir_cleanup_tasks.add(task)
        task.add_done_callback(self.workdir_cleanup_tasks.discard)

    async def shutdown(self, fid):
        if self.live_rows():
            self.log_refusal("shutdown", "turn_running")
            return protocol.refuse(fid, "turn_running")
        self.exit_after_answer = fid
        return protocol.ok(fid)

    def status(self):
        pruned = store.prune_stale_recoveries(self.root, log=self.log)
        sessions = []
        for sess in store.iter_sessions(self.root, log=self.log):
            turns = store.iter_turns(self.root, sess["session_id"])
            lstate = liveness.owner_kind(sess.get("owner"))
            review_open = (self.root / "sessions" / sess["session_id"] / "review" / "open").exists()
            review_age_seconds = None
            files = []
            if review_open:
                try:
                    files = claims.review_files(self.root, sess["session_id"])
                    review_age_seconds = max(0, int(time.time() - (
                        self.root / "sessions" / sess["session_id"] / "review" / "open"
                    ).stat().st_mtime))
                except (OSError, ValueError):
                    files = []
            sessions.append({
                "session_id": sess["session_id"],
                "kind": sess["kind"],
                "workspace": sess["workspace"],
                "owner": sess["owner"],
                "liveness": lstate,
                "review": review_open,
                "review_age_seconds": review_age_seconds,
                "files": files,
                "turns": [{"turn_id": t["turn_id"], "state": t["state"]} for t in turns],
            })
        claim_rows = [
            {key: row[key] for key in ["slug", "session_id", "turn_id", "state", "since"]}
            for row in store.iter_claims(self.root)
        ]
        return {"sessions": sessions, "claims": claim_rows, "pruned": pruned}

    def replay_startup(self):
        # first.
        migrate.migrate_legacy(self.root)
        startup_reap.reap(self.root, self.owner_identity, self.log)
        store.replay(self.root)
        for sess in store.iter_sessions(self.root, log=self.log):
            for turn in store.iter_turns(self.root, sess["session_id"]):
                if turn["state"] != "running":
                    continue
                kind = liveness.owner_kind(turn.get("owner"))
                if kind == "live":
                    self.watch_owner(sess["session_id"], turn["turn_id"], turn["owner"], "launcher")
                elif kind == "dead":
                    self.owner_dead(sess["session_id"], turn["turn_id"], "launcher")
            editor_kind = liveness.owner_kind(sess.get("owner"))
            if editor_kind == "live":
                self.watch_owner(sess["session_id"], None, sess["owner"], "editor")
            elif editor_kind == "dead" and not sess.get("dead"):
                self.owner_dead(sess["session_id"], None, "editor")

    def watch_owner(self, sid, tid, owner, role):
        if not owner:
            return
        try:
            fd = liveness.pidfd_open(int(owner["pid"]))
        except OSError:
            self.owner_dead(sid, tid, role)
            return
        key = (sid, tid, role)
        self.unwatch(*key)
        self.pidfds[key] = fd
        self.register_pidfd_reader(fd, key, sid, tid, role)

    def register_pidfd_reader(self, fd, key, sid, tid, role):
        loop = asyncio.get_running_loop()
        loop.add_reader(fd, self.owner_dead, sid, tid, role)

    def unwatch(self, sid, tid, role):
        key = (sid, tid, role)
        fd = self.pidfds.pop(key, None)
        if fd is not None:
            loop = asyncio.get_running_loop()
            loop.remove_reader(fd)
            os.close(fd)

    def owner_dead(self, sid, tid, role):
        if role == "client":
            self.unwatch(sid, tid, role)
            self.maybe_exit(gone_pid=sid.split(":")[1])
            return
        self.unwatch(sid, tid, role)
        if role == "editor":
            for turn in store.iter_turns(self.root, sid):
                if turn["state"] == "running":
                    self.owner_dead(sid, turn["turn_id"], "launcher")
                elif turn["state"] in {"settling", "reviewing"}:
                    store.set_turn_state(
                        self.root, sid, turn["turn_id"], "dead", log=self.log,
                        clear_workdirs=self.defer_workdir_cleanup,
                    )
            sess_path = self.root / "sessions" / sid / "session.json"
            sess = store.read_json(sess_path) if sess_path.exists() else {}
            self.clear_releasable_claims(sid)
            if sess_path.exists():
                sess["dead"] = True
                store.atomic_json(sess_path, sess)
            return
        if role == "launcher" and tid:
            state = "dead"
            reason = None
            try:
                meta = store.read_json(self.root / "sessions" / sid / "turns" / tid / "meta.json")
                state, reason = liveness.seal_cgroup(meta.get("cgroup", ""))
                if state == "sealed":
                    state = "dead"
            except OSError:
                pass
            store.set_turn_state(
                self.root, sid, tid, state, reason, log=self.log,
                clear_workdirs=self.defer_workdir_cleanup,
            )
            for row in store.iter_claims(self.root):
                if row["session_id"] == sid and row["turn_id"] == tid:
                    if state == "dead_unsealed":
                        store.write_claim_row(self.root, row["slug"], sid, tid, state)
                    else:
                        (self.root / "claims" / row["slug"] / "row.json").unlink(missing_ok=True)
        self.maybe_exit()

    def clear_releasable_claims(self, sid):
        for row in store.iter_claims(self.root):
            if row["session_id"] != sid:
                continue
            meta_path = self.root / "sessions" / sid / "turns" / row["turn_id"] / "meta.json"
            try:
                meta = store.read_json(meta_path)
            except OSError:
                (self.root / "claims" / row["slug"] / "row.json").unlink(missing_ok=True)
                continue
            if meta["state"] != "dead_unsealed":
                (self.root / "claims" / row["slug"] / "row.json").unlink(missing_ok=True)

    async def exit0(self):
        if self.exiting:
            return
        self.exiting = True
        if self.sock_path:
            self.sock_path.unlink(missing_ok=True)
        try:
            (self.root / "yanad.sock.path").unlink(missing_ok=True)
        except OSError:
            pass
        if self.server:
            self.server.close()
        # An in-flight frame finishes -- journals AND answers -- before
        # the daemon goes. Every span is its own shielded task, so it is awaited
        # here, before the writers are aborted and the client tasks cancelled.
        #
        # NO TIMEOUT. A 5 s bound was a cancelling bound: under a burst of 600
        # with two dd writers on the same spindle it fired while spans were
        # still mid-`session.create`, and a cancelled span had already made its
        # session dir in dispatch but not yet reached `journal.append` -- 182
        # unjournaled dirs at N=600, 814 at N=1200 (adversary sd_real.sh). Spans
        # are bounded by the disk, not by a peer, so the right bound is "all of
        # them"; progress is logged every second so a real hang is visible.
        # `handle` refuses new frames once `self.exiting` is set, and the
        # listener is already closed above, so this set only shrinks.
        waited = 0.0
        while True:
            spans = [task for task in self.inflight if not task.done()]
            if not spans:
                break
            done, _ = await asyncio.wait(spans, timeout=1)
            waited += 1
            remaining = len([task for task in self.inflight if not task.done()])
            if remaining:
                self.log.write("INFO", "exit0 draining in-flight frames: %d left after %.0fs"
                               % (remaining, waited))
        current = asyncio.current_task()
        writers = list(self.client_writers)
        for writer in writers:
            writer.transport.abort()
        pending = [task for task in self.client_tasks if task is not current and not task.done()]
        for task in pending:
            task.cancel()
        if pending:
            await asyncio.wait(pending, timeout=1)
        for writer in writers:
            try:
                await asyncio.wait_for(writer.wait_closed(), timeout=1)
            except (OSError, TimeoutError):
                pass
        if self.server:
            try:
                await asyncio.wait_for(self.server.wait_closed(), timeout=1)
            except TimeoutError:
                pass
        if self.journal:
            self.journal.sync()
        for key in list(self.pidfds):
            self.unwatch(*key)
        current = asyncio.current_task()
        watches = list(self.watch_tasks)
        for task in watches:
            if task is not current and not task.done():
                task.cancel()
        if watches:
            await asyncio.gather(
                *(task for task in watches if task is not current),
                return_exceptions=True,
            )
        # The flock is NOT released here, and the fd is NOT closed. Releasing it
        # while this process still exists let a successor win the lock, run
        # startup_reap, see /proc/<predecessor pid> still present, rule the
        # journal owner `zombie_owner_live` and KEEP the predecessor's rows
        # (startup_reap.py:169-196). The kernel drops the flock when the last fd
        # closes at process exit -- by then the pid is gone and the successor's
        # liveness read is unambiguous. `self.lock_fh` stays referenced so the
        # file object is not garbage-collected (that would close the fd, and the
        # lock with it).
        self.stopped.set()
