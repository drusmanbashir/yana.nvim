# Yana

Yana is a Linux-only Neovim agent that runs `cursor-agent` inside a private
workspace layer, then presents its proposed edits as inline hunks. Real project
files remain unchanged until you accept a hunk, file, or turn.

## Quickstart

```lua
{
  "drusmanbashir/yana.nvim",
  cmd = { "Yana", "YanaAsk", "YanaEdit", "YanaOpen" },
  build = "scripts/install-deps.sh",
  opts = {
    global_keymaps = {
      toggle = "<leader>cc",
      ask = "<leader>ca", -- normal mode opens the panel; visual mode asks about the selection
      inline_edit = "<C-k>", -- visual mode
    },
  },
}
```

`build` runs `scripts/install-deps.sh` once, at install and update. It never
installs anything on its own — it only checks and prints the exact remedy for
whatever's missing on your distro, right there in lazy's install log.

Or manually:

```sh
git clone https://github.com/drusmanbashir/yana.nvim ~/.local/share/nvim/yana.nvim
~/.local/share/nvim/yana.nvim/scripts/install-deps.sh
```

```lua
vim.opt.runtimepath:prepend("~/.local/share/nvim/yana.nvim")
require("yana").setup({})
```

Requirements: Linux, Neovim 0.10.4+, `cursor-agent` — `scripts/install-deps.sh`
tells you the rest.

The normal workflow is:

1. Ask from the panel or select lines and open an inline edit.
2. Yana runs the agent in a confined overlay.
3. Proposed changes appear in the real source buffers.
4. You accept or reject them without giving the agent direct write access.

## What Yana does

**Review model.** Every agent edit arrives as inline hunks in your real
buffers. `]x`/`[x` move between hunks and, at a file's edge, park the file and
move to the next one with pending hunks; `ct` accepts a hunk, `co` rejects it,
`ca` accepts the file, `cb` rejects the file's remaining hunks, `cA` accepts
the whole turn. Undo
is per hunk (`u`) or per turn (`U`). Nothing reaches disk until you accept;
accepted bytes are written through a journaled applier that refuses if the
file drifted underneath.

**Confinement.** The agent runs inside a sandbox (bubblewrap) where the whole
host is read-only and one overlay layer captures every write under your code
tree — the opened repo, sibling repos, new directories — so cross-repo work is
reviewed rather than refused. Secret stores (`~/.ssh`, `~/.gnupg`, `~/.aws`,
credential files) are masked inside the sandbox. Writes Yana itself refuses
(control-plane paths like `.git/`, binary artifacts, anything outside the
capture root) are named in the panel and in `:YanaRefusals`, never dropped
silently.

**Modes.** One dial, three results: `ask` (reads and answers, no edits),
`inline` (default: edits become hunks), `agentic` (direct, unconfined — opt-in
with `enable_agentic`). Switching mid-chat hands the next session a short brief
of what you asked, what landed and what was refused, once.

**Liveness and logs.** While a turn runs the panel shows elapsed time and
activity — "working silently (CPU n%)" when a sub-agent is busy but quiet,
"stalled — :YanaStop" only when nothing moves. A stopped stall leaves a
forensics bundle (process state, vendor session files) and
`bin/yana-stall-report` classifies every stalled turn by cause. Every turn
records its raw agent stream, a per-event ledger and lifecycle rows (claim
open/release, review open, mode switch, refusals) under the state root.

**Recovery.** One claim per workspace keeps two editors from clobbering each
other; a second turn on a busy repo is refused by name. If Neovim dies with a
review open, the next turn reclaims the dead editor's claim, keeps its pending
edits for recovery, and logs why (`reclaim.log`). Sessions persist and resume
(`:YanaSessions`, `:YanaResume`), naming a still-open review's files instead
of discarding them.

**Portability.** Tested on Neovim 0.10.4, 0.11.2 and 0.12.4 on every change;
dependencies probed for real capability (user namespaces, GNU tools) not just
presence, with the exact `apt`/`dnf`/`pacman` line for anything missing.

## Next (not built yet)

