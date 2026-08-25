# Changelog

All notable changes to Yana are documented here. Versions follow Semantic
Versioning.

## Unreleased

### Added

- **macOS install path.** `scripts/install-deps.sh` detects Darwin, does not
  crash on stock bash 3.2, and only checks `cursor-agent`. Confined `ask` /
  `inline` stay Linux-only (no overlayfs/bwrap); agentic is the documented
  Mac option (`enable_agentic = true`, `mode = "agentic"`). `:checkhealth
  yana` names that split instead of "mount procfs". Birth-time probe uses
  Darwin `stat -f %B`. README Installation has a macOS section.

## 0.1.0-alpha.3 - 2026-08-25

### Changed

- **Minimum Neovim is now 0.11.2** (was 0.10.4), and `0.10.4` leaves
  `scripts/release/neovim-matrix.txt`. Neovim 0.10.x caps the tree-sitter
  parser ABI at 14 (`vim.treesitter.language_version` == 14; 0.11 and 0.12
  report 15), so it refuses every parser a current tree-sitter CLI produces
  with `ABI version mismatch ... supported between 13 and 14, found 15`.
  Without a tree, the hunk-edge ownership rule in `lua/yana/inline_diff.lua`
  cannot tell a human's boundary line from the agent's, and `:w` withholds
  the human's own line (matrix rows `r73_*`, `r113_undo_reopen_*` are red on
  0.10.4 and green on 0.11.2/0.12.4; hiding the parser on 0.11.2 reproduces
  the 0.10.4 reds exactly). No branch inside Yana can raise another program's
  ABI ceiling, so the floor moved rather than the claim staying false.


- Accepting a hunk in an open buffer no longer writes the file: the accepted
  lines become yours, the buffer turns `modified`, and your own `:w` writes
  them. Yana writes a file directly only when no buffer holds it (a queued
  file you never opened, or a create/delete/chmod). Undo after accept is a
  buffer edit again; drift on disk is Neovim's `W12` at `:w`.
- Rejecting a hunk takes your in-hunk typing with it: text you typed inside a
  pending hunk belongs to that hunk (accept keeps it, reject removes it). The
  old "ambiguous hunk, refused by name" path is gone.

### Added
- Single-file mode (ruling 94): a turn on a file in `$HOME`, a folder with no
  `.git`, or a folder over `single_file.max_entries` entries runs against a
  scratch copy under the state root; the agent may edit only that file,
  multi-file/create/delete are refused by name, and a `SINGLE-FILE MODE` banner
  sits under the prompt. `:Yana --file` forces it, `:Yana --workspace DIR`
  widens it. Review and `:w` stay in the real buffer (ruling 87). User guide:
  `:help yana-single-file`.

### Removed

- `backends.ollama` and the shipped local-Ollama offering (README, spec,
  and `lua/yana/config.lua`'s backend catalogue): operator ruling
  2026-08-23 — Ollama is a pure LLM, not an agent, so it does not work on
  the operator's system; it is delisted until an agent harness exists
  around it. `bin/yana-ollama-agent` stays in the tree, unreferenced, for
  when that harness exists; the internal feature record for this backend
  carries the retirement banner and return condition. Tests
  `tests/headless/backend_ollama_list_models.lua`,
  `tests/headless/pick_am_ollama.lua`, and `tests/ollama_agent_honesty_gate.sh`
  are removed; `tests/headless/backend_setup_refusal.lua`'s refusal-path
  coverage is unaffected (already exercised via `claude`/`codex` entries).

- **The built-in secret-path read mask is removed** (operator ruling
  2026-08-24). Yana no longer maintains its own list of ~17 credential paths
  to hide from the agent: a turn now reads exactly what your user account
  can read, the same as running the agent CLI directly. Write confinement,
  the overlay, claims and review are unchanged.

### Fixed
- `<C-r>` (ruling 75, one register): a decision undone by a cross-file `u`
  is put back by redo -- before, it was announced as redone and left pending
  (accept moves no bytes, so a bare `:redo` did nothing). Redo replays steps
  in reverse undo order across files from one stack; it no longer picks an
  older step in another file first, nor refuses with "no newer buffer state"
  while undone steps remain. A byte-less accept the walk reverted stays
  reverted while later rows are walked (it was being undone again after a
  human edit). Undoing into a file whose review was already reopened no
  longer withdraws its sibling hunk. The post-review typing watcher detaches
  under a reintegrated review (it recorded Yana's own redo as a human edit).
  Rows: `r75_redo_after_cross_file_undo_restores_accept`,
  `r75_redo_replays_mixed_decisions_in_order`,
  `r75_walk_never_reverts_same_row_twice`.

- Starting a turn with your home directory (or `/`, or a top-level folder such
  as `/home`) as the workspace is refused by name with the remedy "pick a
  project subdirectory", instead of the misleading `writable-host exception
  (~/.cursor) must be disjoint from the workspace` message.


- Undo (`u`) now rewinds a whole open review at the single insert boundary in
  one step, instead of being held back while a review is open or fighting
  the redo walk over which decision to undo first.
- Reloading a file from outside Neovim (a `git checkout`, another editor)
  while a review is open no longer drops the review's staged hunks, and
  per-hunk accept can now recover a hunk whose on-screen position moved
  instead of refusing it.
- Turning on Yana's `]x`/`[x` review navigation while a review buffer is
  focused no longer permanently swallows your own pre-existing `]x`/`[x`
  mapping.
- The release install manifest no longer misflags `bin/yana-release` (the
  tool that builds a release) as something that should have shipped inside
  its own export.
- Opening a review for the first time is fast again: it no longer waits on
  an internal disk sync for cross-file history bookkeeping, cutting a
  one-time ~146ms delay to under 1ms.

### Docs

- `:help yana-workspace` explains where a turn may run and how depth is
  counted.

## 0.1.0-alpha.2 - 2026-08-21

### Added

- Local Ollama backend in the model zoo (`backends.ollama` +
  `bin/yana-ollama-agent`): `<leader>am` / `:YanaBackend` list `ollama` and
  resolve the shim from the plugin `bin/` (no PATH install). Models come from
  the local Ollama daemon (`/api/tags`).
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
