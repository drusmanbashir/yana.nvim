"""One-shot yanad client for launcher and CLI processes (U4)."""

import argparse
import hashlib
import json
import os
from pathlib import Path
import shlex
import socket
import subprocess
import sys
import time

# Both `python3 -m yanad.client` (yanad.sh) and `python3 bin/lib/yanad/client.py`
# (a bare debugging invocation, and what the daemon gates drive) must work, so
# the package root goes on the path before the package is imported. Under `-m`
# the entry is already there and the insert changes nothing.
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from yanad import tree_version


EXIT_USAGE = 64
EXIT_REFUSE = 65
EXIT_NO_DAEMON = 66
REPO = Path(__file__).resolve().parents[3]


class Parser(argparse.ArgumentParser):
    def error(self, message):
        self.print_usage(sys.stderr)
        self.exit(EXIT_USAGE, f"{self.prog}: error: {message}\n")


def owner_identity(pid):
    stat = Path(f"/proc/{pid}/stat").read_text(encoding="utf-8")
    fields_after_comm = stat[stat.rfind(")") + 2 :].split()
    return {
        "pid": pid,
        "boot_id": Path("/proc/sys/kernel/random/boot_id")
        .read_text(encoding="utf-8")
        .strip(),
        "start_ticks": int(fields_after_comm[19]),
    }


def socket_path(root):
    recorded = root / "yanad.sock.path"
    try:
        path = recorded.read_text(encoding="utf-8").strip()
    except FileNotFoundError:
        path = ""
    if path:
        return path

    runtime = os.environ.get("XDG_RUNTIME_DIR")
    socket_dir = Path(runtime) / "yana" if runtime else Path(f"/tmp/yana-{os.getuid()}")
    socket_dir.mkdir(parents=True, exist_ok=True)
    digest = hashlib.sha256(os.path.realpath(root).encode("utf-8")).hexdigest()[:8]
    return str(socket_dir / f"{digest}.sock")


def receive_line(stream):
    line = stream.readline()
    if not line:
        raise ConnectionError("yanad closed without an answer")
    answer = json.loads(line)
    if not isinstance(answer, dict):
        raise ConnectionError("yanad answer is not an object")
    return answer


def connect_with_backlog_retry(client, path, deadline_s=2.0):
    """connect(2), retrying only the "queue is momentarily full" answer.

    A full AF_UNIX accept queue makes connect raise EAGAIN (BlockingIOError) on
    a socket with a timeout -- the daemon is up and listening, it simply has not
    accepted yet. That is a wait, not a failure, but a single connect turned it
    into one: at loadavg 17, 9 of 600 simultaneous clients were dropped before
    the daemon ever saw them. ECONNREFUSED is NOT retried here -- it means no
    daemon, which is the autostart path's business, not this loop's.
    """
    deadline = time.monotonic() + deadline_s
    delay = 0.005
    while True:
        try:
            client.connect(path)
            return
        except BlockingIOError:
            if time.monotonic() >= deadline:
                raise
            time.sleep(delay)
            delay = min(delay * 2, 0.05)


def exchange(path, hello, request):
    with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as client:
        client.settimeout(2.0)
        connect_with_backlog_retry(client, path)
        with client.makefile("rwb", buffering=0) as stream:
            stream.write(json.dumps(hello, separators=(",", ":")).encode() + b"\n")
            hello_answer = receive_line(stream)
            if not hello_answer.get("ok"):
                return hello_answer
            stream.write(json.dumps(request, separators=(",", ":")).encode() + b"\n")
            return receive_line(stream)


def start_daemon(root):
    daemon = str(REPO / "bin" / "yanad")
    systemd = shlex.split(os.environ.get("YANAD_SYSTEMD_RUN", "systemd-run"))
    try:
        started = subprocess.run(
            [*systemd, "--user", "--collect", daemon, "--root", str(root)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        ).returncode == 0
    except FileNotFoundError:
        started = False
    if started:
        return

    setsid = shlex.split(os.environ.get("YANAD_SETSID", "setsid"))
    try:
        subprocess.run(
            [*setsid, "-f", daemon, "--root", str(root)],
            stdin=subprocess.DEVNULL,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            check=False,
        )
    except FileNotFoundError:
        pass


def request(args):
    root = Path(args.root).resolve()
    root.mkdir(parents=True, exist_ok=True)
    owner = owner_identity(args.owner_pid)
    version = tree_version.read(REPO)
    hello = {
        "v": 1,
        "id": f"{args.id}:hello",
        "cmd": "hello",
        "args": {"kind": args.kind, "servername": args.servername},
        "owner": owner,
        "version": version,
    }
    frame = {
        "v": 1,
        "id": args.id,
        "cmd": args.command,
        "args": json.loads(args.json),
        "owner": owner,
        "version": version,
    }
    if not isinstance(frame["args"], dict):
        raise ValueError("--json must decode to an object")

    path = socket_path(root)
    last_error = "initial socket connection failed"
    try:
        return exchange(path, hello, frame)
    except (ConnectionError, FileNotFoundError, OSError, socket.timeout) as error:
        last_error = str(error)
        start_daemon(root)

    for _ in range(10):
        time.sleep(0.2)
        path = socket_path(root)
        try:
            return exchange(path, hello, frame)
        except (ConnectionError, FileNotFoundError, OSError, socket.timeout) as error:
            last_error = str(error)
            continue
    request.last_error = "root=%s; last socket error=%s" % (root, last_error)
    return None


def main(args):
    try:
        answer = request(args)
    except (json.JSONDecodeError, OSError, ValueError) as error:
        print(f"yanad.client: {error}", file=sys.stderr)
        return EXIT_USAGE
    if answer is None:
        print(
            "yanad.client: no daemon answered (%s)"
            % getattr(request, "last_error", "no response detail"),
            file=sys.stderr,
        )
        return EXIT_NO_DAEMON
    print(json.dumps(answer, separators=(",", ":")))
    return 0 if answer.get("ok") else EXIT_REFUSE


if __name__ == "__main__":
    parser = Parser(description="Send one command to yanad")
    parser.add_argument("--root", required=True)
    parser.add_argument("--owner-pid", type=int, default=os.getpid())
    parser.add_argument("--id", required=True)
    parser.add_argument("--kind", choices=("launcher", "cli"), default="launcher")
    parser.add_argument("--servername")
    parser.add_argument("command")
    parser.add_argument("--json", default="{}")
    args = parser.parse_known_args()[0]
    raise SystemExit(main(args))
