<p align="center"><img src="assets/yana-logo-wide.svg" alt="YANA" width="480"></p>

# Yana

Yana is a Neovim plugin for using Cursor, Claude Code or Codex in your
project. In `inline` mode, the agent's edits appear as hunks in your buffers;
you review and accept them before they reach disk.

[![Yana reviewing agent edits inline](assets/yana-demo.gif)](assets/yana-demo.mp4)

## Features

- `ask` answers questions without writing files.
- `inline` proposes edits for review, with accept, reject, undo and redo.
- `agentic` writes files directly, without hunk review.
- Switch agent and model, queue prompts, stop a turn, paste images, and resume
  sessions across tabs.

[Feature details](docs/how-it-works.md)

## Install

### Prerequisites

Install `git` for lazy.nvim to clone plugins and `curl` to download installers.
Yana needs Neovim 0.11.2+, an agent CLI and, on Linux, Bubblewrap. Follow
steps 1–3 below, or run the [script](scripts/install-deps.sh) that checks these
and installs what is missing. Read it first if you like; it asks before every
`sudo` command.

```sh
curl -fsSLO https://raw.githubusercontent.com/drusmanbashir/yana.nvim/main/scripts/install-deps.sh
bash install-deps.sh
```

If not using the installer, you can follow steps below for the prerequisites:

#### 1. Install an agent

Choose an installed agent CLI: Claude Code (`claude`), Codex
(`codex`) or Cursor (`cursor-agent`). Use the matching `backend` value
`"claude"`, `"codex"` or `"cursor"` in the Neovim setup below.
After setup, run `:YanaLogin` to sign in through that agent's official login
in a Neovim terminal. Existing API-key authentication keeps working.

<a id="bubblewrap"></a>

#### 2. Install Bubblewrap

In Linux `ask` and `inline` modes, Bubblewrap, also used by
[Flatpak](https://github.com/containers/bubblewrap), keeps the agent's file writes in
a private workspace until you accept them. Install it and its capability tool:

```sh
sudo apt-get install git curl bubblewrap libcap2-bin
```

#### 3. Allow Bubblewrap on Ubuntu 24.04+

AppArmor is [Ubuntu's application security system](https://documentation.ubuntu.com/security/security-features/privilege-restriction/apparmor/).

Bubblewrap builds the sandbox from a Linux user namespace, and Ubuntu 24.04 and
newer block those by default through AppArmor. This one-time step lets
`/usr/bin/bwrap`, and only it, create one; AppArmor stays on and the rule still
applies to every other program. Other distributions can skip it.

First check for an existing profile:

```sh
grep -rl /usr/bin/bwrap /etc/apparmor.d/
```

If a file is printed, ask your administrator to add `userns,` to that profile
and reload it with `sudo apparmor_parser -r FILE`. Otherwise, create it below.
Do not add a second profile for the same executable.

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

To undo it, run
`sudo apparmor_parser -R /etc/apparmor.d/yana-bwrap`, then delete that file.
macOS supports `agentic` mode only. See the
[full requirements and troubleshooting guide](docs/installation.md).

### Neovim setup

Add this plugin declaration to your lazy.nvim configuration. The example
starts with Claude; change `backend` to `"codex"` or `"cursor"` for another CLI.
The table shows the public plugin's configurable mapping defaults. Change
their values during setup; omitted entries keep their defaults.

```lua
{
  "drusmanbashir/yana.nvim",
  dependencies = { "drusmanbashir/yana-ui.nvim" },
  event = "VeryLazy",
  opts = {
    backend = "claude",
    mappings = {
      -- Global: available from any buffer
      toggle = "<C-a>", -- open or close the panel
      ask = false, -- optional shortcut for asking about code
      inline_edit = false, -- optional visual shortcut for the instruction float

      -- Reviewed buffers: normal and visual modes
      accept_hunk = "ca", -- accept the change under the cursor
      reject_hunk = "cr", -- reject the change under the cursor
      accept_file = "cf", -- accept all changes in the current file
      reject_file = "cx", -- reject all changes in the current file
      accept_all = "cA", -- accept all changes in the turn
      next_hunk = "]x", -- next change
      prev_hunk = "[x", -- previous change

      -- Panel prompt and inline-edit float: normal and insert modes
      submit = "<C-s>", -- send the prompt
      stop = "<C-c>", -- stop the response; close the float in insert mode

      -- Panel
      model = "<C-g>", -- choose an agent and model
      new_chat = "<C-n>", -- start a new chat
      resend = "<M-r>", -- then r: here, n: new chat, a: new agent chat
      review = "<C-y>", -- review pending changes
      reject = "<C-x>", -- reject pending changes
      focus_prompt = "i", -- focus the prompt from the conversation
      close = "q", -- close the panel or float (normal mode)
      next_panel = "<M-.>", -- next panel, from the prompt
      prev_panel = "<M-,>", -- previous panel, from the prompt
      completion_menu = "<C-Space>", -- prompt completion (insert mode)
      new_panel = "<M-n>", -- open another panel
      queue = "<M-q>", -- open the prompt queue
      steer = "<C-CR>", -- send instructions to the running agent

      -- Inline-edit float: normal and insert modes
      history_prev = "<C-p>", -- previous instruction
      history_next = "<C-n>", -- next instruction
    },
  },
}
```

Set an optional mapping to `false` to disable it. The seven review mappings
cannot be disabled: `false` or `""` restores their defaults. Review keys `cR`,
`cU`, `u`, `U` and `<C-r>` are fixed. If your terminal treats `<C-CR>` as Enter,
change `steer` to another key, such as `"<M-CR>"`.

lazy.nvim installs the required `yana-ui.nvim` dependency. If you omit
`backend`, Yana starts with Cursor; it does not guess from installed CLIs.

Restart Neovim in your project, run `:checkhealth yana`, then press
`<C-a>`. The opened project is included automatically. Use `:YanaRoots`
only to add other folders; no model or project-path setting is needed for
normal use.

## Use

Press `<C-a>`, enter a prompt and press `<C-s>`. Or select lines and run
`:YanaEdit` to open the instruction float. Review hunks with `ca` / `cr`, accept the
whole turn with `cA`, and undo or redo a decision with `u` / `<C-r>`.

See [all commands and keys](docs/usage.md),
[configuration and optional overrides](docs/configuration.md),
[known issues](docs/known-issues.md), [alternatives](docs/alternatives.md),
and the [roadmap](docs/roadmap.md). The full reference is `:help yana`.

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
