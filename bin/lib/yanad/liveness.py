import ctypes
import errno
import os
import socket
from pathlib import Path


def boot_id():
    return Path("/proc/sys/kernel/random/boot_id").read_text().strip()


def stat_fields(pid):
    """/proc/<pid>/stat from the state letter on. Split after the LAST ')' so a
    comm containing parens or spaces cannot shift the field numbering."""
    stat = Path(f"/proc/{pid}/stat").read_text()
    return stat.rsplit(")", 1)[1].split()


def start_ticks(pid):
    return int(stat_fields(pid)[19])


def pid_identity(pid):
    return {"pid": pid, "boot_id": boot_id(), "start_ticks": start_ticks(pid)}


def pidfd_open(pid):
    if hasattr(os, "pidfd_open"):
        return os.pidfd_open(pid)
    libc = ctypes.CDLL(None, use_errno=True)
    try:
        call = libc.pidfd_open
    except AttributeError as exc:
        raise OSError(errno.ENOSYS, "pidfd_open is unavailable") from exc
    call.argtypes = [ctypes.c_int, ctypes.c_uint]
    call.restype = ctypes.c_int
    fd = call(int(pid), 0)
    if fd < 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error))
    return fd


def identity_matches(owner):
    return owner_kind(owner) == "live"


def owner_kind(owner):
    if not owner:
        return "unknown"
    try:
        expected_boot = owner["boot_id"]
        expected_ticks = int(owner["start_ticks"])
        pid = int(owner["pid"])
    except (KeyError, TypeError, ValueError):
        return "unknown"
    try:
        current_boot = boot_id()
    except OSError:
        return "unknown"
    if expected_boot != current_boot:
        return "dead"
    try:
        # One read for both facts: two reads could straddle a pid being reaped
        # and recycled, and then the state would not belong to the ticks.
        fields = stat_fields(pid)
        current_ticks = int(fields[19])
        state = fields[0]
    except FileNotFoundError:
        return "dead"
    except (OSError, ValueError, IndexError):
        return "unknown"
    if expected_ticks != current_ticks:
        return "dead"
    # A ZOMBIE is an exit status, not a process: it holds no fd, no memory and
    # no lock, and it can never serve another frame. Reading it as "live" made a
    # successor daemon KEEP its predecessor's journal whenever the predecessor's
    # parent had not reaped it yet -- and the successor takes the lock the
    # instant the predecessor's fds close, which is exactly the zombie window.
    # Under init the window is microseconds; under any parent that waits later
    # (a test harness, a supervisor doing other work) it is however long that
    # parent takes.
    return "dead" if state == "Z" else "live"


def peer_uid(writer):
    override = os.environ.get("YANAD_TEST_PEER_UID")
    if override is not None:
        return int(override)
    sock = writer.get_extra_info("socket")
    if sock is None or not hasattr(socket, "SO_PEERCRED"):
        return os.getuid()
    creds = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, 12)
    return int.from_bytes(creds[4:8], "little")


def cwd_for(pid, fallback):
    try:
        return os.readlink(f"/proc/{pid}/cwd")
    except OSError:
        return fallback


def cgroup_matches(owner, cgroup):
    if not cgroup:
        return False
    root = Path(os.environ.get("YANAD_TEST_CGROUP_ROOT", "/sys/fs/cgroup")).resolve()
    path = Path(cgroup).resolve()
    try:
        relative = "/" + str(path.relative_to(root))
    except ValueError:
        return False
    if relative == "/.":
        relative = "/"
    proc_root = Path(os.environ.get("YANAD_TEST_PROC_ROOT", "/proc"))
    try:
        lines = (proc_root / str(int(owner["pid"])) / "cgroup").read_text().splitlines()
    except (OSError, KeyError, TypeError, ValueError):
        return False
    return any(line == f"0::{relative}" for line in lines)


def seal_cgroup(cgroup):
    if not cgroup:
        return "dead_unsealed", "no liveness cgroup was provided"
    root = Path(os.environ.get("YANAD_TEST_CGROUP_ROOT", "/sys/fs/cgroup")).resolve()
    path = Path(cgroup).resolve()
    try:
        path.relative_to(root)
    except ValueError:
        return "dead_unsealed", f"cgroup is outside {root}: {path}"
    try:
        if (path / "cgroup.kill").exists():
            (path / "cgroup.kill").write_text("1\n")
        path.rmdir()
        return "sealed", None
    except OSError:
        try:
            procs = " ".join((path / "cgroup.procs").read_text().split())
        except OSError:
            procs = ""
        reason = f"pids: {procs}" if procs else f"could not seal {path}"
        return "dead_unsealed", reason