Recorded in the private design notes; nothing here ships until it has tests.

- Prompt history: `<Up>`/`<Down>` in the prompt pane recall earlier prompts,
  newest first, like an agent CLI.
- File-keyed resume: opening a file offers the sessions that touched it.
- Chat picker: see and switch between ongoing chats from the keyboard.
- Install automation: `:YanaInstallDeps` fetches user-space dependencies.
- Agent profile file (JSON) and a provider-keyed backend abstraction (v2).
- Verbose agent-stream capture as an opt-in debug level.
- `inline_exec_allowlist` (alpha): a kernel execute rule for inline turns,
  off by default, with every run/refused command logged.

## Alternatives

Other ways to drive a coding agent from Neovim, and the `cursor-agent` CLI
on its own. The table describes mechanisms, not quality. Every cell quotes or
closely paraphrases the project's own README or docs as fetched on 2026-08-21;
"not documented" means that README did not state it, not that the feature is
absent. Projects move fast — check their current docs, and open an issue or
PR here if a cell is wrong.

| Mechanism | Yana | [avante.nvim](https://github.com/yetone/avante.nvim) | [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) | [claude-code.nvim](https://github.com/greggh/claude-code.nvim) | [sidekick.nvim](https://github.com/folke/sidekick.nvim) | [opencode.nvim](https://github.com/NickvanDyke/opencode.nvim) | [cursor-agent CLI](https://cursor.com/docs/cli/overview) |
|---|---|---|---|---|---|---|---|
| Where do agent edits land first? | In the real buffers as pending hunks; disk unchanged until accepted | Sidebar suggestions, applied to source with `a` / `A` ("One-Click Application") | not documented | On disk by the CLI; open files "automatically reloaded" | Next Edit Suggestions in the current buffer; CLI agents run in an integrated terminal | A new tab using Neovim's `:diffpatch` | not documented |
| How are edits reviewed? | Per hunk (`ct` / `co`), per file (`ca` / `cb`), per turn (`cA`); `u` / `U` retrace decisions while the review is open | `confirmation_ui_style`: `popup` or `inline_buttons` | "Code reviews enabling you to comment on and approve/reject agent code" | Handled by the Claude Code CLI's own flow; the plugin reloads files | "Hunk-by-Hunk Navigation" with Treesitter-highlighted diffs | Accept (`da`), reject (`dr`), or per hunk (`dp` / `do`) | Conversational session to "review proposed changes, and approve commands" |
| Is the agent's filesystem access restricted? | Yes: bubblewrap sandbox, host read-only, one overlay layer captures writes; version-control metadata refused | not documented | not documented | not documented | not documented | not documented | not documented |
| Are secret stores hidden from the agent? | Yes: `~/.ssh`, `~/.gnupg`, `~/.aws`, credential files masked inside the sandbox | not documented (scoped `AVANTE_` keys concern the plugin's own API keys) | not documented | not documented | not documented | not documented | Only the `sudo` password is documented: it "flows directly to `sudo` via a secure IPC channel; the AI model never sees it" |
| Two editors on the same tree? | One claim per workspace; a second turn on a busy repo is refused by name | not documented | not documented | not documented | not documented | not documented | not documented |
| Crash recovery of an open review? | Next turn reclaims a dead editor's claim and keeps its pending edits | not documented | not documented | not documented | not documented | not documented | not documented |
| Logging of agent actions? | Raw stream, per-event ledger and lifecycle rows per turn; stalled turns classified by cause | `prompt_logger` "logs prompts to disk (timestamped, for replay/debugging)" | `log_level = "DEBUG"` or `"TRACE"` | `:ClaudeCodeVerbose` "full turn-by-turn output" | `debug` option; see `:messages` | not documented | not documented |
| Agent backends | `cursor-agent` only | Claude, OpenAI, Azure, Gemini, Cohere, Copilot, Ollama, plus ACP agents | ACP and MCP; Claude Code, Codex, Copilot CLI, Gemini CLI, Goose, Cursor CLI, Kimi CLI, Kiro, Mistral Vibe, OpenCode | Claude Code CLI | Claude, Gemini, Grok, Codex, Copilot CLI "and more" | OpenCode | n/a (it is the agent) |
| Neovim version stated | 0.10.4+ (tested 0.10.4, 0.11.2, 0.12.4) | 0.11.0+ | not documented | 0.7.0+ | 0.11.2+ | not documented | n/a |

<details>
<summary><strong>Details</strong> — full requirements, usage, configuration, and security</summary>

### Requirements

- Linux with user namespaces, overlayfs, `/proc`, and Bubblewrap (`bwrap`).
- Neovim 0.10.4 or newer.
- `cursor-agent`, installed and signed in.
- Bash, Python 3, Bubblewrap, `capsh` (from `libcap2-bin` on Debian/Ubuntu or
  `libcap` on Fedora/Arch, used to drop capabilities before the confined
  agent starts), GNU coreutils/findutils, util-linux mount tools, `awk`,
  `sed`, `grep`, and the standard account/network lookup tools `hostname`,
  `getent`, and `id`. `scripts/install-deps.sh` checks all of these and
  prints one copy-paste install command with the real package names for
  your distro (apt/dnf/pacman); `:checkhealth yana` does the same check
  after `setup()` has run.

Most required tools are checked by name only, so a non-GNU build with the
same name (e.g. BusyBox) can still pass; `stat`, `find`, `date`, `bash`, and
`bwrap` are checked functionally instead (GNU stat/find/date behavior, bash
4.3+ nameref support, and a real unprivileged-user-namespace probe), since
those are the ones confinement actually depends on beyond presence. The
Linux/overlayfs/`/proc` requirement above is enforced only for confined
modes (`ask`, `inline`); direct `agentic` mode skips it entirely, since it
never sandboxes. Confined-mode workspace approval also requires the
filesystem to report inode birth time (`stat %w`); `:checkhealth yana`
probes your current working directory for this.

Run `:checkhealth yana` after installation. It distinguishes required tools
from optional session-discovery helpers and names the action that clears each
failure, and checks yana's own default panel keymaps against anything
already mapped: a genuine collision with a global user/plugin mapping warns,
naming both sides, while merely shadowing a Neovim built-in is reported as
INFO instead — yana's panel keymaps are buffer-local, so e.g. `<C-s>` submits
inside the yana prompt and leaves signature-help's default insert-mode
`<C-s>` untouched everywhere else.

The default steer key (`<C-CR>`) is indistinguishable from plain `<CR>` on
many terminals without the Kitty keyboard protocol or an equivalent, which
`:checkhealth yana` reports as INFO on a terminal it cannot confirm supports
it — rebind it, e.g. `keymaps = { steer = "<M-CR>" }`, if `<C-CR>` never
steers for you.

Yana ships no completion provider of its own, so `keymaps.completion_menu`
(default `<C-Space>`) only shows yana-scoped slash-command/@mention
completions when your own blink.cmp config special-cases
`vim.b.yana_prompt`, which `:checkhealth yana` also reports as INFO.

### Usage

| Command | Action |
|---|---|
| `:Yana` | Toggle the panel. |
| `:YanaOpen` / `:YanaClose` | Open or close the panel. |
| `:YanaAsk [question]` | Ask about the current line or visual selection. |
| `:YanaEdit [instruction]` | Edit the current line or visual selection through inline review. |
| `:YanaNew` / `:YanaNewPanel` | Start a new chat or an additional panel. |
| `:YanaSessions[!]` | Resume a session; `!` opens it in a new panel. |
| `:YanaMode` | Switch between `ask` and `inline` while the chat is quiescent: no running turn and no pending or open review. |
| `:YanaModel` | Select a model reported by `cursor-agent`. |
| `:YanaTimeline` | Show review decisions and later human edits for the file. |
| `:YanaRefusals` | List system-refused artifact operations and recovery paths. |
| `:YanaReview` | Open a pending inline review. |
| `:YanaAccept` / `:YanaReject` | Accept or reject the pending file change. |
| `:YanaStop` | Stop the running turn. |
| `:YanaQueue` | Manage queued follow-up prompts. |

During inline review:

| Key | Action |
|---|---|
| `co` | Reject the current hunk. |
| `ct` | Accept the current hunk. |
| `ca` | Accept all remaining hunks. |
| `cA` | Accept every pending change in the turn. |
| `cb` | Reject the entire file. |
| `]x` / `[x` | Move between hunks. |

### Configuration

```lua
require("yana").setup({
  -- cmd/cmd_env: see "Machine-specific configuration" below.
  model = nil,
  mode = "inline", -- "ask" or "inline"
  approve_mcps = false,
  -- Extra directory component names/globs for artifact grouping only. This can
  -- change binary recovery from durable to momentary; it never grants safety.
  artifact_dir_prefixes = {},

  -- Directories outside the opened workspace that a turn is allowed to write.
  write_roots = {},

  -- ALPHA. nil means inline turns may execute tools as before. Set
  -- executable basenames or paths to restrict inline child execution to
  -- exactly that list -- a real kernel (Landlock) rule, not a PATH trick,
  -- and the COMPLETE set of executables the turn may launch: that includes
  -- the agent binary itself, and every interpreter a shebang or `sh -c`
  -- needs (env, bash/sh, ...). A turn whose agent binary is not listed
  -- fails closed immediately, never a silent hang. Every run and every
  -- refusal is logged as exec.ran / exec.refused. Use agentic mode for
  -- compiler/test validation turns.
  inline_exec_allowlist = nil,

  selection_scope = {
    enforce = "reject",
    unstructured = "warn",
  },

  ui = {
    width = 0.40,
    position = "right",
    prompt_height = 6,
    show_usage = true,
  },

  global_keymaps = {
    toggle = nil,
    ask = nil,
    inline_edit = nil,
    inline_edit_normal = nil,
  },
})
```

#### Editing more than one repository in a turn

By default a turn may write exactly one directory: the one you opened. A write
anywhere else fails read-only, which is what stops an agent from editing half
your machine — but it also means a change that spans two repositories half
happens. `write_roots` is how you say, deliberately and in advance, which other
directories a turn may write:

```lua
require("yana").setup({
  write_roots = { "~/code/fran", "~/code/det3d" },
})
```

Each declared root is treated exactly like the workspace: its own private
overlay, its own lock, its own change set, and the same hunk-by-hunk review
before anything reaches the real file. The panel names the repository beside
each change once a turn has more than one. Everything you have not declared
stays read-only, and when a write is refused the panel now tells you the exact
`write_roots` line that would have allowed it.

Nothing the agent says can add a root — the list comes from your config and
nowhere else — and a root that does not exist, that overlaps another one, or
that is inside yana's own state directory refuses the turn by name before the
agent starts. Each extra root costs about 180 ms of setup per turn.

#### The capture root: one boundary instead of a list

Since 2026-08-20 a turn does not need that list for the common case. It mounts
**one** private overlay over a **capture root** — a directory that contains the
repository you opened — and everything beneath it is writable inside the jail:
the open repository, a sibling repository you never mentioned, a directory that
did not exist when the turn started. Every one of those writes goes into the
turn's private layer, nothing touches your real files until you accept a hunk,
and the review groups the hunks by the repository each file actually belongs to
(its nearest `.git` root), worked out from what the turn wrote rather than from
anything declared in advance. One mount and one lock, however many repositories
a turn ends up touching.

yana picks the capture root from where things are on disk: `~/code` when the
repository you opened is under it, otherwise your home directory, otherwise just
the repository — and never a directory that contains yana's own state. Set it
yourself to narrow or widen that choice:

```lua
require("yana").setup({
  capture_root = "~/code",     -- one boundary; no list to keep up to date
})
```

Anything outside the capture root is still read-only, and the refusal still
names the line that would allow it. The lock stays on the repository you opened,
so a second turn on a *different* repository under the same capture root starts
freely; if two turns end up proposing changes to the same file, both capture
privately and the second one to accept that file is refused by name, with the
other turn's review named as the holder. Nothing the agent says can choose the
capture root.

See `:help yana-configuration` for the complete option reference.

### Machine-specific configuration

Yana bakes in no usernames or absolute paths, and invents no environment
variable of its own that you have to remember: everything machine-specific is
a first-class `setup()` entry, resolved fresh each time it is needed.

The agent binary (`cursor-agent`) is the main example. Resolution order:

1. `cmd`, if you set it — an explicit path or name always wins outright.
2. The environment variable *named by* `cmd_env` (default `"YANA_AGENT_BIN"`),
   read lazily — the same indirection [avante.nvim] uses for provider API
   keys (`api_key_name`): you tell yana the NAME of a variable your shell
   already exports, and yana reads it at resolve time. Nothing secret or
   machine-specific is ever a default.
3. `cursor-agent` resolved on `$PATH`.

`~` is expanded on whichever candidate wins.

```lua
require("yana").setup({
  -- Leave unset to use $YANA_AGENT_BIN (if exported) or PATH. Set only if
  -- cursor-agent isn't on PATH and you don't want to use an env var:
  -- cmd = "~/.local/bin/cursor-agent",

  -- Point this at an env var YOUR shell already exports, if it isn't
  -- YANA_AGENT_BIN. For example, if your shell profile already has
  -- `export CURSOR_CLI_BIN=/path/to/cursor-agent`:
  -- cmd_env = "CURSOR_CLI_BIN",
})
```

`:checkhealth yana` reports exactly which of the three steps resolved (or
that none did) along with every candidate it tried, so a fresh machine tells
you *why* `cursor-agent` wasn't found instead of just that it wasn't.

Session storage (`sessions.dir`, `sessions.chats_dir`) and skill discovery
(`skill_dirs`) follow the same rule: every path defaults to a well-known
relative location (e.g. `~/.cursor/chats`, `stdpath("data")`) that is
expanded at the point of use, never hardcoded into the plugin, and always
overridable in `setup()`. A missing optional directory is reported, not
treated as an error — `:checkhealth yana` names what was found and what was
skipped.

[avante.nvim]: https://github.com/yetone/avante.nvim

### Security

`inline` and `ask` run in the host-enforced overlay. Yana treats prompts,
vendor permission modes, and agent self-reports as guidance, not containment.
In `inline` mode the agent receives the vendor permission-bypass flag so a
non-interactive turn can use tools; the overlay remains the enforcement
boundary, and the inline review gate decides what reaches your files. `ask`
mode never receives the bypass flag and has no review gate: it is
overlay-confined and its turns change nothing.

In `inline` mode, generated trees such as `target`, `build`, and
`__pycache__` are shown as one system-refused group per root and never enter
the real workspace. `:YanaRefusals` expands the complete per-operation
metadata. Artifact bytes are inspectable only until settlement; the metadata
survives for the newest five turns and at most seven days. Unsafe destructive
operations apply nothing, release the workspace lock, and report a preserved
recovery directory. `artifact_dir_prefixes` adds grouping names only: it can
change an individual binary proposal from durable recovery to momentary
retention, but cannot grant destructive safety or change the authoritative
change bundle.

**Warning:** direct (`agentic`) mode lets `cursor-agent` write your real
workspace with no overlay, no review, and no diary, and its turns also carry
the vendor permission-bypass flag. Nothing stands between the agent and your
files. It requires both settings:

```lua
require("yana").setup({
  enable_agentic = true,
  mode = "agentic",
})
```

Yana never falls back from a failed confined turn into direct mode. See
`:help yana-security`.

### Data

Session metadata and transcripts use `stdpath("data") .. "/yana"`. Durable
diagnostics use Neovim's state/log directories. Workspace-local review history
uses `.yana/`. Cursor credentials remain owned by `cursor-agent` under
`~/.cursor`.

### Release Policy

Yana follows Semantic Versioning. Before `1.0.0`, incompatible public changes
increment the minor version and compatible fixes increment the patch version.
Prereleases use tags such as `v0.1.0-alpha.1`, `v0.1.0-beta.1`, or
`v0.1.0-rc.1`; stable releases use `v0.1.0`.

### Licence

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for provenance.

</details>
