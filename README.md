# Yana

Yana was built after using the existing Neovim agent plugins and finding their
inline-edit and hunk-review experience unreliable: edits that landed in the
wrong place, a review that lost track of what had already been decided, an
undo that didn't actually take you back. Yana exists to make exactly that part
dependable — the agent proposes, you see every change as a hunk in your own
buffer, you accept or reject each one, and undo retraces your own steps, the
way the editor's own undo should. Nothing reaches disk until you say so.

## Features

- Ask the agent about your code without it touching anything (`ask` mode)
- Let it edit, and review every change as a hunk in your own buffer before it lands
- Accept or reject one hunk, one file, or the whole turn
- Undo your last decision — across files — and the hunk comes back where you can see it; redo it
- Reset the whole turn with one key
- Switch which agent answers — Cursor, Claude, or Codex — and which model, mid-chat
- Keep your unsaved typing: an accept never overwrites it
- Recover automatically if Neovim crashes mid-review
- Resume a past chat, with its open review intact
- Stop a stuck turn with one command
- See which model actually answered, and be told if it wasn't the one you asked for
- Edit just the selected lines without leaving the buffer
- Edit more than one repository in a single turn, reviewed the same way
- Queue several requests; they run in order
- Watch a turn work or stall, instead of a bare spinner
- See exactly what was refused, and why
- Restrict which programs an inline turn can execute, enforced by the kernel (alpha)
- Record a turn's raw output and per-event history for a bug report, on request
- The agent can't read your SSH keys or cloud credentials, or rewrite your git history

## Installation

Requirements: Linux, Neovim 0.10.4+, and one agent CLI signed in — `cursor-agent`,
`claude`, or `codex`.

Install the system packages:

**Debian / Ubuntu**
```sh
sudo apt-get install -y bubblewrap libcap2-bin python3 util-linux findutils gawk libc-bin hostname
```

**Fedora / RHEL**
```sh
sudo dnf install -y bubblewrap libcap python3 util-linux findutils gawk glibc-common hostname
```

**Arch**
```sh
sudo pacman -S --needed bubblewrap libcap python3 util-linux findutils gawk glibc inetutils
```

Everything else Yana needs — `bash`, `sed`, `grep`, and standard coreutils — ships
with any mainstream distro already. `scripts/install-deps.sh` (still in the repo)
checks the complete list against your actual machine and prints only what's
really missing; `:checkhealth yana` does the same check after `setup()` has run.

