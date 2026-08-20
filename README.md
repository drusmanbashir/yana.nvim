# Yana

Yana is a Linux-only Neovim agent that runs `cursor-agent` inside a private
workspace layer, then presents its proposed edits as inline hunks. Real project
files remain unchanged until you accept a hunk, file, or turn.

The normal workflow is:

1. Ask from the panel or select lines and open an inline edit.
2. Yana runs the agent in a confined overlay.
3. Proposed changes appear in the real source buffers.
4. You accept or reject them without giving the agent direct write access.

## Requirements

- Linux with user namespaces, overlayfs, `/proc`, and Bubblewrap (`bwrap`).
- Neovim 0.10.4 or newer.
- `cursor-agent`, installed and signed in.
- Bash, Python 3, Bubblewrap, `capsh` (from `libcap2-bin`/`libcap-utils`, used
  to drop capabilities before the confined agent starts), GNU
  coreutils/findutils, util-linux mount tools, `awk`, `sed`, `grep`, and the
  standard account/network lookup tools `hostname`, `getent`, and `id`.

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

## Install

With lazy.nvim:

```lua
{
  "drusmanbashir/yana.nvim",
  cmd = { "Yana", "YanaAsk", "YanaEdit", "YanaOpen" },
  opts = {
    global_keymaps = {
      toggle = "<leader>cc",
      ask = "<leader>ca", -- normal mode opens the panel; visual mode asks about the selection
      inline_edit = "<C-k>", -- visual mode
    },
  },
}
```

For a local checkout:

```lua
vim.opt.runtimepath:prepend("/path/to/yana.nvim")
require("yana").setup({})
```

`setup()` is optional when the defaults are sufficient.

## Usage

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

## Configuration

```lua
require("yana").setup({
  -- cmd/cmd_env: see "Machine-specific configuration" below.
  model = nil,
  mode = "inline", -- "ask" or "inline"
  approve_mcps = false,
  -- Extra directory component names/globs for artifact grouping only. This can
  -- change binary recovery from durable to momentary; it never grants safety.
  artifact_dir_prefixes = {},

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

See `:help yana-configuration` for the complete option reference.

## Machine-specific configuration

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

## Security

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

## Data

Session metadata and transcripts use `stdpath("data") .. "/yana"`. Durable
diagnostics use Neovim's state/log directories. Workspace-local review history
uses `.yana/`. Cursor credentials remain owned by `cursor-agent` under
`~/.cursor`.

## Release Policy

Yana follows Semantic Versioning. Before `1.0.0`, incompatible public changes
increment the minor version and compatible fixes increment the patch version.
Prereleases use tags such as `v0.1.0-alpha.1`, `v0.1.0-beta.1`, or
`v0.1.0-rc.1`; stable releases use `v0.1.0`.

## Licence

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for provenance.
