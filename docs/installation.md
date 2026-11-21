# Installation

## Choose your backend

If Neovim and your agent CLI already work, configure Yana to use that agent:

| Agent | Command | Modes |
|---|---|---|
| Claude Code | `claude` | All |
| Codex | `codex` | All |
| Cursor | `cursor-agent` | `agentic` |
| Grok | `grok` | All |

With lazy.nvim:

```lua
{
  "drusmanbashir/yana.nvim",
  dependencies = { "drusmanbashir/yana-ui.nvim" },
  event = "VeryLazy",
  opts = { backends = { default = "claude" } }, -- or "codex"
}
```

The dependency entry installs `yana-ui.nvim` automatically. With `opts = {}`,
Yana starts with Claude. Your existing agent login is used; no separate Yana account or API
key is required.

If your agent is installed but not signed in, run `:YanaLogin` after configuring
Yana. It opens the selected agent's official interactive login in a Neovim
terminal. Follow its browser or terminal instructions, then submit your prompt
again. Returning to the login window restores terminal input mode. In normal
mode (for example after a click), paste and Enter still reach the login
process, `p`/`P` paste the selected register, and `q` closes the window. The window shows
an input hint. If login exits unsuccessfully, its output stays visible and the
notice names the exit status. Yana does not store login tokens, log this
terminal or replay a turn. The agent owns its credentials; existing API-key
authentication is preserved.

## Ubuntu extras and first use

```sh
sudo apt-get install git curl python3 ripgrep
```

