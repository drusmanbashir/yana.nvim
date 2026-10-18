# Configuration

Choose the agent CLI you already use. Omitted settings keep their defaults.
With lazy.nvim, put these settings in the plugin entry's `opts` table:

```lua
opts = {
  backends = { default = "claude" },
}
```

The examples below show fields to merge into that table. For installation and
custom executable locations, see [Installation](installation.md).

[Agent and model](#agent-and-backend) · [Modes](#modes) ·
[Instruction float](#inline-edit) · [Logging](#logging)

## Agent and backend

`backends.default` selects `"cursor"`, `"claude"` or `"codex"`. It defaults to
`"cursor"`; Yana does not automatically choose another installed CLI.

Each agent entry accepts just `cmd` and `model`. Set either only when you need
to override the executable or the agent's default model:

```lua
backends = {
  default = "codex",
  codex = {
    cmd = "/custom/path/codex",
    model = "your-model-id",
  },
},
```

Yana normally finds the CLI through Neovim's `PATH`. `cmd` can be a command name
or a path. An omitted `model` lets the agent choose. Unknown agents, unknown
entry fields and invalid values stop setup with a message naming the field.

The panel picker (`<C-g>`) selects an agent and then a model. It remembers
choices across restarts; a remembered choice takes precedence over setup.
Changing agents starts with that agent's configured model, or its default.
Use `:YanaLogin` to sign in and `:checkhealth yana` to check the installation.

## Modes

The default order is `{ "inline", "agentic", "ask" }`. The first entry is the
starting mode, and `:YanaMode` cycles through the listed modes. Omit a mode to
make it unavailable:

```lua
modes = { "inline", "ask" },
```

| Mode | What happens |
|---|---|
| `ask` | The agent reads and answers without proposing edits. |
| `inline` | Edits appear as hunks for review before Yana applies them. |
| `agentic` | The agent writes directly, without Yana's overlay or hunk review. |

See [How it works](how-it-works.md) for the write boundary and
[Usage](usage.md) for review keys.

## Inline edit

Select lines and run `:YanaEdit` to enter an instruction in a small float. The
selection and instruction then use the ordinary panel submission path.

```lua
inline_edit = { width = 37, max_height = 4 },
```

| Setting | Default | Effect |
|---|---|---|
| `inline_edit.enable` | `true` | `false` disables the instruction float. |
| `inline_edit.width` | `0.5` | At most `1`: fraction of editor columns; above `1`: column count. Minimum width: 20 columns. |
| `inline_edit.max_height` | `6` | Maximum rows as the instruction grows or wraps. |
| `inline_edit.history` | `20` | Number of instructions retained; `0` disables history navigation. |

`<C-p>` and `<C-n>` recall previous and next instructions. Moving past the
newest restores the draft you were typing. Adjacent repeated instructions
occupy one history entry.

## Logging

The release has one logging setting:

```lua
log_level = "warn",
```

`log_level` defaults to `"info"`; accepted levels are `"error"`, `"warn"`,
`"info"` and `"debug"`. Only records at or above the selected level are written.

## Reference

These are the documented public inputs. Agent command-line flags and transport
settings are internal.

| Option path | Default |
|---|---|
| `backends` | `{ default = "cursor" }` |
| `backends.default` | `"cursor"` |
| `backends.<name>` | Optional settings for `cursor`, `claude` or `codex` |
| `backends.<name>.cmd` | Built-in CLI command |
| `backends.<name>.model` | Agent default |
| `modes` | `{ "inline", "agentic", "ask" }` |
| `inline_edit` | Defaults listed above |
| `log_level` | `"info"` |

Inside Neovim, run `:help yana-configuration`.
