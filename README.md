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

You need Neovim 0.11.2+ and an installed, signed-in agent CLI. Choose the
matching `backend` value below. The example starts with Claude; change it to
`"codex"` or `"cursor"` for another CLI.

```lua
{
  "drusmanbashir/yana.nvim",
  dependencies = { "drusmanbashir/yana-ui.nvim" },
  event = "VeryLazy",
  opts = { backend = "claude" },
}
```

lazy.nvim installs the required `yana-ui.nvim` dependency. If you omit
`backend`, Yana starts with Cursor; it does not guess from installed CLIs.

Confined `ask` and `inline` modes need Linux, Bubblewrap and `capsh`. On
Ubuntu, install the sandbox packages with:

```sh
sudo apt-get install bubblewrap libcap2-bin
```

macOS supports `agentic` mode only. On Ubuntu 24.04, host policy can block
Bubblewrap user namespaces even after installation. See the
[full requirements and troubleshooting guide](docs/installation.md).

Restart Neovim in your project, run `:checkhealth yana`, then `:Yana`. The
opened project is included automatically. Use `:YanaRoots` only to add other
folders; no model or project-path setting is needed for normal use.

## Use

Run `:Yana`, enter a prompt and press `<C-s>`. Or select lines and run
`:YanaEdit`. Review the proposed hunks with `ca` / `cr`, accept the whole turn
with `cA`, and undo or redo a decision with `u` / `<C-r>`.

See [all commands and keys](docs/usage.md),
[configuration and optional overrides](docs/configuration.md),
[known issues](docs/known-issues.md), [alternatives](docs/alternatives.md),
and the [roadmap](docs/roadmap.md). The full reference is `:help yana`.

## License

Apache 2.0. See [LICENSE](LICENSE) and [NOTICE](NOTICE).