Then install whichever agent CLI you plan to use — `claude` and `codex` have
their own installers (see each vendor's docs); `cursor-agent`:

```sh
curl https://cursor.com/install -fsS | bash
```

### Environment variables

All optional. Yana reads these directly:

```sh
# Only needed if cursor-agent isn't already on $PATH:
export YANA_AGENT_BIN=~/.local/bin/cursor-agent

# Opt-in diagnostics, both off by default:
export YANA_DEBUG_EVENTS=1     # record every turn's raw agent stream
export YANA_LIFECYCLE_LOG=1    # record what each turn did, event by event
```

`YANA_AGENT_BIN` is just the *default* variable name — point `cmd_env` at any
variable your shell already exports and Yana reads that one instead:

```lua
require("yana").setup({ cmd_env = "CURSOR_CLI_BIN" })
```
```sh
export CURSOR_CLI_BIN=~/.local/bin/cursor-agent
```

To pick which account bills from your shell instead of `:YanaBackend` every
session, read your own variable in your lazy.nvim spec and pass it through —
Yana itself never reads `YANA_BACKEND`, this is just the pattern:

```lua
opts = function()
  return { backend = vim.env.YANA_BACKEND or "cursor" }
end
```

### With lazy.nvim

```lua
{
  "drusmanbashir/yana.nvim",
  cmd = { "Yana", "YanaAsk", "YanaEdit", "YanaOpen" },
  build = "scripts/install-deps.sh", -- re-checks and prints what's missing, on install/update
  opts = {
    global_keymaps = {
      toggle = "<leader>cc",
      ask = "<leader>ca", -- normal mode opens the panel; visual mode asks about the selection
      inline_edit = "<C-k>", -- visual mode
    },
  },
}
```

Or manually:

```sh
git clone https://github.com/drusmanbashir/yana.nvim ~/.local/share/nvim/yana.nvim
~/.local/share/nvim/yana.nvim/scripts/install-deps.sh
```

```lua
vim.opt.runtimepath:prepend("~/.local/share/nvim/yana.nvim")
require("yana").setup({})
```

## Default setup configuration

```lua
require("yana").setup({
  backend = "cursor",         -- "cursor" | "claude" | "codex" | your own entry in `backends`
  cmd = nil,                  -- explicit path/name; see "Environment variables" above
  cmd_env = "YANA_AGENT_BIN",
  model = nil,
  mode = "inline",             -- "ask" | "inline" | "agentic"
  enable_agentic = false,
  approve_mcps = false,

  -- Extra directories a turn may write, beyond the one you opened.
  write_roots = {},

  -- ALPHA, nil by default: restrict inline execution to exactly this list.
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
    show_thinking = false,
  },

  diff_highlights = {
    incoming = { link = "DiffAdd" },
    deleted = { link = "DiffDelete" },
    hint = { link = "Comment" },
  },

  -- Review, in the file buffer while hunks are open:
  diff_keymaps = {
    ours = "co",
    theirs = "ct",
    all_theirs = "ca",
    all_changes = "cA",
    both = "cb",
    next = "]x",
    prev = "[x",
  },
  -- The chat panel:
  keymaps = {
    submit = "<C-s>",
    submit_normal = "<CR>",
    new_chat = "<C-n>",
    toggle_mode = "<M-t>",
    resend = "<M-r>",
    model = "<C-g>",
    backend = "<C-b>",
    review = "<C-y>",
    accept = "<C-a>",
    reject = "<C-x>",
    stop = "<C-c>",
    sessions = "<M-s>",
    new_panel = "<M-n>",
    queue = "<M-q>",
    steer = "<C-CR>",
    completion_menu = "<C-Space>",
    focus_prompt = "i",
    close = "q",
  },
  -- Off (nil) by default; only applied if you set them:
  global_keymaps = {
    toggle = nil,            -- e.g. "<leader>cc"
    ask = nil,               -- e.g. "<leader>ca"
    inline_edit = nil,       -- visual mode, e.g. "<C-k>"
    inline_edit_normal = nil,
  },
})
```

See `:help yana-configuration`
for the complete option reference, and "How it works" below for `backends`,
multi-repository turns, and machine-specific resolution of `cmd`.

## Usage

1. Ask from the panel, or select lines and open an inline edit.
2. The agent works; nothing it does touches your real files yet.
3. Its proposed changes appear in your real buffers as hunks.
4. You accept or reject each one — only what you accept reaches disk.

## Key Bindings

### Review — in the file buffer, while hunks are open

| Key | Action |
|---|---|
| `ct` | Accept the current hunk |
| `co` | Reject the current hunk |
| `ca` | Accept all remaining hunks in the file |
| `cb` | Reject the entire file |
| `cA` | Accept every pending change in the turn |
| `]x` / `[x` | Next / previous hunk |
| `u` | Undo your last decision (retraces across files once this file's own history is empty) |
| `U` | Undo the whole turn — every file, back to where you started |
| `<C-r>` | Redo |

### Panel — the chat pane

| Key | Action |
|---|---|
| `<C-s>` / `<CR>` | Submit prompt (insert / normal mode) |
| `<C-n>` | Start a new chat |
| `<M-t>` | Cycle mode |
| `<M-r>` | Resend the last prompt |
| `<C-g>` | Pick the model (layer 2: within the active backend) |
| `<C-b>` | Pick the backend (layer 1: which binary/account/bill) |
| `<C-y>` | Open review for a pending change |
| `<C-a>` / `<C-x>` | Accept / reject a pending change |
| `<C-c>` | Stop the in-flight response |
| `<M-s>` | Pick a session |
| `<M-n>` | Open an additional panel |
| `<M-q>` | View/edit the queue |
| `<C-CR>` | Steer: interrupt and resend the prompt as a new turn |
| `<C-Space>` | Open the completion menu |
| `i` | Focus the prompt |
| `q` | Close the panel |

### Global — set these yourself; unset by default

| Setting (`mappings.global`) | Example | Action |
|---|---|---|
| `toggle` | `<leader>cc` | Open/close the panel from any buffer |
| `ask` | `<leader>ca` | Ask about the current line/selection (normal + visual) |
| `inline_edit` | `<C-k>` | Inline edit the visual selection |
| `inline_edit_normal` | — | Inline edit the current line (usually left unset) |

## Commands

| Command | Action |
|---|---|
| `:Yana` / `:YanaToggle` | Toggle the panel |
| `:YanaOpen` / `:YanaClose` | Open or close the panel |
| `:YanaAsk [question]` | Ask about the current line or visual selection |
| `:YanaEdit [instruction]` | Edit the current line or visual selection through inline review |
| `:YanaNew` | Start a new chat |
| `:YanaNewPanel` | Open an additional panel (parallel session) |
| `:YanaSessions[!]` | Pick a previous session to view/resume; `!` opens it in a new panel |
| `:YanaResume [id]` | Resume the latest (or a specific) session |
| `:YanaMode` | Cycle the agent mode |
| `:YanaModel` | Pick the model (layer 2: within the active backend) |
| `:YanaBackend` | Pick the backend (layer 1: which binary/account/bill) |
| `:YanaDiff` | View agent file changes as a diff (read-only) |
| `:YanaTimeline` | Show review decisions and later human edits for the file |
| `:YanaRefusals` | List system-refused operations and recovery paths |
| `:YanaReview` | Open a pending inline review |
| `:YanaAccept` / `:YanaReject` | Accept or reject the pending file change |
| `:YanaAbortReview` | Abort the open review: put the file back as it was before the hunks appeared |
| `:YanaUndo` / `:YanaRedo` | Step back/forward through your action history across every file, once at least one file's own review has closed |
| `:YanaStop` | Stop the in-flight response |
| `:YanaSteer` | Interrupt the in-flight response and resend the prompt as a new turn |
| `:YanaQueue` | View/edit/delete/reorder queued follow-up prompts |
| `:YanaPasteImage` | Paste an image from the system clipboard into the prompt (when `image_paste.enable = true`, the default) |
| `:YanaDump` | Write a diagnostic dump of the current turn and review state, for bug reports |
| `:YanaFlowReport[!]` | Write the per-turn flow report (`!` also opens it) |
| `:YanaRenderCheck` | Reconcile every open review's display against its actual state |
| `:YanaDiffThemes` | Live-preview Yana's inline diff color themes |

## Highlight Groups

| Group | Paints | Configured via |
|---|---|---|
| `YanaDiffIncoming` | Added/incoming lines in an open review | `diff_highlights.incoming` (default links to `DiffAdd`) |
| `YanaDiffDeleted` | Removed lines in an open review | `diff_highlights.deleted` (default links to `DiffDelete`) |
| `YanaInlineHint` | The hint text between hunks | `diff_highlights.hint` (default links to `Comment`) |
| `YanaModeAsk` / `YanaModeInline` / `YanaModeAgentic` | The mode chip in the winbar | `mode_highlights.ask` / `.inline` / `.agentic` |
| `YanaModel` | The model chip in the winbar | `model_highlight` |

## Alternatives

Other ways to drive a coding agent from Neovim, and the `cursor-agent` CLI on
its own. The table describes what each tool lets you do, not how well. Every
cell quotes or closely paraphrases the project's own README or docs as
fetched on 2026-08-21; "not documented" means that README did not state it,
not that the feature is absent. Projects move fast — check their current
docs, and open an issue or PR here if a cell is wrong.

| | Yana | [avante.nvim](https://github.com/yetone/avante.nvim) | [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) | [claude-code.nvim](https://github.com/greggh/claude-code.nvim) | [sidekick.nvim](https://github.com/folke/sidekick.nvim) | [opencode.nvim](https://github.com/NickvanDyke/opencode.nvim) | [cursor-agent CLI](https://cursor.com/docs/cli/overview) |
|---|---|---|---|---|---|---|---|
| Does the agent write directly to my files, or do I see it first? | I see it first — every change appears as a hunk in my own buffer; nothing reaches disk until I accept it | Review first by default: `auto_apply_diff_after_generation` is `false`; sidebar suggestions apply with a single command once I choose to | not documented (says only "code reviews enabling you to comment on and approve/reject agent code") | Writes land on disk via the Claude Code CLI itself; the plugin's job is reloading files that changed underneath you | Not fully documented; Next Edit Suggestions apply in the current buffer, and CLI agents get "Hunk-by-Hunk Navigation: jump through edits to review them one by one before applying" | Opens the file in a new tab and shows proposed changes side-by-side via Neovim's `:diffpatch` before I accept | Interactive sessions let me "review proposed changes, and approve commands"; not documented whether edits land before or after that review |
| Can I accept or reject one change without touching the rest? | Yes — one hunk (`ct`/`co`), one file (`ca`/`cb`), or the whole turn (`cA`) | Partially — apply at cursor (`a`) or apply all (`A`); diff mode adds "choose ours" / "choose theirs" / "choose both", no documented per-hunk reject beyond that | not documented beyond "approve/reject agent code" | not documented | "Hunk-by-Hunk Navigation" reviews one hunk at a time; whether I can reject just one is not documented | Yes — `dp` accepts only the hunk under the cursor, `do` rejects only the hunk under the cursor | not documented |
| If I made a mistake, can I undo just that one change? | Yes — `u` retraces my own actions backwards across every file in the turn, and the hunk comes back where I can see it; `U` resets the whole turn | not documented | not documented | not documented | not documented (ordinary Neovim undo only) | not documented (a `session.undo` command exists; its scope isn't stated) | not documented |
| Can the agent wreck my repo? | Not in the default modes — a turn can't reach `.git`, credentials, or anything outside the project I opened until I accept a change; the opt-in `agentic` mode removes this protection entirely | not documented | not documented | not documented | not documented | not documented | Partially — a `--sandbox <mode>` / `/sandbox` setting toggles command-execution sandboxing; file-write restrictions aren't documented |
| Can the agent read my SSH keys, cloud credentials, or other secrets? | No — `~/.ssh`, `~/.gnupg`, `~/.aws`, and other credential files are kept out of its reach | not documented (scoped `AVANTE_`-prefixed keys concern the plugin's own API keys, not files hidden from the agent) | not documented | not documented | not documented | not documented | Only the `sudo` password is documented: it "flows directly to `sudo` via a secure IPC channel; the AI model never sees it" |
| What happens if I open two editors on the same project? | Refused by name — only one editor's turn can work on a project at a time, so two editors never overwrite each other's changes | not documented | not documented | not documented | not documented | not documented | not documented |
| What happens if Neovim crashes mid-review? | Recovered on my next turn — pending edits are kept, and Yana says why | not documented | not documented | not documented | not documented | not documented | not documented |
| Can I see exactly what the agent did? | Yes — every turn's actions are recorded, and a stalled turn is diagnosed by cause instead of a bare spinner | Yes — `prompt_logger` "logs prompts to disk (timestamped, for replay/debugging)" | Yes — `log_level = "DEBUG"` or `"TRACE"`, path shown via `:checkhealth codecompanion` | Yes — `:ClaudeCodeVerbose` gives "full turn-by-turn output" | Yes — a `debug` config option; see `:messages` | not documented | not documented |
| Which accounts can I run this on — do I pay Cursor's markup, or my own provider? | Three, switchable mid-chat: my own Cursor, Anthropic (Claude), or OpenAI (Codex) account — I choose whose bill it is, not just which model answers | Many — Claude, OpenAI, Azure OpenAI, Gemini, Cohere, Copilot, Bedrock, Moonshot, Ollama, plus Morph (Fast Apply) and ACP agents; scoped API keys "recommended for isolation" let me bring my own per provider | Many — Anthropic, DeepSeek, Google Gemini, GitHub Copilot, GitHub Models, Kimi, Mistral, Novita, Ollama, OpenAI, Azure OpenAI, OpenRouter, HuggingFace, xAI "out of the box (or bring your own)", plus ACP/MCP agent CLIs: Claude Code, Codex, Copilot CLI, Gemini CLI, Goose, Cursor CLI, Kimi CLI, Kiro, Mistral Vibe, OpenCode | One — the Claude Code CLI only | Many CLIs listed — Aider, Amazon Q, Claude, Codex, Copilot, Crush, Cursor, Gemini, Grok, OpenCode, Pi, Qwen — each on its own account; not brokered by the plugin | One — locked to the OpenCode server | n/a — it is the account being billed |
| What Neovim version do I need? | 0.10.4+ (tested on 0.10.4, 0.11.2, 0.12.4) | 0.11.0+ | not documented | 0.7.0+ | 0.11.2+ | not documented | n/a |

## Roadmap

Recorded in the private design notes; nothing here ships until it has tests.

- Prompt history: `<Up>`/`<Down>` in the prompt pane recall earlier prompts,
  newest first, like an agent CLI.
- File-keyed resume: opening a file offers the sessions that touched it.
- Chat picker: see and switch between ongoing chats from the keyboard.
- Install automation: `:YanaInstallDeps` fetches user-space dependencies.
- Agent profile file (JSON): a declarative alternative to configuring
  backends only in Lua.

<details>
<summary><strong>How it works, security, data, and release policy</strong></summary>

### How it works

**Review model.** Every agent edit arrives as inline hunks in your real
buffers. `]x`/`[x` move between hunks and, at a file's edge, park the file and
move to the next one with pending hunks; `ct` accepts a hunk, `co` rejects it,
`ca` accepts the file, `cb` rejects the file's remaining hunks, `cA` accepts
the whole turn — including parked hunks, since parking is navigation, never a
decision. Undo is per hunk (`u`, falling through to a cross-file order index
once the current file's own history is empty) or per turn (`U`, which puts
every file of the turn back to the state you were first shown, reopening any
file already closed and writing an already-accepted file back to disk with
its own notice). Nothing reaches disk until you accept; accepted bytes are
written through an applier that refuses if the file drifted underneath.

**Confinement.** The agent runs inside a sandbox (bubblewrap) where the whole
host is read-only and one overlay layer captures every write under your code
tree — the opened repo, sibling repos, new directories — so cross-repo work is
reviewed rather than refused. Secret stores (`~/.ssh`, `~/.gnupg`, `~/.aws`,
credential files) are masked inside the sandbox. Writes Yana itself refuses
(control-plane paths like `.git/`, binary artifacts, anything outside the
capture root) are named in the panel and in `:YanaRefusals`, never dropped
silently.

**Multiple repositories.** By default a turn may write exactly the directory
you opened; `write_roots` declares other directories a turn may also write,
each with its own private capture, lock, change set, and review before
anything reaches the real file. Since 2026-08-20 the common case needs no
list at all: one overlay mounts over a capture root (usually `~/code`) that
contains the repository you opened, and anything beneath it — a sibling repo
you never mentioned, a directory that didn't exist when the turn started — is
captured too, with hunks grouped by each file's own nearest `.git` root.
Anything outside the capture root stays read-only, and a refusal always names
the `write_roots` line that would allow it.

**Modes.** One dial, three results: `ask` (reads and answers, no edits),
`inline` (default: edits become hunks), `agentic` (direct, unconfined —
opt-in with `enable_agentic`). Switching mid-chat hands the next session a
short brief of what you asked, what landed, and what was refused, once.

**Backends — two layers of "which model".** Layer 1 is the backend: which
binary, which account, which bill (`cursor`, `claude`, `codex`, or a vendor
you add yourself). Layer 2 is the model within that backend. Conflating them
is a real trap: picking `claude-4-sonnet` *inside* `cursor-agent` is Cursor's
own resale of Claude, billed on Cursor's meter — a different product from
running `claude-sonnet-5` through your own Anthropic account, even though
both chips once said only `model: claude-4-sonnet`. `:YanaBackend` and
`:YanaModel` are deliberately different commands and keys so a mis-press
never changes the wrong one; switching backend always resets the model,
because a model id from one vendor is meaningless to another. A `--resume`
session id is vendor-specific too: resuming a session recorded under a
different backend is refused by name, naming both backends.

Backends are declared in `config.backends` — a named table of vendor entries
(avante.nvim's `providers` shape, applied to a CLI agent instead of an HTTP
provider). Three ship today; `codex`'s entry shows the fields a vendor whose
CLI shape genuinely differs needs (non-interactive mode as a subcommand
rather than a flag, a positional resume id, its own JSON stream token):

```lua
require("yana").setup({
  backends = {
    codex = {
      cmd = "codex",
      subcommand = { "exec" },
      noninteractive_flag = false,
      stream_protocol = "codex",
      stream_json_args = { "--json" },
      allow_edits_args = { "--sandbox", "workspace-write", "--skip-git-repo-check" },
      select_model_flag = "--model",
      resume_subcommand = { "resume" },
      list_models_args = { "debug", "models" },
      list_models_format = "json_models",
      close_stdin = true,
    },
  },
})
```

Every field is a spelling, never a policy: an entry can't make a turn
interactive, swap the event-stream format Yana parses, leave an edit-capable
mode silently unable to write, or inject a token Yana itself places. All of
it is validated by name at `setup()` time, never discovered mid-turn.

**Machine-specific resolution.** The agent binary resolves in order: an
explicit `cmd`, then the environment variable named by `cmd_env` (default
`YANA_AGENT_BIN`), then `cursor-agent` on `$PATH`. `:checkhealth yana`
reports which step resolved, and every candidate it tried.

**Liveness and logs.** While a turn runs the panel shows elapsed time and
activity — "working silently (CPU n%)" when a sub-agent is busy but quiet,
"stalled — :YanaStop" only when nothing moves. A stopped stall leaves a
forensics bundle and `bin/yana-stall-report` classifies every stalled turn by
cause. Every turn can record its raw agent stream and a per-event history
(`YANA_DEBUG_EVENTS`, `YANA_LIFECYCLE_LOG`, both off by default) under the
state root.

**Recovery.** One claim per workspace keeps two editors from clobbering each
other; a second turn on a busy repo is refused by name. If Neovim dies with a
review open, the next turn reclaims the dead editor's claim, keeps its
pending edits for recovery, and logs why. Sessions persist and resume
(`:YanaSessions`, `:YanaResume`), naming a still-open review's files instead
of discarding them.

**Portability.** Tested on Neovim 0.10.4, 0.11.2 and 0.12.4 on every change;
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
it — rebind it, e.g. `mappings.panel.steer = "<M-CR>"`, if `<C-CR>` never
steers for you.

Yana ships no completion provider of its own, so `mappings.panel.completion_menu`
(default `<C-Space>`) only shows Yana-scoped slash-command/@mention
completions when your own blink.cmp config special-cases
`vim.b.yana_prompt`, which `:checkhealth yana` also reports as INFO.

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

</details>

## Licence

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for provenance.