Restart Neovim in your project directory, run `:checkhealth yana`, then open
`:Yana`. For an agent or system requirement reported by health, see
[troubleshooting](#troubleshooting).

The opened project is already included. The chosen agent supplies its default
model unless you set one in its `backends` entry.

## System requirements

Use the commands below to install missing prerequisites. On Linux, `ask` and
`inline` use the launcher and MCP tools listed here.

**Get Neovim 0.11.2+ first.** `apt` on Ubuntu 24.04 and older installs an
older Neovim (0.9.5 on a stock Ubuntu 24.04 image, verified) with no warning
that it is below Yana's floor — `:checkhealth yana` catches it, but only
after you have already tried to run Yana.

**AppImage** (no install, no root):
```sh
curl -LO https://github.com/neovim/neovim/releases/latest/download/nvim-linux-x86_64.appimage
chmod u+x nvim-linux-x86_64.appimage
./nvim-linux-x86_64.appimage
```

Other ways to get 0.11.2+ (PPA, package managers, Windows, macOS): see
Neovim's own install docs at [neovim.io/doc/install](https://neovim.io/doc/install/).

The launcher uses Bash 4.4+, coreutils, sed and awk. A standard Linux installation
already provides these. The commands below include them for minimal installations.
If Yana must enter a systemd user scope, it also needs `systemd-run` from systemd.

**Debian / Ubuntu**
```sh
sudo apt-get install -y git curl python3 ripgrep bash coreutils sed mawk
```

**Fedora / RHEL**
```sh
sudo dnf install -y git curl python3 ripgrep bash coreutils sed gawk
```

**Arch**
```sh
sudo pacman -S --needed git curl python ripgrep bash coreutils sed gawk
```

**macOS**

Only **agentic** mode works on macOS: the agent writes your real files
directly. Confined `ask` and `inline` require Linux, `/proc`, and cgroup v2 delegation.
On macOS, add this field to the `opts` table above:

```lua
modes = { "agentic" },
```

For hunk review, run Yana on Linux.

If you still need an agent CLI, install one or more below. Select it with
`backends.default`.

- **`cursor-agent`** — install line from Cursor's own docs
  ([cursor.com/docs/cli/installation](https://cursor.com/docs/cli/installation)):
  ```sh
  curl https://cursor.com/install -fsS | bash
  ```
  What you need: a Cursor account. Sign in with `cursor-agent login`, or set
  `CURSOR_API_KEY`.

- **`claude`** (Claude Code CLI) — **experimental**. Install line from
  Anthropic's own docs
  ([code.claude.com/docs/en/setup](https://code.claude.com/docs/en/setup)):
  ```sh
  curl -fsSL https://claude.ai/install.sh | bash
  ```
  What you need: an Anthropic Pro/Max/Team/Enterprise/Console account. Sign
  in by running `claude` and following the browser prompt, or set
  `ANTHROPIC_API_KEY`.

- **`codex`** (OpenAI Codex CLI) — **experimental**. Install line from
  OpenAI's own package
  ([npmjs.com/package/@openai/codex](https://www.npmjs.com/package/@openai/codex)):
  install Node.js and npm first if they are not already available.
  ```sh
  npm install -g @openai/codex
  ```
  What you need: an OpenAI account (ChatGPT Plus/Pro/Business/Edu/Enterprise).
  Sign in with `codex login`, or set `OPENAI_API_KEY`.

- **`grok`** (xAI Grok CLI) — **experimental**.
  ```sh
  curl -fsSL https://x.ai/cli/install.sh | bash
  ```
  What you need: a grok.com or xAI account. Sign in with `grok login`, or set
  `XAI_API_KEY`. The installer puts `grok` in `~/.grok/bin`; if that is not on
  Neovim's `PATH`, set `backends = { grok = { cmd = "~/.grok/bin/grok" } }`.

Then run `:checkhealth yana` — it names any missing package, the agent
binary it tried, and the fix.

## Custom CLI location

If Neovim cannot find an installed CLI on its `$PATH`, set its command in the
matching backend entry:

```lua
backends = {
  default = "claude",
  claude = { cmd = "/custom/path/claude" },
},
```

The named entries also accept an optional `model`. See
[configuration](configuration.md#agent-and-backend) for the full setup sample.

## Manual installation

Install both plugin repositories as Neovim start packages. The directory is
derived from your Neovim data path, so XDG settings and `NVIM_APPNAME` are
respected:

```sh
data=$(nvim --headless -i NONE -u NONE -c 'lua io.write(vim.fn.stdpath("data"))' -c qa)
test -n "$data" || { echo "Neovim did not report its data directory" >&2; exit 1; }
start="$data/site/pack/yana/start"
mkdir -p "$start"
git clone https://github.com/drusmanbashir/yana.nvim "$start/yana.nvim"
git clone https://github.com/drusmanbashir/yana-ui.nvim "$start/yana-ui.nvim"
```

Then add this to your Neovim configuration, choosing the backend from the table
above:

```lua
require("yana").setup({ backends = { default = "claude" } }) -- or "codex"
```

## Verify installation

Run `:Yana` to open the panel; if it fails, `:checkhealth yana` names the missing package, the agent binary it tried, and the fix.

## Troubleshooting

**Agent CLI not found.** Neovim's `$PATH` can differ from your shell's —
GUI Neovim, a Flatpak or Snap build, Nix, an `asdf`/`mise` shim, or an npm
global prefix your shell profile adds but Neovim never sources. Set
`backends.<name>.cmd` to an absolute path so Yana doesn't need to find the
binary on `$PATH` at all. `:checkhealth yana` shows exactly what it tried
and in what order.

**No delegated user cgroup.** A cgroup is the Linux process group used to stop
and reclaim a confined turn. Yana automatically enters a systemd user scope
when launched from SSH, tty or a system service. If `cgroup:delegation` fails,
ensure the login has a running systemd user manager and its owned runtime
directory (`/run/user/UID`) with `systemd/private` or `bus`; Yana refuses if
that manager is unavailable. Containers
need a writable delegated cgroup v2 hierarchy.

**The model list times out.** The agent CLI itself may be waiting for you
to log in before it can list models. Run it once directly in a terminal
(e.g. `cursor-agent`, `claude`, or `codex`) and sign in there, then retry
the picker in Yana.

## Release Policy

Yana follows Semantic Versioning. Before `1.0.0`, incompatible public changes
increment the minor version and compatible fixes increment the patch version.
Prereleases use tags such as `v0.1.0-alpha.1`, `v0.1.0-beta.1`, or
`v0.1.0-rc.1`; stable releases use `v0.1.0`.
