"""Workspace identity for yanad U1."""

import hashlib
import os


def resolve_workspace(file):
    """Return nearest git workspace root, else the resolved file directory."""
    path = os.path.realpath(os.fspath(file))
    if os.path.isdir(path):
        directory = path
    else:
        directory = os.path.dirname(path)
    current = directory
    while current and current != os.path.dirname(current):
        if os.path.exists(os.path.join(current, ".git")):
            return current
        current = os.path.dirname(current)
    return directory


def workspace_slug(path):
    """Return Lua-compatible 16-hex workspace slug."""
    target = resolve_workspace(path)
    try:
        st = os.stat(target)
    except OSError:
        material = target
    else:
        material = "%d:%d" % (st.st_dev, st.st_ino)
    digest = hashlib.sha256(material.encode("utf-8")).hexdigest()
    return digest[:16]
