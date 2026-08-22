# Changelog

All notable changes to Yana are documented here. Versions follow Semantic
Versioning.

## 0.1.0-alpha.2 - 2026-08-21

### Added

- Capture root: the sandbox now mounts ONE overlay at the nearest `.git` root
  (or a configured root, or the opened folder), so an agent that edits a
  sibling repository or creates a directory that does not exist yet has its
  writes captured and reviewed instead of failing read-only. Each file the turn
  touched is claimed at finalize.
- Stall diagnosis: a turn that goes quiet is classified by cause (refusal spin,
  silent sub-agent, approval wait, pipe backpressure, network wait, vendor
  hang, or simply slow), the panel shows CPU-backed liveness instead of a
  guess, forensics are captured before anything is stopped, and
  `bin/yana-stall-report` aggregates it. Yana still never kills a turn itself.
- Review parking: `]x` on a file's last pending hunk moves to the next file
  with pending hunks without deciding anything, and the parked change returns
  at its original position.
- Session history: a review left open when Neovim dies is offered again on
  restart, with the files it can recover named.
- `inline_exec_allowlist` (ALPHA, off by default): a kernel execute rule for
  inline turns. Listed executables run, everything else is refused by the
  kernel, and every run and refusal is logged.
- `scripts/install-deps.sh`: the one-command dependency installer. Detects
  apt/dnf/pacman and prints a single copy-paste install line with the real
  package names for whatever's missing (e.g. `bubblewrap`, not `bwrap`);
  `--run` offers to install it (and `cursor-agent` via its official
  installer) after showing the exact command and asking `[y/N]`. Wired into
  the README's lazy.nvim quickstart via `build`.

### Fixed

- A review left open by an editor that died no longer locks the workspace: the
  next turn proves the holder dead, reclaims the claim, keeps the pending edits
  and records why in `reclaim.log`. The old failure came from the new editor
  stamping the dead one's marker with its own pid, so the evidence for "still
  alive" was self-made.

### Changed

- The winbar's mode chip carries the standout colour and the model chip is
  blue: the mode decides whether a turn answers, reviews, or writes, so it is
  the word to read first. `agentic` keeps a warning colour of its own.

## Unreleased

### Added

- Vendor→model convenience: `pick_vendor_then_model` (nvim `<leader>am`
  cascades layer 1 then layer 2; `:YanaBackend` / `:YanaModel` stay separate).
- Per-vendor model-list cache warmed at `setup()` so model picks open from
  `(cached)` without re-spawning the vendor CLI.
- `scripts/install-deps.sh`: the one-command dependency installer. Detects
  apt/dnf/pacman and prints a single copy-paste install line with the real
  package names for whatever's missing (e.g. `bubblewrap`, not `bwrap`);
  `--run` offers to install it (and `cursor-agent` via its official
  installer) after showing the exact command and asking `[y/N]`. Wired into
  the README's lazy.nvim quickstart via `build`.

### Changed

- README and `doc/yana.txt` lead with a copy-paste install block instead of
  a wall of requirements prose; the detailed requirements, usage, and
  configuration reference now live under a collapsed "Details" section.
- `dependencies.preflight()` now reports every missing required dependency
  in one refusal instead of only the first, and names
  `scripts/install-deps.sh` as the remedy. Health/preflight remedy text for
  `bwrap`, `capsh`, `flock`/`mount`/`umount`, `find`, `awk`, and `getent` now
  names the real distro package instead of the bare executable name.

### Security

- Removed the ambient-environment toggle that let `yana-turn finish` re-observe
  the workspace after classification instead of trusting the producer's own
  read, reopening the human-save race the fix it replaced had closed. An
  unsafe posture selectable by whatever an environment happens to export is a
  defect wearing a keystroke; the safe path is now the only path,
  unconditionally. A disposable mutation test preserves proof that restoring
  the unsafe behaviour turns the protection red; it is never live code.

## 0.1.0-alpha.1 - 2026-08-19

### Added

- Confined `cursor-agent` turns for ask and inline-edit workflows.
- Inline hunk review with per-hunk and per-file accept/reject decisions.
- Durable apply journal, crash recovery, workspace claims, and review timeline.
- Session resume, parallel panels, prompt queueing, and selection-scoped edits.
- Health diagnostics backed by the same dependency table as the turn preflight.
- Deterministic export, verification, and archive tooling (`scripts/release/`).

### Security

- Direct workspace-writing mode is disabled unless explicitly enabled.
- Confined turns fail closed when their host enforcement cannot be established.
