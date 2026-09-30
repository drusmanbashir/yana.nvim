# Installation

## Choose your backend

If Neovim and your agent CLI already work, configure Yana to use that agent:

| Installed agent | Command | Setup option |
|---|---|---|
| Claude Code | `claude` | `backend = "claude"` |
| Codex | `codex` | `backend = "codex"` |
| Cursor | `cursor-agent` | `backend = "cursor"` |

With lazy.nvim:

```lua
{
  "drusmanbashir/yana.nvim",
  dependencies = { "drusmanbashir/yana-ui.nvim" },
  event = "VeryLazy",
  opts = { backend = "claude" }, -- choose "claude", "codex" or "cursor"
}
```

The dependency entry installs `yana-ui.nvim` automatically. With `opts = {}`,
Yana starts with Cursor; it does not select whichever CLI happens to be
installed. Your existing agent login is used; no separate Yana account or API
key is required.

## Ubuntu extras and first use

For a normal Ubuntu installation, add the tools used by Yana's sandbox:

```sh
sudo apt-get install bubblewrap libcap2-bin
```

These provide `bwrap` and `capsh`. The full system-tool list below covers minimal
images too; Neovim and agent installation instructions can be skipped when those
already work.

Restart Neovim in your project directory, run `:checkhealth yana`, then open
`:Yana`. If health reports `bwrap:userns`, the host is preventing the sandbox
from starting; installing the packages alone does not clear that restriction.
Read the reported platform-specific diagnostic. If health cannot find the
selected agent, see [troubleshooting](#troubleshooting).

The opened project is already included. `:YanaRoots` adds extra folders;
the startup notice that the extra capture set is empty does not mean your
project is excluded. No `write_roots` or model setting is needed for normal
first use; the chosen backend supplies its default model.

## System requirements

For a new setup, install the pieces you do not already have with the commands
below; there is no Yana installer. If Neovim and your agent CLI already work,
skip their installation sections. Confined `ask` and `inline` still need the
Linux sandbox tools listed here.

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

Then install the system packages:

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

`overlayfs-fast` does not require FUSE. For `fuse-compat`, also install
`fuse-overlayfs` and the uid/gid mapping tools:

```sh
# Debian / Ubuntu
sudo apt-get install -y fuse-overlayfs uidmap

# Fedora / RHEL
sudo dnf install -y fuse-overlayfs shadow-utils

# Arch
sudo pacman -S --needed fuse-overlayfs shadow
```

**macOS**

Only **agentic** mode works on macOS: the agent writes your real files
directly, with no overlay and no hunk review. Confined `ask` / `inline` need
Linux kernel facilities (bubblewrap, overlayfs, `/proc`) that Homebrew cannot
provide, so Yana refuses those modes on Darwin instead of silently falling
back.

```lua
opts = {
  modes = { "agentic" },
}
```

For hunk review, run Yana on Linux.

If you still need an agent CLI, install one or more below. Each installed CLI
is selectable with `backend = "cursor" | "claude" | "codex"`.

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
  ```sh
  npm install -g @openai/codex
  ```
  What you need: an OpenAI account (ChatGPT Plus/Pro/Business/Edu/Enterprise).
  Sign in with `codex login`, or set `OPENAI_API_KEY`.

Then run `:checkhealth yana` — it names any missing package, the agent
binary it tried, and the fix.

## Environment variables

All optional. Yana reads these directly:

```sh
# Only needed when a CLI is not already on Neovim's PATH:
export YANA_CURSOR_BIN=/custom/path/cursor-agent
export YANA_CLAUDE_BIN=/custom/path/claude
export YANA_CODEX_BIN=/custom/path/codex

# Legacy Cursor-only override:
export YANA_AGENT_BIN=~/.local/bin/cursor-agent

# Opt-in diagnostics, both off by default:
export YANA_DEBUG_EVENTS=1     # record every turn's raw agent stream
export YANA_LIFECYCLE_LOG=1    # record what each turn did, event by event
```

`YANA_DEBUG_EVENTS` writes the raw stream and decoded `events.jsonl` into that
turn's private state directory. `YANA_LIFECYCLE_LOG` adds structured turn,
claim, and review rows to Yana's durable log. They exist for diagnosis and add
extra writes, so leave them unset for normal use.

The vendor-specific variables need no Lua configuration. `YANA_AGENT_BIN`
remains supported for Cursor; point the top-level `cmd_env` at any existing
variable if you use another legacy name:

```lua
opts = { cmd_env = "CURSOR_CLI_BIN" }
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
require("yana").setup({ backend = "claude" }) -- or "codex" / "cursor"
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

**bubblewrap missing, or user namespaces blocked.** Confined modes (`ask`,
`inline`) need unprivileged user namespaces; this shows up as a refusal on
Ubuntu 24.04 with its default AppArmor profile, inside most containers, and
on WSL2. `:checkhealth yana` names which check failed and the fix for your
setup — installing `bubblewrap`, or the AppArmor/sysctl change needed to
allow user namespaces again.

On Ubuntu 24.04, `bwrap:userns` reporting `setting up uid map: Permission
denied` can mean Bubblewrap lacks an AppArmor exception. AppArmor is Ubuntu's
program permission policy; a user namespace lets Bubblewrap build the private
environment for a confined turn. If no existing Bubblewrap profile grants this
permission, an administrator can add this profile for `/usr/bin/bwrap`:

```sh
sudo apt-get install apparmor
sudo tee /etc/apparmor.d/yana-bwrap <<'EOF'
abi <abi/4.0>,
include <tunables/global>
profile yana-bwrap /usr/bin/bwrap flags=(unconfined) {
  userns,
}
EOF
sudo apparmor_parser -r /etc/apparmor.d/yana-bwrap
```

This permits Bubblewrap to construct its sandbox while retaining Ubuntu's
user-namespace restriction for other programs. It does not disable AppArmor
globally. Follow [Ubuntu's application-profile guidance](https://documentation.ubuntu.com/release-notes/24.04/#unprivileged-user-namespace-restrictions)
if the machine already has a Bubblewrap profile. Restart Neovim and run
`:checkhealth yana` again. To remove this exception, run
`sudo apparmor_parser -R /etc/apparmor.d/yana-bwrap`, then remove that file.
The release CI uses the same exception on its disposable Ubuntu runner.

**The model list times out.** The agent CLI itself may be waiting for you
to log in before it can list models. Run it once directly in a terminal
(e.g. `cursor-agent`, `claude`, or `codex`) and sign in there, then retry
the picker in Yana.

## Release Policy

Yana follows Semantic Versioning. Before `1.0.0`, incompatible public changes
increment the minor version and compatible fixes increment the patch version.
Prereleases use tags such as `v0.1.0-alpha.1`, `v0.1.0-beta.1`, or
`v0.1.0-rc.1`; stable releases use `v0.1.0`.
