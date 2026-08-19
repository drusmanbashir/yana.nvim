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
- Bash, Python 3, Bubblewrap, GNU coreutils/findutils, util-linux mount tools,
  `awk`, `sed`, `grep`, and the standard account/network lookup tools
  `hostname`, `getent`, and `id`.

Run `:checkhealth yana` after installation. It distinguishes required tools
from optional session-discovery helpers and names the action that clears each
failure.

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
  cmd = "cursor-agent",
  model = nil,
  mode = "inline", -- "ask" or "inline"
  approve_mcps = false,

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

## Security

`inline` and `ask` run in the host-enforced overlay. Yana treats prompts,
vendor permission modes, and agent self-reports as guidance, not containment.
In `inline` mode the agent receives the vendor permission-bypass flag so a
non-interactive turn can use tools; the overlay remains the enforcement
boundary, and the inline review gate decides what reaches your files. `ask`
mode never receives the bypass flag and has no review gate: it is
overlay-confined and its turns change nothing.

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
Release candidates use tags such as `v0.1.0-rc.1`; stable releases use
`v0.1.0`.

## Licence

MIT. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for provenance.
