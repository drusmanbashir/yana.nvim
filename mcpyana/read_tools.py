"""MCP reads from Run copies and searches the remaining files with ripgrep."""

import base64
import inspect
import os
import subprocess
from functools import cache
from itertools import islice
from pathlib import Path

from mcpyana.read_paths import glob_allows, rules_from, virtual_allowed


TEXT_LIMIT = 16_000
IMAGE_LIMIT = 5 * 1024 * 1024
MIME_TYPES = {".png": "image/png", ".jpg": "image/jpeg", ".jpeg": "image/jpeg",
              ".gif": "image/gif", ".webp": "image/webp"}
SCHEMAS = {
    "read": ("Read numbered lines from the Run copy or disk. Read a PNG, JPEG, GIF or WebP as an image.",
             ("name",), {"name": str, "offset": int, "limit": int}),
    "grep": ("Search Run copies and disk files using a ripgrep pattern.",
             ("pattern",), {"pattern": str, "path": str, "glob": str, "limit": int}),
    "list_files": ("List files and named Run copies under a directory, optionally matching a glob.",
                   (), {"path": str, "glob": str}),
}
TOOLS = [
    {"name": name, "description": description, "inputSchema": {
        "type": "object",
        "properties": {
            key: {"type": "integer", "minimum": 1} if kind is int else {"type": "string"}
            for key, kind in properties.items()
        },
        "required": list(required), "additionalProperties": False,
    }}
    for name, (description, required, properties) in SCHEMAS.items()
]


def text_content(lines, limit=None):  #AI
    """Bound a text result by bytes and, when supplied, by line count."""
    output, remaining = [], TEXT_LIMIT
    notice = "\n[output truncated]"
    for i, line in enumerate(lines):
        data = line.encode("utf-8", errors="replace")
        if len(data) + 1 > remaining or (limit is not None and i >= limit):
            if limit is None or i < limit:
                output.append(data[:max(remaining - len(notice), 0)].decode("utf-8", errors="ignore"))
            result = "\n".join(output).encode("utf-8", errors="replace")[:TEXT_LIMIT - len(notice)]
            return [{"type": "text", "text": result.decode("utf-8", errors="ignore") + notice}]
        output.append(line)
        remaining -= len(data) + 1
    return [{"type": "text", "text": "\n".join(output)}]


def rg(workspace, args, data=None):  #AI
    """Run only ripgrep with literal argv and report its command errors."""
    result = subprocess.run(["rg", "--no-config", "--color=never", *args], cwd=workspace, input=data,
                            stdin=subprocess.DEVNULL if data is None else None, capture_output=True)
    if result.returncode not in (0, 1):
        raise ValueError(result.stderr.decode("utf-8", errors="replace").strip())
    return result.stdout


class ReadTools:
    """Read-only view of one Run over its editor copies and readable files."""

    def __init__(self, host):  #AI
        self.host = host
        self.workspace = Path(os.environ.get("YANA_MCP_WORKSPACE") or Path.cwd()).resolve()

    async def call(self, tool, args):  #AI
        """Validate the tool request and capture its in-memory portion once."""
        _, required, fields = SCHEMAS[tool]
        if not set(required) <= args.keys() <= fields.keys() or any(
            type(value) is not fields[key] or (fields[key] is int and value < 1)
            or (fields[key] is str and (not value or "\0" in value)) for key, value in args.items()
        ):
            raise ValueError("invalid_arguments: check the tool's argument names and types")
        path = Path(args.get("name", args.get("path", "."))).expanduser()
        root = Path(os.path.abspath(self.workspace / path))
        if root.exists():
            root = root.resolve()
        copies = self.host.copies({"root": str(root)})
        if inspect.isawaitable(copies):
            copies = await copies
        if tool == "read":
            return self.read(root, copies, args)
        paths = self.paths(root, copies, args.get("glob"))
        if tool == "list_files":
            return text_content(self.display(path) for path in paths)
        return text_content(self.grep(paths, copies, args["pattern"], args.get("limit", 200)), args.get("limit", 200))

    def read(self, path, copies, args):  #AI
        """Return an image or a numbered, paged text result."""
        key = str(path)
        if key in copies:
            text = copies[key]
            if text is None:
                raise ValueError("file_deleted: the Run copy was deleted")
        else:
            if not path.is_file():
                raise ValueError(f"not a readable file: {path}")
            mime = MIME_TYPES.get(path.suffix.lower())
            with path.open("rb") as stream:
                data = stream.read(IMAGE_LIMIT + 1) if mime else stream.read()
            if mime:
                if len(data) > IMAGE_LIMIT:
                    raise ValueError("image exceeds the 5 MiB limit")
                return [{"type": "image", "mimeType": mime, "data": base64.b64encode(data).decode("ascii")}]
            text = data.decode("utf-8", errors="replace")
        if "\0" in text:
            raise ValueError("binary file: contains NUL bytes")
        offset = args.get("offset", 1)
        lines = text.removesuffix("\n").split("\n") if text else []
        lines = (str(i) + ": " + line.removesuffix("\r")
                 for i, line in enumerate(islice(lines, min(offset - 1, len(lines)), None), offset))
        return text_content(lines, args.get("limit", 2000))

    def paths(self, root, copies, glob):  #AI
        """Reconcile a disk inventory with deleted, edited and no-disk copies."""
        directory = root if root.is_dir() else root.parent

        def inventory(args):
            output = rg(directory, ["--files", "-0", *args, "--", str(root)])
            return {Path(os.fsdecode(name)) for name in output.split(b"\0") if name}

        paths = inventory([]) if root.exists() else set()
        if glob and paths:
            paths &= inventory(["--glob", glob])
        rules = cache(rules_from)
        for name, contents in copies.items():
            path = Path(name)
            if contents is None:
                paths.discard(path)
            elif not path.exists() and (path == root or (
                glob_allows(path.relative_to(root), glob) and virtual_allowed(path, root, rules)
            )):
                paths.add(path)
        return sorted(paths)

    def display(self, path):  #AI
        """Give project files stable workspace-relative names."""
        return str(path.relative_to(self.workspace) if path.is_relative_to(self.workspace) else path)

    def grep(self, paths, copies, pattern, limit):  #AI
        """Search disk candidates explicitly and Run copies over stdin."""
        args = ["-n", "--max-count", str(min(limit + 1, TEXT_LIMIT)), "-e", pattern]
        disk = [path for path in paths if str(path) not in copies]
        if not paths:
            rg(self.workspace, [*args, "--", "-"], b"")
        for start in range(0, len(disk), 128):
            paths_arg = [str(path) for path in disk[start:start + 128]]
            result = rg(self.workspace, ["-H", *args, "--", *paths_arg])
            prefix = str(self.workspace) + "/"
            yield from (line.removeprefix(prefix) for line in result.decode("utf-8", errors="replace").splitlines())
        for path in paths:
            if str(path) in copies:
                result = rg(self.workspace, [*args, "--", "-"], copies[str(path)].encode("utf-8"))
                yield from (f"{self.display(path)}:{line}" for line in result.decode("utf-8", errors="replace").splitlines())
