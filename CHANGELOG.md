# Changelog

All notable changes to Yana are documented here. Versions follow Semantic
Versioning.

## 0.1.0-alpha.7 - 2026-09-13

First public release of this line. 0.1.0-alpha.6 was pushed and withdrawn
without a tag or GitHub release; everything listed under 0.1.0-alpha.6 ships in
0.1.0-alpha.7, together with the changes below.

### Changed

- **The UI dependency is the public `drusmanbashir/yana-ui.nvim`.** README,
  `:help yana` and the `:checkhealth yana` advice name it, and releases pin it
  to one commit in `scripts/release/yana-ui.pin`.
- **The retired `bin/yana-ollama-agent` helper is no longer packaged.** It stays
  in the development tree, unreferenced.

### Fixed

- **Neovim 0.11.x: a fully decided review turn now ends when no UI is
  attached** (headless or embedded use). The End-turn prompt mistook Neovim
  0.11's built-in `confirm()` for a test stub, so the review stayed open and
  the post-review `u` never installed.
- **The release archive includes every page and image README links to**
  (`docs/*.md`, `assets/*`); release verification fails on a dead local link in
  the export or the archive.

## 0.1.0-alpha.6 - 2026-09-12

### Fixed

- **`:YanaEdit` no longer silently promotes `config.options.mode` to unconfined
  `agentic`.** The first inline edit of a fresh, `mode = "inline"` session used
  to call `ui.lua`'s `set_mode(p, "agent")`; `config.resolve_mode()` treated
  the string `"agent"` as an alias for `"agentic"`, so a panel that was never
  asked to change mode silently flipped the whole session's confinement dial
  before the agent was even spawned — no hunk review, no sandbox, panel header
  reading `## Cursor · agentic`. `resolve_mode()`'s `"agent"` alias is removed
  (it errors loudly now — nothing legitimate used it); `:YanaEdit` asks a new
  `ui.panel_write_capable()` whether its panel can produce an edit at all and
  never assigns a mode itself, so only the documented mode-switch command
  (`:YanaMode` / `<M-t>`) may change `config.options.mode`. A mode = `"ask"`
  (read-only) session now refuses `:YanaEdit` with a named reason instead of
  silently promoting itself.
