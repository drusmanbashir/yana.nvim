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
[Instruction float](#inline-edit) · [Review size](#review-size) · [Logging](#logging)

## Agent and backend

Yana offers only the agents you list in `backends`, plus the one
`backends.default` names. It ships tested presets for `cursor`, `claude`,
`codex` and `grok`; listing one switches it on (`grok = {}`). `backends.default`
defaults to `"claude"`. Claude, Codex and Grok support every mode. Cursor can run in `agentic` mode.

```lua
backends = {
  default = "codex",
  codex = {
    cmd = "/custom/path/codex",
    model = "your-model-id",
  },
  grok = { env = { GROK_CLAUDE_HOOKS_ENABLED = "0" } },
},
```

Yana normally finds the CLI through Neovim's `PATH`. `cmd` can be a command name
or a path. An omitted `model` lets the agent choose. `env` adds environment
variables to every process Yana starts for that agent.

An entry may also set any other preset setting; each one replaces the preset's
value whole. The presets in `lua/yana/configuration/config_defaults_backends.lua`
show every setting. A name without a preset adds an agent: its entry declares
the command, its flags and which stream protocol Yana reads (`cursor`, `claude`
or `codex`):

```lua
backends = {
  mycli = {
    cmd = "mycli",
    noninteractive_flag = false,
    prompt_flag = "--single",
    stream_protocol = "claude",
    stream_json_args = { "--output-format", "stream-json" },
    mode_switch = "per_turn",
    sandbox_args = { full = {}, workspace = {}, ["read-only"] = {}, ["vendor-default"] = {} },
    allow_edits_args = {},
  },
},
```

Settings are plain data. A function, an unknown setting or an invalid value
stops setup with a message naming the field.

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
| `agentic` | The agent writes directly, without hunk review. |

See [How it works](how-it-works.md) for the write boundary and
[Usage](usage.md) for review keys.

## Inline edit

Select lines and run `:YanaEdit` to enter an instruction in a small float. The
selection and instruction then use the ordinary panel submission path. The
selection shows the agent where to look; it may change other lines and files
when the request needs it.

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

## Review size

`review.max_files` (default 30) is the most files one review can hold; a moved
file counts twice. The agent is told the limit, but Yana enforces it: a bigger
change is refused when the agent stops, nothing is applied, and the panel names a
recovery folder.

```lua
review = { max_files = 60 },
```

The editor waits while a review opens: about 1 second at 30 files and 3.5 seconds at 60.

## Logging

The release has one logging setting:

```lua
log_level = "warn",
```

`log_level` defaults to `"info"`; accepted levels are `"error"`, `"warn"`,
`"info"` and `"debug"`. Only records at or above the selected level are written.

## Reference

These are the documented public inputs. Agent flag settings are listed in the
presets file.

| Option path | Default |
|---|---|
| `backends` | `{ default = "claude" }` |
| `backends.default` | `"claude"` |
| `backends.<name>` | Enables a preset (`cursor`, `claude`, `codex`, `grok`) or adds an agent |
| `backends.<name>.cmd` | Preset CLI command |
| `backends.<name>.model` | Agent default |
| `backends.<name>.env` | `{}`; extra environment for that agent's processes |
| `modes` | `{ "inline", "agentic", "ask" }` |
| `review` | `{ max_files = 30 }` |
| `review.max_files` | `30` |
| `inline_edit` | Defaults listed above |
| `log_level` | `"info"` |

Inside Neovim, run `:help yana-configuration`.
