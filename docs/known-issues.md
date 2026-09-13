# Known issues

None of these lose data on disk — `:w` always withholds pending agent lines:

- **There is no trash store, so a proposed DELETE or CHMOD is not enabled
  yet.** A deletion should move a file to trash so the confirmation's undo is
  a real undo, not a nominal one — that trash store does not exist yet, so
  neither a delete nor a chmod proposal is reachable today; nothing is at risk
  in the meantime. (Undoing a file Yana itself created is a separate, already
  safe path: see the note on removal below.)
- **A hard crash during a review may leave one empty file behind.** Yana
  creates an agent-proposed new file on disk, EMPTY, the moment the turn
  proposes it, and removes it again at the last undo press, at `:qa`, at turn
  abort, at session death, or at end of turn if you rejected every hunk in it.
  A SIGKILL, an OOM kill or a power loss runs none of that cleanup, so a
  zero-byte file may survive at the proposed path. It contains nothing — no
  proposed line ever reaches disk without your own `:w` — and Yana never adopts
  it in a later session. Delete it if it bothers you.

- **The agent cannot edit any folder you point it at — the folder must be in
  your Yana roots first.** Yana confines every turn to a writable region chosen
  before the agent starts, from your configuration and the folder you opened.
  A write anywhere else fails with a read-only-filesystem error, is recorded,
  and names the folder you would have to add. Reading is unrestricted; only
  writing is bounded. Add a folder with `:YanaRoots`, or set `write_roots` in
  `setup{}`; either takes effect on your NEXT turn, because the writable region
  is mounted before the agent process exists and cannot be widened while it
  runs. This is deliberate: the boundary is what makes the review the only route
  from agent bytes to your files.
- **A vendor's system-wide sandbox can silently narrow an inline root.** Inline
  defaults to `sandbox.inline = "vendor-default"`, so Yana adds no second
  vendor sandbox over its own host-enforced overlay. This keeps every declared
  `write_roots` mount writable while everything outside the mounts stays
  read-only. A stricter vendor config can still refuse a declared root;
  `:checkhealth yana` warns and names the active backend and configuration key.
- **A vendor can hide a kernel refusal inside its JSON stream.** Yana records
  `system_refused` when the real vendor process exposes EROFS on stderr. Codex
  0.151.0 can instead put the child error inside JSON stdout, narrate the
  failure, and exit 0 without any EROFS-bearing stderr (unrelated warnings may
  still be present). Yana does not trust vendor-authored narration enough to
  create a filesystem fact, so that case has no structured refusal yet. The
  outside target remains unchanged because the kernel mount boundary still
  refused the write.
- **`:earlier` / `:later` / `g-` / `g+` rewind the WHOLE review, not one
  hunk.** Crossing the point where Yana inserted the proposal takes the whole
  review back — every decision in it, together — and crossing it forward
  again restores the exact proposal and reopens the same review with every
  hunk pending. Decisions are not stepped one at a time by time travel; use
  `u` / `<C-r>` for that. If the undo history itself is gone (`:bwipeout`,
  cleared undo), Yana says so rather than guessing.
- **Whole-file `cf` / `cx` inside a multi-file undo/redo walk** is being
  rebuilt as one register step; until it lands, `u` after `cf` may fragment
  across presses.
- **`o` / `O` on the edge of a one-line hunk** can grow the green band over your
  new line until the next repaint.
- **Crash + reopen** (SIGKILL) shows Neovim's own swap-file prompt (E325) before
  Yana restores the session; answer it as usual, the review state survives.
- **Undo-seq drift after `:bwipeout` / recreated undo tree** is named, not
  resynced: the proposal insertion is gone from the undo tree, so there is
  nothing left to rewind to or restore from.
- **Confined modes are Linux-only.** Overlay + hunk review (`ask`, `inline`)
  need bubblewrap, overlayfs, `/proc`, and capsh. macOS cannot provide those;
  Homebrew cannot either. On Darwin, preflight refuses confined turns (no
  silent fallback). **Agentic** works if your `modes` list includes
  `"agentic"` — the agent writes the real tree, with no overlay and no
  review. Windows is still unsupported. macOS itself is not tested on real
  hardware; the Darwin refusal path is covered only by an automated test, not
  a real Mac.
- **WSL2 is untested.** Yana has not been run against a WSL2 kernel. Ubuntu
  under WSL2 ships the same AppArmor user-namespace restriction as Ubuntu
  24.04 desktop, so expect the `bwrap:userns` remedy from `:checkhealth yana`;
  whether overlayfs behaves under WSL2's kernel has not been measured. Reports
  welcome.
- **Only x86_64 is tested.** Testing installs the x86_64 Neovim tarball.
  aarch64 Linux is expected to work (nothing in Yana is architecture-specific)
  but has not been run.
- **After End-turn, undo is Neovim's.** Ending the turn drops Yana's review
  keymaps; `u` / `<C-r>` become ordinary Neovim undo/redo on the buffer's own
  undo tree. During a live turn they walk the turn-global register only;
  there is no separate timeline journal or ex-command walk.
- **musl-based Linux (Alpine) does not work** with the official Neovim tarball:
  it is built against glibc and fails to load with `fcntl64: symbol not found`.
  This is Neovim's packaging, not Yana — but until a musl build is used, Alpine
  is out. Yana cannot print a cleaner refusal because Neovim itself fails to
  start before any plugin code runs.
- **REPL / SLIME integration is known to work only under the kitty terminal.**
  The whole suite (vim-slime / iron.nvim / neopyter routing, cells, traceback
  jump, REPL tail into the prompt) has been exercised only in kitty, which it
  uses for pane targeting. Other terminals are untested.

- **Removing a file is an unlink, not a move to your desktop trash.** The only
  removal path that exists today is undoing a file Yana created itself, and
  that only ever removes it while it is still byte-empty — a file you have
  since written to is refused rather than removed. A true DELETE or CHMOD
  proposal from the agent is not reachable yet (see the trash-store note
  above); it will need a real trash before it is enabled.

## Missing features

Deliberately not built. Each entry says what does not exist and why, so the
absence is a decision on record rather than a gap you discover mid-review.

- **Crash / session recovery.** If Neovim dies mid-review, the pending hunks
  are gone. Nothing was applied and the file on disk is untouched, so no work
  is lost from the file's point of view — but the review itself does not come
  back, and no prompt offers to restore it. What runs at the next start only
  releases the dead turn's lock on the project so the next editor is not
  refused. Restoring the review instead would mean bringing an older turn's
  decisions into a new editing session, and that reaches into every boundary
  the plugin is careful about at once: which project a dead session belongs to
  when repositories nest or share files, a lock still held by a process that no
  longer exists, an undo register that deliberately refuses to walk into an
  older turn, and a prompt that would have to fire before you have typed
  anything — including in scripted and headless starts where nobody is there to
  answer. The blast radius is not acceptable for the safety this would buy,
  so it is not planned. Save before you walk away; that is the whole remedy.
