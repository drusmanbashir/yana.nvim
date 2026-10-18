# How it works

**Review model.** Every affected file receives its inline hunks and review
keys when a turn opens, including after a follow-up. `]x`/`[x` move between
hunks and files without closing another file's review; `ca` accepts a hunk,
`cr` rejects it, `cf` accepts the file, `cx` rejects the file's remaining
hunks, and `cA` accepts the whole turn. Undo walks the turn-global register
from the buffer of every file the turn has reviewed -- a parked member, or a
file a follow-up's undo took back out -- with `u` / `<C-r>` (one door;
no `:YanaUndo` / `:YanaRedo`); exhausting the register opens the End-turn
dialog. Whole-turn reset is `U` (every file back to the state you were first
shown). After End-turn, `u` / `<C-r>` are native Neovim. Nothing reaches disk
until you accept; accepted bytes are written through an applier that refuses
if the file drifted underneath.

**Confinement.** In `ask` and `inline`, the agent runs inside a sandbox
(bubblewrap). Proposed writes go into a private overlay; the agent's own
configuration and session directories may remain writable. The sandbox limits
writes; it does not prevent reading files your account can read. Refused
writes, including `.git/` metadata and paths outside the captured areas, are
named in the panel and in `:YanaRefusals`.

**Write scope.** An `inline` turn can propose edits anywhere in your home
folder, on every writable data disk (a mounted ordinary filesystem whose top
folder you can write) and in the turn's own folder, wherever the turn starts.
There is nothing to configure. The turn's folder is normally the nearest
`.git` root above the file, or the file's folder when there is no `.git` above
it. Other paths, such as system folders, stay read-only.

**Modes.** One dial, three results: `ask` (reads and answers, no edits),
`inline` (edits become hunks), `agentic` (direct, unconfined). `modes` picks
which of the three are available: the first entry is the starting mode,
`:YanaMode` cycles in that order, and a mode not listed cannot be entered.
Yana assigns no cycle shortcut; bind the command in your own keymap configuration.

**Backends and models.** Yana supports `cursor`, `claude`, and `codex`. Set
`backends.default` to choose the starting agent. Each named `backends` entry
can set `cmd` to a custom executable path and `model` to that agent's model ID.
The picker can change agent and model during a session; saved picker choices
continue to take precedence after restart. See
[configuration](configuration.md#agent-and-backend) for the setup syntax.

Yana applies the CLI sandbox policy automatically: ask uses read-only access,
while inline and agentic use full vendor access by default. Inline changes still
pass through Yana's overlay and review before they reach files.

**Machine-specific resolution.** Yana searches Neovim's `$PATH` for each CLI.
For a custom location, set `backends.<name>.cmd` to its path. `:checkhealth yana`
reports whether the selected executable was found.

**Liveness and logs.** While a turn runs the panel shows elapsed time and
activity — "working silently (CPU n%)" when a sub-agent is busy but quiet,
"stalled — :YanaStop" only when nothing moves. A stopped stall leaves a
forensics bundle and `bin/yana-stall-report` classifies every stalled turn by
cause.

**Where a turn may run.** The workspace can be any folder, including your
home folder itself when Neovim starts there with no file open; only `/` is
refused. `:Yana --workspace DIR` binds one turn to a named directory.

**Recovery.** One claim per workspace keeps two editors from clobbering each
other; a second turn on a busy repo is refused by name. If Neovim dies with a
review open, the next turn reclaims the dead editor's claim, keeps its
pending edits for recovery, and logs why. Sessions attach and recover only
while the daemon that owns them is still alive (`:YanaSessions`,
`:YanaRecover`), naming a still-open review's files instead of discarding
them; once that daemon dies the session dies with it — nothing resumes a
session from disk.

**Portability.** Tested on Neovim 0.11.2 and 0.12.4 on every change;
dependencies probed for real capability (user namespaces, GNU tools) not just
presence, with the exact `apt`/`dnf`/`pacman` line for anything missing.

**How confinement checks your machine.** Most required tools are checked by
name only, so a non-GNU build with the same name (e.g. BusyBox) can still
pass; `stat`, `find`, `date`, `bash`, and `bwrap` are checked functionally
instead (GNU stat/find/date behavior, bash 4.3+ nameref support, and a real
unprivileged-user-namespace probe), since those are the ones confinement
actually depends on beyond presence. The Linux/overlayfs/`/proc` requirement
is enforced only for confined modes (`ask`, `inline`); direct `agentic` mode
skips it entirely, since it never sandboxes. Confined-mode workspace approval
also requires the filesystem to report inode birth time (`stat %w`);
`:checkhealth yana` probes your current working directory for this. It also
distinguishes required tools from optional session-discovery helpers, names
the action that clears each failure, and checks Yana's own default panel
keymaps against anything already mapped: a genuine collision with a global
user/plugin mapping warns, naming both sides, while merely shadowing a
Neovim built-in is reported as INFO instead — Yana's panel keymaps are
buffer-local, so e.g. `<C-s>` submits inside the Yana prompt and leaves
signature-help's default insert-mode `<C-s>` untouched everywhere else.

The default steer key (`<C-CR>`) is indistinguishable from plain `<CR>` on
many terminals without the Kitty keyboard protocol or an equivalent, which
`:checkhealth yana` reports as INFO on a terminal it cannot confirm supports
it.

Yana ships no completion provider of its own, so `<C-Space>` only shows
Yana-scoped slash-command/@mention
completions when your own blink.cmp config special-cases
`vim.b.yana_prompt`, which `:checkhealth yana` also reports as INFO.
