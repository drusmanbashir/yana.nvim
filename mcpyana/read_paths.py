"""Apply ripgrep's path rules to names that exist only in memory."""

import fnmatch
import os
import re
from functools import cache
from pathlib import Path


def matches(path, pattern):  #AI
    """Match a ripgrep glob against a path relative to its rule directory."""
    alternatives = re.search(r"(?<!\\)\{([^{}]*,[^{}]*)\}", pattern)
    if alternatives:
        return any(matches(path, pattern[:alternatives.start()] + branch + pattern[alternatives.end():])
                   for branch in alternatives[1].split(","))
    anchored = pattern.startswith("/") or "/" in pattern
    parts = path.parts if anchored else path.parts[-1:]
    rules = pattern.lstrip("/").split("/")

    @cache
    def walk(i, j):
        if j == len(rules):
            return i == len(parts)
        if rules[j] == "**":
            if j == len(rules) - 1:
                return i < len(parts)
            return walk(i, j + 1) or (i < len(parts) and walk(i + 1, j))
        rule = re.sub(r"\\([*?\[\]])", r"[\1]", rules[j])
        return i < len(parts) and fnmatch.fnmatchcase(parts[i], rule) and walk(i + 1, j + 1)

    return walk(0, 0)


def glob_allows(path, glob):  #AI
    """Apply the optional single include or exclude glob."""
    if not glob:
        return True
    if glob.startswith("!"):
        paths = path.parents if glob.endswith("/") else (path, *path.parents)
        return not any(matches(part, glob[1:].rstrip("/")) for part in paths if part.parts)
    return not glob.endswith("/") and matches(path, glob)


def rules_from(path):  #AI
    """Read one optional ignore file, preserving escaped terminal spaces."""
    try:
        lines = path.read_text(encoding="utf-8", errors="replace").splitlines()
    except OSError:
        return ()
    return tuple(line.rstrip() if not line.endswith("\\ ") else line[:-2] + " " for line in lines)


def global_excludes(root, rules):  #AI
    """Find the global excludes file using ripgrep's config search order."""
    home = Path.home()
    config_home = Path(os.environ.get("XDG_CONFIG_HOME") or home / ".config")
    configs = (os.environ.get("GIT_CONFIG_GLOBAL"), home / ".gitconfig", config_home / "git/config",
               os.environ.get("GIT_CONFIG_SYSTEM") or "/etc/gitconfig")
    for config in configs:
        for line in rules(Path(config)) if config else ():
            entry = re.fullmatch(r'\s*excludesfile\s*=\s*"?\s*(\S+?)\s*"?\s*', line, re.IGNORECASE)
            if entry:
                return root / Path(entry[1]).expanduser()
    return config_home / "git/ignore"


def virtual_allowed(path, root, rules):  #AI
    """Check inherited ignore rules and hidden components for a no-disk name."""
    parents = tuple(path.parents)
    git_root = next((parent for parent in parents if (parent / ".git").exists()), None)
    sources = [(parent, parent / name) for name in (".rgignore", ".ignore") for parent in parents]
    if git_root:
        sources.extend((parent, parent / ".gitignore") for parent in parents if parent.is_relative_to(git_root))
        git_dir = git_root / ".git"
        if git_dir.is_file():
            git_dir = git_root / git_dir.read_text().removeprefix("gitdir: ").strip()
            common = git_dir / "commondir"
            if common.is_file():
                git_dir = git_dir / common.read_text().strip()
        sources.extend(((git_root, git_dir / "info/exclude"), (root, global_excludes(root, rules))))

    for entry in reversed((path, *(parent for parent in parents if parent != root and parent.is_relative_to(root)))):
        selected = None
        for base, file in sources:
            if entry != base and entry.is_relative_to(base):
                for rule in reversed(rules(file)):
                    if not rule or rule.startswith("#") or (rule.endswith("/") and entry == path):
                        continue
                    negated = rule.startswith("!")
                    pattern = rule[1:] if negated or rule.startswith(("\\!", "\\#")) else rule
                    if matches(entry.relative_to(base), pattern.rstrip("/")):
                        selected = negated
                        break
            if selected is not None:
                break
        if selected is False or (selected is None and entry.name.startswith(".")):
            return False
    return True
