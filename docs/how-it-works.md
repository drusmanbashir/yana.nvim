# How it works

**Review model.** Every agent edit arrives as inline hunks in your real
buffers. `]x`/`[x` move between hunks and, at a file's edge, park the file and
move to the next one with pending hunks; `ca` accepts a hunk, `cr` rejects it,
`cf` accepts the file, `cx` rejects the file's remaining hunks, `cA` accepts
the whole turn — including parked hunks, since parking is navigation, never a
decision. Undo walks the turn-global register with `u` / `<C-r>` (one door;
no `:YanaUndo` / `:YanaRedo`); exhausting the register opens the End-turn
dialog. Whole-turn reset is `U` (every file back to the state you were first
shown). After End-turn, `u` / `<C-r>` are native Neovim. Nothing reaches disk
until you accept; accepted bytes are written through an applier that refuses
if the file drifted underneath.

**Confinement.** The agent runs inside a sandbox (bubblewrap) where the whole
host is read-only and one overlay layer captures every write inside your
workspace. Secret stores (`~/.ssh`, `~/.gnupg`, `~/.aws`, credential files)
are masked inside the sandbox. Writes Yana itself refuses (control-plane
paths like `.git/`, binary artifacts, anything outside the workspace) are
named in the panel and in `:YanaRefusals`, never dropped silently.

**Workspace scope.** A turn may write inside the workspace you opened — the
nearest `.git` root above the file, or the folder itself when there is no
`.git` above it. Anything outside that boundary stays read-only, and a
refusal always names the exact boundary that would allow it.

**Modes.** One dial, three results: `ask` (reads and answers, no edits),
`inline` (edits become hunks), `agentic` (direct, unconfined). `modes` picks
which of the three are available: the first entry is the starting mode,
`<M-t>` cycles in that order, and a mode not listed cannot be entered.
Switching mid-chat hands the next session a short brief of what you asked,
what landed, and what was refused, once.

**Backends — two layers of "which model".** Layer 1 is the backend: which
binary, which account, which bill (`cursor`, `claude`, `codex`, or a vendor
you add yourself). Layer 2 is the model within that backend. Conflating them
is a real trap: picking `claude-4-sonnet` *inside* `cursor-agent` is Cursor's
own resale of Claude, billed on Cursor's meter — a different product from
running `claude-sonnet-5` through your own Anthropic account, even though
both chips once said only `model: claude-4-sonnet`. `:YanaBackend` and
`:YanaModel` are deliberately different commands and keys so a mis-press
never changes the wrong one; switching backend always resets the model,
because a model id from one vendor is meaningless to another. A map of your
own can call the two in sequence — backend, then model — without merging
them. The active backend's model list is fetched the first time you open
the model picker, and then cached, so opening it again (or `:YanaModel`)
reads from memory instead of re-spawning the vendor CLI. A
`--resume`
session id is vendor-specific too: resuming a session recorded under a
different backend is refused by name, naming both backends.

Backends are declared in `config.backends` — a named table of vendor entries.
Three ship today (`cursor`, `claude`, `codex`); `codex`'s entry shows the fields a vendor whose
CLI shape genuinely differs needs (non-interactive mode as a subcommand
rather than a flag, a positional resume id, its own JSON stream token):

```lua
opts = {
  sandbox = { inline = "vendor-default", agentic = "full" },
  backends = {
    codex = {
      cmd = "codex",
      subcommand = { "exec" },
      noninteractive_flag = false,
      stream_protocol = "codex",
      stream_json_args = { "--json" },
      sandbox_args = {
        full = { "-c", 'sandbox_mode="danger-full-access"' },
        workspace = { "-c", 'sandbox_mode="workspace-write"' },
        ["read-only"] = { "-c", 'sandbox_mode="read-only"' },
        ["vendor-default"] = {},
      },
      allow_edits_args = { "--skip-git-repo-check" },
      select_model_flag = "--model",
      resume_subcommand = { "resume" },
      list_models_args = { "debug", "models" },
      list_models_format = "json_models",
      close_stdin = true,
    },
  },
}
```

`sandbox` uses Yana's four vendor-neutral levels: `full`, `workspace`,
`read-only`, and `vendor-default` (append no sandbox flag). Ask always uses
`read-only`; inline and agentic default to `vendor-default` and `full`. Each
shipped backend translates the selected level into its own measured CLI
spelling. Inline's default appends no vendor sandbox token because Yana's
overlay is the write boundary. A system-wide vendor config may narrow a
declared root; `:checkhealth yana` warns when inline inherits it.
Custom backends must declare all four `sandbox_args` entries. A token-bearing
map also needs dated vendor-version stamps; missing levels refuse at setup
instead of silently tightening a turn.

Every field is a spelling, never a policy: an entry can't make a turn
interactive, swap the event-stream format Yana parses, leave an edit-capable
mode silently unable to write, or inject a token Yana itself places. All of
it is validated by name at `setup()` time, never discovered mid-turn.

**Machine-specific resolution.** The agent binary resolves in order: an
explicit `cmd`, then `YANA_CURSOR_BIN`, then the environment variable named by
`cmd_env` (default `YANA_AGENT_BIN`), then `cursor-agent` on `$PATH`. Claude and
Codex similarly check `YANA_CLAUDE_BIN` and `YANA_CODEX_BIN` before their
standard command names. `:checkhealth yana`
reports which step resolved, and every candidate it tried.

**Liveness and logs.** While a turn runs the panel shows elapsed time and
activity — "working silently (CPU n%)" when a sub-agent is busy but quiet,
"stalled — :YanaStop" only when nothing moves. A stopped stall leaves a
forensics bundle and `bin/yana-stall-report` classifies every stalled turn by
cause. Every turn can record its raw agent stream and a per-event history
(`YANA_DEBUG_EVENTS`, `YANA_LIFECYCLE_LOG`, both off by default) under the
state root.

**Where a turn may run.** The workspace is any folder, not only a git
project, but never your whole home, `/`, or a top-level folder such as
`/home` or `/tmp` (fewer than two path components below `/`). Those are
refused by name with the remedy "pick a project subdirectory" — start Yana
inside `~/code/myproject`, `~/notes`, and so on. `:Yana --workspace DIR` binds
one turn to a named directory; the old `:Yana --file` shortcut now refuses by
name.

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
it — rebind it, e.g. `mappings.steer = "<M-CR>"`, if `<C-CR>` never
steers for you.

Yana ships no completion provider of its own, so `mappings.completion_menu`
(default `<C-Space>`) only shows Yana-scoped slash-command/@mention
completions when your own blink.cmp config special-cases
`vim.b.yana_prompt`, which `:checkhealth yana` also reports as INFO.
