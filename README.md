# Yana

**Cursor-style agent workflow inside Neovim** — chat panel, inline edits on a
selection, backend and model switching. Every proposed change appears as a hunk
in your real buffer first; nothing reaches disk until you accept it. Undo is
normal Neovim (`u`, `U`, `<C-r>`), not a separate command.

## Features

- Modes: `ask` (answers only), `inline` (reviewed edits), `agentic` (direct writes, opt-in)
- Agents: Cursor, Claude, or Codex — switch backend and model mid-chat
- Restrict which programs an inline turn may execute — kernel-enforced allowlist (alpha)

## Setup

1. **Prerequisites** — system packages and agent CLI (Yana does not install these).
2. **Plugin** — lazy.nvim or manual `rtp`.
3. **Configuration** — one `setup()` table; lazy uses `opts`, manual uses `require`.

### 1. Prerequisites

Neovim 0.11.2+. Linux with glibc for hunk review (`ask` / `inline`). macOS:
**agentic** only — no overlay hunk review (`:help yana-known-issues`).

Install one agent CLI and sign in (`cursor-agent`, `claude`, or `codex`).

Linux system packages:

```sh
# Debian / Ubuntu
sudo apt-get install -y bubblewrap libcap2-bin python3 util-linux findutils gawk libc-bin hostname

# Fedora / RHEL
sudo dnf install -y bubblewrap libcap python3 util-linux findutils gawk glibc-common hostname

# Arch
sudo pacman -S --needed bubblewrap libcap python3 util-linux findutils gawk glibc inetutils
```

`bash`, `sed`, `grep`, and coreutils usually ship with the distro.

Agent CLI — `claude` / `codex`: each vendor's installer; `cursor-agent`:

```sh
# Linux
curl https://cursor.com/install -fsS | bash

# macOS
curl https://cursor.com/install -fsS | zsh
xattr -cr ~/.local/share/cursor-agent/
```

### 2. Installation

**lazy.nvim**

```lua
"drusmanbashir/yana.nvim"
```

**Manual**

```sh
git clone https://github.com/drusmanbashir/yana.nvim ~/.local/share/nvim/yana.nvim
```

```lua
vim.opt.runtimepath:prepend("~/.local/share/nvim/yana.nvim")
```

Then, you can confirm installation of deps worked by cd to the plugin directory (lazy: your data path; manual: clone path above):

```sh
./scripts/install-deps.sh
```

### 3. Configuration

```lua
require("yana").setup({
  backend = "cursor",
  global_keymaps = {
    toggle = "<leader>cc",
    ask = "<leader>ca",
    inline_edit = "<C-k>",
  },
})
```

**lazy.nvim** — same keys as `opts` on the spec from step 2. Optional lazy-load:
`cmd = { "Yana", "YanaAsk", "YanaEdit", "YanaOpen" }`.

**Manual** — call `require("yana").setup({ ... })` after `rtp` in step 2.

**macOS** — agentic mode only:

```lua
require("yana").setup({
  enable_agentic = true,
  mode = "agentic",
  global_keymaps = { toggle = "<leader>cc", ask = "<leader>ca", inline_edit = "<C-k>" },
})
```

**Environment variables** (all optional):

```sh
export YANA_AGENT_BIN=~/.local/bin/cursor-agent
export YANA_VENDOR_PROFILE=~/.config/nvim/yana-vendors.lua
export YANA_DEBUG_EVENTS=1
export YANA_LIFECYCLE_LOG=1
```

<details><summary>lazy.nvim: <code>opts</code> from <code>vim.env</code></summary>

```lua
opts = function()
  return {
    backend = vim.env.YANA_BACKEND or "cursor",
    global_keymaps = {
      toggle = "<leader>cc",
      ask = "<leader>ca",
      inline_edit = "<C-k>",
    },
  }
end
```

Yana does not read `YANA_BACKEND` unless you pass it through `setup()`.

</details>

Full options: `:help yana-configuration`. Verify: `:Yana`, then `:checkhealth yana`.

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
| `u` / `U` / `<C-r>` | Undo / reset-turn / redo — wired into the file buffer like normal Neovim undo (not commands, not `setup()` keys) |

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
| `:Yana` | Toggle the panel (`--file`, `--workspace` flags on this turn) |
| `:YanaAsk [question]` | Ask about the current line or visual range |
| `:YanaEdit [instruction]` | Inline edit the current line or visual range |
| `:YanaStop` | Stop the in-flight response |
| `:YanaSessions` / `:YanaResume` | Pick or resume a session (`!` opens in a new panel) |
| `:YanaMode` | Switch `ask` / `inline` / `agentic` |
| `:YanaModel` / `:YanaBackend` | Pick model (layer 2) or backend (layer 1) |

Review undo uses `u`, `U`, and `<C-r>` in the file buffer — same keys as Neovim undo, not `:YanaUndo` / `:YanaRedo`.

Every command: `:help yana-commands`. Everything else: `:help yana`.

## Alternatives

Other Neovim agent plugins and the `cursor-agent` CLI. Rows are the features
that actually differ — not generic editor behaviour. Cells paraphrase each
project's README; "not documented" means they didn't say, not that it is absent.

| | Yana | [avante.nvim](https://github.com/yetone/avante.nvim) | [codecompanion.nvim](https://github.com/olimorris/codecompanion.nvim) | [claude-code.nvim](https://github.com/greggh/claude-code.nvim) | [sidekick.nvim](https://github.com/folke/sidekick.nvim) | [opencode.nvim](https://github.com/NickvanDyke/opencode.nvim) | [cursor-agent CLI](https://cursor.com/docs/cli/overview) |
|---|---|---|---|---|---|---|---|
| Nothing on disk until you approve | Yes — hunks in your buffer; accept per hunk, file, or turn | Yes by default (`auto_apply_diff_after_generation` false) | "approve/reject agent code" | No — CLI writes; plugin reloads changed files | Partial — hunk navigation for CLI agents; NES in-buffer | Yes — `:diffpatch` side-by-side before accept | Interactive review of changes/commands; write timing not documented |
| Sandboxed workspace (default) | Yes — Linux overlay + bubblewrap; outside capture root read-only (`ask`/`inline`) | not documented | not documented | not documented | not documented | not documented | Command sandbox (`--sandbox`); file-write limits not documented |
| Credential paths hidden from agent | Yes — `~/.ssh`, `~/.aws`, etc. | not documented | not documented | not documented | not documented | not documented | `sudo` password only (IPC to `sudo`, not the model) |
| Backends you can switch mid-chat | Cursor, Claude, Codex (your accounts) | Many HTTP providers + ACP agents | Many providers + agent CLIs | Claude Code CLI only | Many agent CLIs | OpenCode server only | n/a (the billed account) |

## Licence

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE) for provenance.
