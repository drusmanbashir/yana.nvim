import asyncio
import fcntl
import json
import os
import resource
import socket
import sys
import time
from pathlib import Path

from . import claims, daemon_log, daemon_store as store, liveness, protocol, tree_version
from .journal import Journal
from .server_lifecycle import LifecycleMixin


class Daemon(LifecycleMixin):
    def __init__(self, root, log_level=None):
        self.root = Path(root).resolve()
        self.repo = Path(__file__).resolve().parents[3]
        self.version = tree_version.read(self.repo)
        self.log = daemon_log.DaemonLogger(self.root / "yanad.log", log_level)
        if self.version == "":
            # A daemon on "" is serviceable -- its clients read the same absence --
            # but nothing else in the run records why the version handshake went
            # blank, and the tree state that caused it is usually gone by the time
            # anyone looks.
            self.log.write("WARN", "version unreadable at %s: serving version=''" % (self.repo / tree_version.PATH))
        self.lock_fh = None
        self.sock_path = None
        self.server = None
        self.journal = None
        self.pidfds = {}
        self.client_tasks = set()
        self.client_writers = set()
        self.workdir_cleanup_tasks = set()
        self.watch_tasks = set()
        self.stopped = asyncio.Event()
        self.had_client = False
        self.exiting = False
        # Frame id of the answer whose sender must exit after it is written --
        # never a bare bool: the span that SET it is the only one allowed to act
        # on it. A global flag let a bystander connection run exit0 and abort
        # the requester's socket before its own ok was written.
        self.exit_after_answer = None
        # Shielded dispatch->journal->answer spans in flight (server.serve_frame).
        # exit0 awaits these so no created session dir is left unjournaled.
        self.inflight = set()
        self.lock_inode = None
        self.owner_identity = None
        # Bound on frames DISPATCHING at once (start(): derived from RLIMIT_NOFILE).
        # None until start, so a Daemon constructed and never started is unchanged.
        self.dispatch_slots = None
        self.dispatch_limit = 0
        self.write_timeout = float(os.environ.get("YANAD_WRITE_TIMEOUT", "10"))

    async def start(self):
        asyncio.get_running_loop().set_exception_handler(self.loop_exception_handler)
        probe = liveness.pidfd_open(os.getpid())
        os.close(probe)
        self.owner_identity = liveness.pid_identity(os.getpid())
        self.raise_fd_limit()
        self.root.mkdir(parents=True, exist_ok=True)
        self.log.write("DEBUG", "daemon start attempt root=%s" % self.root)
        self.lock_fh = (self.root / "yanad.lock").open("a+")
        deadline = time.time() + 5
        while True:
            try:
                fcntl.flock(self.lock_fh.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
                break
            except BlockingIOError:
                if time.time() >= deadline:
                    return False
                await asyncio.sleep(0.1)
        self.lock_inode = os.fstat(self.lock_fh.fileno()).st_ino
        self.sock_path = self.socket_path()
        self.sock_path.parent.mkdir(parents=True, exist_ok=True)
        self.sock_path.unlink(missing_ok=True)
        # A predecessor that died without exit0 (SIGKILL, crash, os._exit) leaves its
        # readiness file behind; it must never advertise this daemon before replay.
        (self.root / "yanad.sock.path").unlink(missing_ok=True)
        sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        sock.bind(str(self.sock_path))
        # The accept BACKLOG is part of the concurrency bound, not a detail: 600
        # clients connecting at once overflowed a backlog of 100 and 14 of them
        # got EAGAIN from connect(2) before the daemon ever saw them -- a client
        # dropped for arriving in a crowd, which no retry of ours can excuse.
        # Sized off the same dispatch bound: queueing a connection costs a
        # kernel struct, not an fd, so the queue may be deeper than the work.
        backlog = 512 if self.dispatch_slots is None else max(512, 2 * self.dispatch_limit)
        sock.listen(backlog)
        sock.setblocking(False)
        (self.root / "yanad.pid").write_text(str(os.getpid()) + "\n")
        self.server = await asyncio.start_unix_server(self.handle, sock=sock, start_serving=False)
        # yanad.sock.path is readiness: it MUST NOT exist before startup work finishes.
        self.replay_startup()
        self.journal = Journal(self.root, self.owner_identity)
        (self.root / "yanad.sock.path").write_text(str(self.sock_path) + "\n")
        await self.server.start_serving()
        task = asyncio.create_task(self.root_watch())
        self.watch_tasks.add(task)
        task.add_done_callback(self.watch_done)
        return True

    def raise_fd_limit(self):
        """Take the whole hard RLIMIT_NOFILE, then bound dispatch under it.

        A burst of 600 clients is 600 accepted sockets plus the daemon's own
        fds, and the default soft limit of 1024 is not enough: at N=600 the
        session.json tmp open in store.write_json_atomic raised EMFILE and 186
        of 600 creates were answered `internal_error` (adversary y1, 8/8 runs).
        Two halves, because either alone is a gamble: raise the soft limit to
        the hard one, AND cap concurrent dispatch so exhaustion is impossible
        whatever the limit turns out to be. Beyond the cap a connection WAITS --
        it is already accepted and simply queues; refusing a client that did
        nothing wrong is not a bound, it is a failure with a nicer name.
        """
        soft, hard = resource.getrlimit(resource.RLIMIT_NOFILE)
        if soft < hard:
            try:
                resource.setrlimit(resource.RLIMIT_NOFILE, (hard, hard))
                soft = hard
            except (OSError, ValueError) as exc:
                self.log.write("WARN", "could not raise RLIMIT_NOFILE from %s to %s: %s"
                               % (soft, hard, type(exc).__name__))
        limit = soft if soft != resource.RLIM_INFINITY else 4096
        slots = max(16, min(512, int(limit) - 128))
        self.dispatch_slots = asyncio.Semaphore(slots)
        self.dispatch_limit = slots
        self.log.write("INFO", "fd limit soft=%s hard=%s dispatch_slots=%d"
                       % (soft, hard, slots))

    async def handle(self, reader, writer):
        task = asyncio.current_task()
        self.client_tasks.add(task)
        self.client_writers.add(writer)
        try:
            # Persistent connection: clients send hello then commands on ONE
            # socket (bin/lib/yanad/client.py exchange(); lua/yana/runtime/yanad.lua).
            # Closing after the first frame → BrokenPipe on
            # the second write and yanad.client exits 66. One-shot CLIs still
            # work — they send one frame and close their end.
            # YANAD_TEST_ONE_FRAME=1 is the mutation seam: one answer then close.
            one_frame = os.environ.get("YANAD_TEST_ONE_FRAME") == "1"
            while True:
                try:
                    line = await reader.readline()
                except (ConnectionResetError, BrokenPipeError):
                    # asyncio parks a transport's fatal WRITE error on the reader
                    # and re-raises it here (streams.readuntil -> `raise
                    # self._exception`), so a client that departed while its
                    # answer was in flight surfaces as a read failure, not at
                    # `self.write`. Both sites end the connection quietly: every
                    # answer already sent is journaled, and letting this escape
                    # cost an fsync'd "Unhandled exception in
                    # client_connected_cb: Connection lost" per departed client.
                    return
                if not line:
                    return
                try:
                    frame = json.loads(line.decode())
                except json.JSONDecodeError:
                    return
                if self.exiting:
                    # exit0 has closed the listener and is draining the spans it
                    # can see; a frame DISPATCHED now would add a side effect to
                    # a set it has already finished waiting on. But it is still
                    # answered: returning here silently gave the asker an
                    # unexplained EOF, and the runner's own shutdown helper read
                    # that as "yanad closed without answer" and failed the row.
                    # Neither answer below has a side effect, so neither needs a
                    # journal row -- `shutdown` is already happening, and every
                    # other command is refused with a code that says re-send.
                    if frame.get("cmd") == "shutdown":
                        await self.write(writer, protocol.ok(frame.get("id")))
                    else:
                        await self.write(writer, protocol.refuse(frame.get("id"), "shutting_down"))
                    return
                if liveness.peer_uid(writer) != os.getuid():
                    return
                owner = frame.get("owner") or {}
                # Reserve (owner, id) HERE, on the loop thread, before any await:
                # dispatch and the journal both yield now, and the product's own
                # client re-sends the identical frame on a new connection after a
                # 2.0 s timeout (client.py exchange/request). See journal.claim.
                answer, pending = self.journal.claim(owner, frame.get("id"))
                if pending is not None:
                    answer = await pending
                    if answer is None:
                        # The owning connection died without an answer; this one
                        # closes too, and the client re-sends to a clean daemon.
                        return
                if answer is not None:
                    await self.write(writer, answer)
                    if one_frame:
                        return
                    continue
                span = asyncio.ensure_future(self.serve_frame(writer, frame, owner))
                self.inflight.add(span)
                span.add_done_callback(self.inflight.discard)
                # Shielded: cancelling this connection at exit0 must not strand a
                # session dir with no journal row and no answer (an in-flight
                # frame finishes, journals and answers).
                exit_after = await asyncio.shield(span)
                if exit_after is None:
                    return
                if one_frame:
                    return
                if exit_after:
                    writer.close()
                    self.client_writers.discard(writer)
                    self.client_tasks.discard(task)
                    await self.exit0()
                    return
        finally:
            self.client_writers.discard(writer)
            self.client_tasks.discard(task)
            try:
                writer.close()
            except Exception:
                pass

    async def serve_frame(self, writer, frame, owner):
        """Own one reserved frame end to end: dispatch, journal, answer.

        Returns None if the connection must close, else whether THIS frame asked
        the daemon to exit after its answer. Runs as its own shielded task so
        the span survives the client task's cancellation at exit0.
        """
        settled = False
        try:
            # The slot covers DISPATCH only -- the part that opens files. The
            # journal has one fd for the daemon's life, and `write` uses a
            # socket that is already open, so holding the slot across either
            # would let one unread answer (see `write`) stall every other
            # client's dispatch for nothing.
            if self.dispatch_slots is None:
                answer = await self.dispatch(frame)
            else:
                async with self.dispatch_slots:
                    answer = await self.dispatch(frame)
            if answer is None:
                return None
            # Read the exit intent with NO await since dispatch returned: only
            # this frame's own handlers can have set it to this answer's id.
            exit_after = self.exit_after_answer == answer["id"]
            if exit_after:
                self.exit_after_answer = None
            # Shielded: the side effect is already on disk, so a cancellation
            # landing between dispatch and the journal row is exactly the split
            # exit0 must never produce. The batch this line joins commits
            # regardless of what happens to this task.
            await asyncio.shield(self.journal.append(owner, frame, answer))
            settled = True
            if os.environ.get("YANAD_TEST_DIE_AFTER_JOURNAL") == frame.get("cmd"):
                os._exit(3)
            await self.write(writer, answer)
            return exit_after
        finally:
            if not settled:
                self.journal.abandon(owner, frame.get("id"))

    async def write(self, writer, answer):
        # The answer is already journaled, so a client that departed before
        # reading it costs nothing: it will get the identical answer from
        # `journal.stored` if it ever re-sends the id. Letting the reset escape
        # made asyncio log "Unhandled exception in client_connected_cb:
        # Connection lost" -- one more fsync'd ERROR line per departed client.
        try:
            writer.write((json.dumps(answer, sort_keys=True) + "\n").encode())
            # BOUNDED. `drain()` returns only when the peer reads, so a client
            # that pipelines frames and never reads fills the send buffer and
            # parks this span for ever -- and exit0 waits for every span, so the
            # daemon could never shut down (adversary y3). The answer is already
            # journaled, which is what makes dropping this client safe: it gets
            # the identical answer from `journal.stored` when it re-sends the id.
            # A span in dispatch or append is still never cut; only the write is.
            await asyncio.wait_for(writer.drain(), timeout=self.write_timeout)
        except (ConnectionResetError, BrokenPipeError):
            return
        except TimeoutError:
            self.log.write(
                "WARN",
                "client did not read its answer within %.1fs; dropping the connection "
                "(id=%s, answer is journaled and replayable)" % (self.write_timeout, answer.get("id")),
            )
            try:
                writer.transport.abort()
            except Exception:
                pass
            return

    async def dispatch(self, frame):
        cmd = frame.get("cmd")
        fid = frame.get("id")
        owner = frame.get("owner") or {}
        args = frame.get("args") or {}
        if cmd not in {"status", "session.delete"} and not liveness.identity_matches(owner):
            self.log_refusal(
                cmd, "identity_mismatch",
                session=args.get("session_id"), turn=args.get("turn_id"), path=args.get("path"),
            )
            return protocol.refuse(fid, "identity_mismatch")
        if cmd == "hello":
            if self.version_changed():
                self.log_refusal(cmd, "version_changed")
                asyncio.create_task(self.exit0())
                return None
            if frame.get("version") != self.version:
                self.log_refusal(cmd, "version_mismatch")
                return protocol.refuse(fid, "version_mismatch", {"reload": True})
            self.register_client(args.get("kind"), owner)
            return protocol.ok(fid, {"client_id": str(os.getpid()), "version": self.version, "epoch": self.journal.epoch})
        if frame.get("version") != self.version:
            self.log_refusal(
                cmd, "version_mismatch",
                session=args.get("session_id"), turn=args.get("turn_id"), path=args.get("path"),
            )
            return protocol.refuse(fid, "version_mismatch", {"reload": True})
        try:
            if cmd == "status":
                return protocol.ok(fid, self.status())
            if cmd == "session.delete":
                return self.exit_checked(self.session_delete(frame))
            if cmd == "session.create":
                return await self.session_create(frame)
            if cmd == "session.attach":
                return self.session_attach(frame)
            if cmd == "turn.request":
                return self.turn_request(frame)
            if cmd == "turn.end":
                return self.exit_checked(self.turn_end(frame))
            if cmd == "review.open":
                return self.review_open(frame)
            if cmd in {"review.close", "review.abort"}:
                return self.exit_checked(self.review_close(frame))
            if cmd == "review.none":
                return self.exit_checked(self.review_none(frame))
            if cmd == "file.claim":
                return self.file_claim(frame)
            if cmd == "shutdown":
                return await self.shutdown(fid)
        except store.Refused as exc:
            self.log_refusal(
                cmd, exc.code, getattr(exc, "reason", None),
                session=args.get("session_id"), turn=args.get("turn_id"), path=args.get("path"),
            )
            return protocol.refuse(fid, exc.code, {"reason": getattr(exc, "reason", None)})
        except Exception as exc:
            # An answered refusal is always better than a dropped connection: the client
            # can name it, and the journal keeps a row.
            self.log_unhandled(cmd, exc)
            return protocol.refuse(fid, "internal_error", {
                "reason": type(exc).__name__ + ": " + str(exc),
                "cmd": cmd,
            })
        self.log_refusal(cmd, "unknown_command")
        return protocol.refuse(fid, "unknown_command")

    def exit_checked(self, answer):
        # after_answer carries the FRAME ID, so only this answer's own span acts.
        self.maybe_exit(after_answer=answer["id"])
        return answer

    def log_refusal(self, cmd, code, detail=None, session=None, turn=None, path=None):
        parts = ["refusal cmd=%s code=%s" % (cmd, code)]
        if session not in (None, ""):
            parts.append("session=%s" % session)
        if turn not in (None, ""):
            parts.append("turn=%s" % turn)
        if path not in (None, ""):
            parts.append("path=%s" % path)
        if detail not in (None, "") and not isinstance(detail, dict):
            parts.append("reason=%s" % detail)
        self.log.write("WARN", " ".join(parts))

    def log_unhandled(self, cmd, exc):
        import traceback
        self.log.write(
            "ERROR",
            "unhandled in %s: %s\n%s" % (cmd, exc, traceback.format_exc()),
        )

    def version_changed(self):
        return tree_version.read(self.repo) != self.version

    async def session_create(self, frame):
        # create_session is tmp+replace+two fsyncs of session.json (store.py
        # write_json_atomic): 25-45 ms of blocked event loop per request on
        # rotational ext4. It touches no daemon in-memory state, only the
        # filesystem, so it runs in the default executor while other
        # connections are served; `watch_owner` stays on the loop thread.
        args = frame["args"]
        sid = await asyncio.get_running_loop().run_in_executor(
            None,
            store.create_session,
            self.root,
            args["workspace"],
            args["backend"],
            args["kind"],
            args["owner"],
            self.owner_identity,
            self.version,
        )
        self.watch_owner(sid, None, args["owner"], "editor")
        return protocol.ok(frame["id"], {"session_id": sid})

    def session_attach(self, frame):
        sid = frame["args"]["session_id"]
        recovery = store.load_recovery(self.root, sid)
        self.unwatch(sid, None, "editor")
        if recovery:
            session = store.rebind_review(self.root, sid, frame["owner"], recovery)
        else:
            session = store.rebind_session(self.root, sid, frame["owner"])
        self.watch_owner(sid, None, frame["owner"], "editor")
        result = dict(session)
        if recovery:
            # O8: surface the turn's persisted mode from meta.json onto the
            # recovery payload (load_recovery does not yet copy it). Absence
            # stays absence — yanad_recover refuses a mode-less record.
            meta = store.read_json(
                self.root / "sessions" / sid / "turns" / recovery["turn_id"] / "meta.json"
            )
            if isinstance(meta, dict) and "mode" in meta:
                recovery["mode"] = meta["mode"]
            result["recovery"] = recovery
        return protocol.ok(frame["id"], result)

    def session_delete(self, frame):
        removed = store.delete_session(self.root, frame["args"]["session_id"], log=self.log)
        return protocol.ok(frame["id"], {"removed": removed})

    def turn_request(self, frame):
        args = frame["args"]
        sid = args["session_id"]
        store.load_session(self.root, sid)
        owner = frame["owner"]
        if not liveness.cgroup_matches(owner, args.get("cgroup", "")):
            self.log_refusal("turn.request", "cgroup_mismatch", session=sid)
            return protocol.refuse(frame["id"], "cgroup_mismatch")
        blocked, cleaned = self.reconcile_prior_turns(sid, args["turn_id"])
        if blocked:
            self.log_refusal(
                "turn.request", "turn_running",
                session=sid, turn=blocked.get("turn_id"),
            )
            return protocol.refuse(frame["id"], "turn_running", blocked)
        if cleaned:
            self.warn_dead_turn_cleanup(cleaned, args["turn_id"])
        mode = args.get("mode")
        # Claims are per FILE, never per workspace: a claim refuses a FILE under another
        # session's open review (the same path or one inside it). Reads, ask turns and an
        # agent inside its own overlay never claim; an empty touched set takes no claim;
        # `file.claim` arbitrates per file at accept.
        if mode == "ask":
            launch = self.make_turn_dir(sid, args, owner, mode)
            return protocol.ok(frame["id"], {"launch": launch})
        keys = claims.claim_keys(args.get("touched") or args.get("files") or [])
        launch = self.make_turn_dir(sid, args, owner, mode)
        for key in keys:
            store.write_claim_row(self.root, key, sid, args["turn_id"], "running")
            self.log.write(
                "DEBUG",
                "claim event action=acquire key=%s session=%s turn=%s"
                % (key, sid, args["turn_id"]),
            )
        self.watch_owner(sid, args["turn_id"], owner, "launcher")
        return protocol.ok(frame["id"], {"launch": launch})

    def make_turn_dir(self, sid, args, owner, mode):
        try:
            return store.turn_dir(
                self.root, sid, args["turn_id"], args["cgroup"], owner,
                args["mounted_root"], args.get("roots", []), mode, args.get("plan"),
            )
        except Exception as exc:
            self.log.write(
                "ERROR",
                "overlay mount failure turn=%s: %s" % (args["turn_id"], exc),
            )
            raise

    def reconcile_prior_turns(self, sid, requested_tid):
        """Clear dead launch state before minting the next turn's layers.

        A live or unclassifiable owner is never reclaimed. A dead turn with an
        open review remains available for recovery; only an unreviewed dead
        turn is disposable.
        """
        cleaned = []
        review_path = self.root / "sessions" / sid / "review" / "open"
        review_tid = None
        if review_path.exists():
            try:
                review_tid = store.read_json(review_path).get("turn_id")
            except (OSError, AttributeError, TypeError, ValueError):
                review_tid = None
        for turn in store.iter_turns(self.root, sid):
            tid = turn["turn_id"]
            state = turn.get("state")
            if state == "running":
                kind = liveness.owner_kind(turn.get("owner"))
                if kind == "live":
                    return {"turn_id": tid, "reason": "turn is still live"}, cleaned
                if kind != "dead":
                    return {"turn_id": tid, "reason": "turn liveness is unconfirmed"}, cleaned
                self.owner_dead(sid, tid, "launcher")
                try:
                    state = store.read_json(
                        self.root / "sessions" / sid / "turns" / tid / "meta.json"
                    ).get("state")
                except OSError:
                    state = "dead"
            # dead_unsealed preserves its residue refusal for
            # session.delete, but never excludes another launch.
            if state == "dead_unsealed":
                continue
            if state not in {"dead", "sealed"} or tid == review_tid:
                continue
            store.clear_claim_rows_for_turn(self.root, sid, tid)
            store.remove_turn(self.root, sid, tid, log=self.log)
            cleaned.append(tid)
        return None, cleaned

    def warn_dead_turn_cleanup(self, turn_ids, requested_tid):
        names = ", ".join(turn_ids)
        self.log.write("WARN", "self-healed dead turn %s before turn %s" % (names, requested_tid))

    def turn_end(self, frame):
        args = frame["args"]
        tid = args["turn_id"]
        sid = args.get("session_id")
        if not sid:
            for session in store.iter_sessions(self.root):
                if any(turn["turn_id"] == tid for turn in store.iter_turns(self.root, session["session_id"])):
                    sid = session["session_id"]
                    break
        if not sid:
            return protocol.ok(frame["id"])  # no-op when not holder
        meta_path = self.root / "sessions" / sid / "turns" / tid / "meta.json"
        if not meta_path.exists():
            return protocol.ok(frame["id"])
        held = [
            row for row in store.iter_claims(self.root)
            if row["session_id"] == sid and row["turn_id"] == tid
        ]
        state, reason = liveness.seal_cgroup(store.read_json(meta_path).get("cgroup", ""))
        next_state = "settling" if state == "sealed" else state
        for row in held:
            store.write_claim_row(self.root, row["key"], sid, tid, next_state)
        store.set_turn_state(
            self.root, sid, tid, next_state, reason, log=self.log,
            clear_workdirs=self.defer_workdir_cleanup,
        )
        self.unwatch(sid, tid, "launcher")
        session = store.load_session(self.root, sid)
        if session.get("kind") == "cli":
            self.unwatch(sid, None, "editor")
        return protocol.ok(frame["id"])

    def review_open(self, frame):
        args = frame["args"]
        sid = args["session_id"]
        tid = args["turn_id"]
        meta_path = self.root / "sessions" / sid / "turns" / tid / "meta.json"
        try:
            turn = store.read_json(meta_path)
        except OSError:
            return protocol.refuse(frame["id"], "not_holder")
        if turn.get("state") not in {"running", "settling"}:
            return protocol.refuse(frame["id"], "not_holder")
        files = args["files"]
        incoming_keys = claims.claim_keys(files)
        for holder in store.iter_arbitration_holders(self.root):
            if holder["session_id"] == sid:
                continue
            code, result = claims.refusal_for(self.root, holder, files)
            if code:
                return protocol.refuse(frame["id"], code, result)
        store.open_review(
            self.root, sid, tid, files, args.get("tabs", []), args.get("bundle", []),
        )
        store.clear_claim_rows(self.root, sid)
        for key in incoming_keys:
            store.write_claim_row(self.root, key, sid, tid, "reviewing")
        store.set_turn_state(
            self.root, sid, tid, "reviewing", log=self.log,
            clear_workdirs=self.defer_workdir_cleanup,
        )
        return protocol.ok(frame["id"])

    def review_none(self, frame):
        args = frame["args"]
        sid = args["session_id"]
        tid = args["turn_id"]
        store.set_turn_state(
            self.root, sid, tid, "closed", log=self.log,
            clear_workdirs=self.defer_workdir_cleanup,
        )
        store.clear_claim_rows(self.root, sid)
        return protocol.ok(frame["id"])

    def review_close(self, frame):
        sid = frame["args"]["session_id"]
        opened = self.root / "sessions" / sid / "review" / "open"
        if not opened.exists():
            raise store.Refused("no_review")
        try:
            tid = store.read_json(opened).get("turn_id")
        except (OSError, ValueError):
            tid = None
        if not tid:
            holder = next(
                (row for row in store.iter_arbitration_holders(self.root) if row["session_id"] == sid),
                None,
            )
            tid = holder and holder["turn_id"]
        if not tid:
            raise store.Refused("no_review")
        store.close_review(self.root, sid)
        store.set_turn_state(
            self.root, sid, tid, "closed", log=self.log,
            clear_workdirs=self.defer_workdir_cleanup,
        )
        store.clear_claim_rows(self.root, sid)
        return protocol.ok(frame["id"])

    def file_claim(self, frame):
        args = frame["args"]
        sid = args["session_id"]
        path = str(Path(args["path"]).resolve())
        for holder in store.iter_arbitration_holders(self.root):
            if holder["session_id"] == sid:
                continue
            code, result = claims.refusal_for(self.root, holder, [path])
            if code:
                self.log.write(
                    "DEBUG",
                    "claim event action=check path=%s result=held" % path,
                )
                return protocol.refuse(frame["id"], "held", result)
        self.log.write("DEBUG", "claim event action=check path=%s result=free" % path)
        return protocol.ok(frame["id"])

async def amain(root, log_level=None):
    daemon = Daemon(root, log_level)
    asyncio.get_running_loop().set_exception_handler(daemon.loop_exception_handler)
    try:
        started = await daemon.start()
        if not started:
            return
        await daemon.stopped.wait()
    except Exception as exc:
        daemon.log_unhandled("amain", exc)
        if not daemon.exiting:
            await daemon.exit0()
        raise


def main(args):
    try:
        asyncio.run(amain(args.root, getattr(args, "log_level", None)))
    except ValueError as exc:
        print("yanad: %s" % exc, file=sys.stderr)
        sys.exit(2)
    except KeyboardInterrupt:
        sys.exit(0)
