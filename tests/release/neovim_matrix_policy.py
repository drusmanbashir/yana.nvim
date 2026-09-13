#!/usr/bin/env python3
"""PURPOSE: reds when CI installs a Neovim version absent from the immutable release matrix."""

from __future__ import annotations

import json
import re
import sys
from pathlib import Path
from typing import Any


VERSION_RE = re.compile(r"(?<![0-9.])([0-9]+\.[0-9]+\.[0-9]+)(?![0-9.])")
SHA256_RE = re.compile(r"[0-9a-f]{64}")


def fail(message: str) -> None:
    print(f"NEOVIM MATRIX POLICY FAIL: {message}", file=sys.stderr)


def workflow_install_versions(workflows_dir: Path) -> set[str]:
    versions: set[str] = set()
    workflow_paths = sorted((*workflows_dir.glob("*.yml"), *workflows_dir.glob("*.yaml")))
    if not workflow_paths:
        raise ValueError(f"no workflow files found under {workflows_dir}")

    def visit(value: Any) -> None:
        if isinstance(value, dict):
            for child in value.values():
                visit(child)
        elif isinstance(value, list):
            for child in value:
                visit(child)
        elif isinstance(value, str) and "scripts/release/install-neovim.sh" in value:
            versions.update(VERSION_RE.findall(value))

    for path in workflow_paths:
        try:
            visit(json.loads(path.read_text(encoding="utf-8")))
        except (OSError, UnicodeError, json.JSONDecodeError) as exc:
            raise ValueError(f"cannot parse workflow {path}: {exc}") from exc
    if not versions:
        raise ValueError("workflows contain no literal install-neovim versions")
    return versions


def matrix_rows(path: Path) -> dict[str, tuple[str, str]]:
    rows: dict[str, tuple[str, str]] = {}
    try:
        lines = path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeError) as exc:
        raise ValueError(f"cannot read {path}: {exc}") from exc
    for line_number, raw in enumerate(lines, 1):
        line = raw.strip()
        if not line or line.startswith("#"):
            continue
        fields = line.split()
        if len(fields) != 3:
            raise ValueError(f"{path}:{line_number}: expected version URL sha256")
        version, url, checksum = fields
        if version in rows:
            raise ValueError(f"{path}:{line_number}: duplicate version {version}")
        canonical_prefix = (
            f"https://github.com/neovim/neovim/releases/download/v{version}/"
        )
        if not url.startswith(canonical_prefix) or url.endswith("/"):
            raise ValueError(
                f"{path}:{line_number}: version {version} has mutable or non-versioned URL"
            )
        if SHA256_RE.fullmatch(checksum) is None:
            raise ValueError(
                f"{path}:{line_number}: version {version} checksum is not 64 lowercase hex"
            )
        rows[version] = (url, checksum)
    if not rows:
        raise ValueError(f"{path} has no Neovim rows")
    return rows


def main() -> int:
    if len(sys.argv) != 2:
        print(f"Usage: {sys.argv[0]} TREE", file=sys.stderr)
        return 2
    tree = Path(sys.argv[1]).resolve()
    try:
        workflow_versions = workflow_install_versions(tree / ".github" / "workflows")
        rows = matrix_rows(tree / "scripts" / "release" / "neovim-matrix.txt")
    except ValueError as exc:
        fail(str(exc))
        return 2

    missing = sorted(workflow_versions - rows.keys())
    if missing:
        fail(
            "workflow install-neovim version(s) absent from neovim-matrix.txt: "
            + " ".join(missing)
        )
        return 1
    unused = sorted(rows.keys() - workflow_versions)
    if unused:
        fail(
            "neovim-matrix.txt version(s) absent from workflow install requests: "
            + " ".join(unused)
        )
        return 1
    print(
        "NEOVIM MATRIX POLICY PASS: workflow versions="
        + " ".join(sorted(workflow_versions))
    )
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