- **A sibling defect in the same "agent" ambiguity, in `agent.lua`**:
  `jail_session.mode` was fed the vendor's own CLI permission-mode string
  (`config.agent_permission_mode()`'s `"ask"`/`"agent"`/`"plan"` vocabulary)
  instead of yana's own mode dial, so `inline_exec_allowlist_active`
  (`shadow/jail.lua`) was always computed `false` for a genuine `inline` turn
  when `inline_exec_allowlist` was configured — masked for as long as the
  `"agent"` alias above existed. `agent.run()` now takes an explicit
  `req.yana_mode` field for this purpose; `req.mode` keeps its original,
  vendor-facing meaning.
- **`:checkhealth` now warns when the resolved agent binary is the raw,
  unwrapped `cursor-agent`** (its own probe output carrying `"not in the list
  of known options"` — Electron/Chromium rejecting yana's flags, exit 0, zero
  usable stream-json events). The new `exec:cursor-agent-wrapper` row names
  the resolved `cmd` and recommends a wrapper script in the
  `~/scripts/bin/cursor-cli` shape.

## 0.1.0-alpha.5 - 2026-08-26

### Added

- README Usage now includes the in-repository review clip exported as
  `assets/yana-review.gif`, with `assets/yana-review-still.png` available for
  release/package consumers that need a still image.
- Two review screencast takes landed as release assets: the first still/clip
  pair and the full-flow take covering a red hunk, typing inside and above the
  hunk, undo, and `cA`.
- **`YanaReviewSettled` `User` autocmd** (`doautocmd User YanaReviewSettled`,
  `data = { buf, turn, reason }`), fired exactly when a review-state
  transition has fully applied — hunk accept/reject, file accept/reject,
  undo/redo of a decision, review open, review close/abort, and reload. See
  `:help yana-events`. Lets tests (and integrations) poll for a positive
  product signal instead of guessing a fixed delay after a keypress.

### Changed

- **`diff_keymaps.both` renamed to `diff_keymaps.reject_file`** (default
  unchanged: `"cx"`). The old name borrowed Avante's `replace_in_file`
  "keep both" vocabulary for a binding that has only ever rejected the
  whole file. `both` still works as a deprecated alias — it wins only when
  `reject_file` is left unset — and warns once per session
  (`yana: diff_keymaps.both is deprecated; use reject_file`) when an
  operator sets it explicitly.
- Multi-session peer sockets now use a short owned directory and stderr
  listen-error reporting, so long matrix paths become a named INCONCLUSIVE
  instead of a hidden socket-length failure.

### Fixed

- Release gates no longer pass silently when a headless test row exits 0 after
  failing; rows now exit through `cquit`, and `tests/exit_path_gate.sh` rejects
  the old false-green pattern.
- `review_property_gate`, `inline_fcs_reload_gate`, and
  `inline_playground_gate` now run hermetically and stop writing to the
  operator's live `~/.local/state/nvim/yana.log`; `session_log_gate` remains
  red only for already-existing operator log lines.
- The internal render check's "wrong extent" comparison now sees every
  incoming-paint span a hunk owns, not just the first, when it runs the way
  `buffer_watch` and `:YanaRenderCheck` actually run it. A hunk split by a
  human row typed in its middle painted correctly but still logged
  `model_extent,leaked_decoration` — alpha.4's CHANGELOG entry for this class
  fixed the check's pure evaluation logic but not the data-gathering step
  that feeds it, so production never saw the multi-span data the fix needed.
- Issue 30 and issue 32 are closed in the ledger.

### Tests

- `tests/all_gates.sh` now runs `--prove-red` and refuses a PASS from a gate
  that cannot show its own planted failure path.
- Blind-wait triage classified the fixed-delay sites: observable waits were
  converted, fixture allowlists were named, and the remaining product-signal
  work is parked.

## 0.1.0-alpha.4 - 2026-08-26

### Added

- **macOS install path.** `scripts/install-deps.sh` detects Darwin, does not
  crash on stock bash 3.2, and only checks `cursor-agent`. Confined `ask` /
  `inline` stay Linux-only (no overlayfs/bwrap); agentic is the documented
  Mac option (`enable_agentic = true`, `mode = "agentic"`). `:checkhealth
  yana` names that split instead of "mount procfs". Birth-time probe uses
  Darwin `stat -f %B`. README Installation has a macOS section.
- `:YanaLog` opens the session log, refusing gracefully when nothing has
  been written yet (like `:LspLog`). `:YanaSetLogLevel {level}` sets the
  active log level and refuses an unrecognised level by name without
  changing the current one. `:YanaLogLevel` reports the level actually in
  effect. `setup({ log_level = ... })` sets it at startup. `WARN` stays the
  default.

### Changed

- Conversation-panel turn activity now reads in plain verbs —
  `✓ Edited · edit <path>`, `✓ Ran · ...` — replacing the previous
  gear-icon-prefixed jargon labels used for every tool call. The README's
  lazy.nvim quick-start block is now a complete, copy-pasteable
  configuration.
- The single-file-mode winbar banner is now sentence case —
  `Single-file mode · agent edits only <name> · ...` — instead of ALL CAPS.
  The word "edits" keeps its own highlight so the write-only restriction
  stays visible at a glance.
- Refusal reports now carry a machine-readable reason code plus
  category-specific evidence (the expected file state; for a stale-file
  refusal, the exact time the base fingerprint was captured) in both the
  turn journal and `yana.log`, instead of prose only. A refusal can now be
  greped and diagnosed after the fact instead of re-run to reproduce.
- **Reverses alpha.3's in-hunk rule.** A line you type inside a still-open
  hunk is never claimed by that hunk's decision — neither accept nor reject
  takes it, it stays yours, and the highlight band shows a gap at that row.
  Only the lines the agent's own patch introduced are ever treated as
  "yours" for that hunk's highlighting and accept/reject. Ownership above
  and below the hunk is unchanged (tree-sitter still rules there).
- The developer session-log gate's `--ack` now actually advances: it
  re-verifies the current log prefix, lists every pending item since the
  last acknowledgement, and refuses without `--yes`; `--ack --yes` freezes
  the newly reviewed bytes and moves the offset forward. A prefix that no
  longer verifies still refuses in both forms and never advances. Before
  this, `--ack` was an unimplemented stub and a leftover marker file forced
  the gate inconclusive permanently.

### Fixed

- The per-turn "## `<backend>` · `<mode>`" header at the top of each
  assistant reply, and the `SINGLE-FILE MODE` winbar banner, no longer go
  missing after the conversation-panel refresh — both had been silently
  dropped by it.
- A hunk with human-typed lines in its middle no longer trips a false
  "wrong extent" internal render check during review.
- The claim-store sweep's `reclaim.log` line said "the previous turn was
  terminated" whenever the kernel offered `cgroup.kill`, even when the
  cgroup was already empty; it now reports "terminated (pids: …)" only when
  a process was actually there, and "was empty" otherwise.

### Tests

- 75 headless test rows exited 0 on failure because `:qa!` ran before
  `os.exit`; they now exit non-zero via `:cquit`, and a new gate
  `tests/exit_path_gate.sh` refuses the pattern.
- `r_claim_orphan_sidecar_is_swept` reddened under machine load because its
  "live" holder was a 2-second sleep; it now holds the claim until after
  the assertion by construction.
- The multi-session rows' peer spawn waited a fixed 15 s for the peer
  Neovim's socket and `r_ms_holder_dies_reclaim` slept a fixed 500 ms for
  the holder to die; both now poll the observable, bounded only by the
  child process being alive, so machine load no longer reds them; five more
  rows that sampled state once now poll it the same way.

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

## Unreleased

### Added

- **Backend `state_dirs` configuration**: Each backend can declare directories that need to be writable at startup (e.g., cursor `~/.cursor`, `~/.config/cursor`; codex `~/.codex`; claude `~/.claude`, `~/.claude.json`). The overlay bind-mounts exactly those paths read-write; everything else under `$HOME` remains read-only. Paths outside `$HOME` or under protected directories (`~/.ssh`, `~/.gnupg`, `~/.aws`) are refused at setup with an error.

### Fixed

- **The agent runs as the invoking user; root is never exposed to it**: the sandbox launched with `bwrap --unshare-user --uid 0 --gid 0`, so every turn's agent ran as root. Electron-based CLIs refuse outright ("You are trying to start Cursor as a super user which isn't recommended..."), and everything a turn wrote came back root-owned. The launcher now passes the invoking `--uid`/`--gid`, so the namespace maps exactly one uid and uid 0 does not exist inside the sandbox to be reached. Because bwrap reaches a non-zero sandbox uid through an intermediate user namespace — leaving its mount namespace owned by an ancestor, where CAP_SYS_ADMIN does not satisfy `may_mount()` — `yana-overlay-inner` now re-execs itself under `unshare --mount` and mounts into a mount namespace of its own. `unshare` (util-linux) joins `bwrap` and `capsh` as a required executable. Capabilities are still dropped in full before the agent starts.

- **Vendor CLI state directory failures**: fixed "Read-only file system (os error 30)" when vendor CLIs (codex, claude, cursor) wrote their state directories at startup, which happens before the prompt is read and so refused the whole turn. The launcher binds each declared `state_dirs` entry read-write. They are staged inside bwrap's private `/tmp` and mounted onto their real paths after the overlay — so the write reaches the REAL host directory instead of the turn's disposable upper layer, where a refreshed credential would be discarded at release and the next turn would re-authenticate forever. The `~/.cursor` exception was corrected the same way, and for the same reason.

