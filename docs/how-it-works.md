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

**Tool permissions.** In `ask` and `inline`, Yana starts the agent in a
private directory and configures the agent CLI to permit Yana's workspace tools.
Reads see unsaved buffer text from submit time. In `inline`, the agent can
also submit changes for review. These modes trust the installed agent CLI
to enforce its tool permissions.

**Modes.** One dial, three results: `ask` (reads and answers, no edits),
`inline` (edits become hunks), `agentic` (direct, unconfined). `modes` picks
which of the three are available: the first entry is the starting mode,
`:YanaMode` cycles in that order, and a mode not listed cannot be entered.
Yana assigns no cycle shortcut; bind the command in your own keymap configuration.

**Backends and models.** Yana ships presets for `cursor`, `claude`, `codex`, and
`grok`, and offers only the agents your `backends` table lists plus
`backends.default`. Each entry can set `cmd`, `model`, `env` or any preset flag;
a new name adds an agent Yana has no preset for.
The picker can change agent and model during a session; saved picker choices
continue to take precedence after restart. See
[configuration](configuration.md#agent-and-backend) for the setup syntax.

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

**Recovery.** If Neovim crashes, Yana discards the open review. Your files
stay as they were at the crash.

**Portability.** Yana is tested on Neovim 0.11.2 and 0.12.4.

**How confinement checks your machine.** For `ask` and `inline`, Yana checks
Linux, `/proc`, cgroup v2 delegation, and the tools used by the launcher and
MCP server. It checks that `stat` reports filesystem type and owner. Direct
`agentic` mode skips these launcher checks.
`:checkhealth yana` distinguishes required tools from optional session-discovery helpers, names
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
