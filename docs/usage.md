# Usage

## Interface

Yana uses ordinary Neovim windows, winbars, highlights, and text decorations.
It adds no UI framework. The conversation header leads with `YANA · Inline`
and the confirmed backend/model; the input header says `Send follow-up…`.

The interface uses short result-focused labels. Configuration names remain
stable: `ask` appears as **Ask**, `inline` as **Inline**, and `agentic` as
**Agent**. Tool progress uses **Thinking**, **Explored**, **Edited**, and
**Ran**. Pending edits say **Review changes** and file-buffer decisions say
**Accept** or **Reject**.

## Key Bindings

### Review — in the file buffer, while hunks are open

| Key | Action |
|---|---|
| `ca` | Accept the current hunk |
| `cr` | Reject the current hunk |
| `cf` | Accept all remaining hunks in the file |
| `cx` | Reject the entire file |
| `cA` | Accept every pending change in the turn |
| `cR` | Abort the whole review after confirmation |
| `]x` / `[x` | Next / previous hunk |
| `u` | Undo on the turn-global register (`u` / `<C-r>` are the only walk keys); when the register is empty, the End-turn dialog asks whether to end |
| `U` | Undo the whole turn — every file, back to where you started |
| `<C-r>` | Redo on the same turn-global register (reverse of the `u` walk); after End-turn, plain Neovim redo |

### Panel — the chat pane

| Key | Action |
|---|---|
| `<C-s>` | Submit the prompt (normal and insert mode) |
| `<C-n>` | Start a new chat |
| `<M-t>` | Cycle through `modes`, in list order |
| `<M-r>` | Resend the last prompt |
| `<C-g>` | Pick the agent CLI, then its model |
| `<C-y>` | Open review for a pending change |
| `<C-x>` | Reject a pending change |
| `<C-c>` | Stop the in-flight response (prompt and conversation window) |
| `<M-s>` | Pick a session |
| `<M-n>` | Open an additional panel |
| `<M-q>` | View/edit the queue |
| `<C-CR>` | Steer: interrupt and resend the prompt as a new turn |
| `<C-Space>` | Open the completion menu |
| `i` | Focus the prompt |
| `q` | Close the panel |

### Global — `<C-a>` toggles the sidebar by default

| Setting (`mappings`) | Example | Action |
|---|---|---|
| `toggle` | `<C-a>` | Open/close the panel from any normal-mode buffer, including the panel |
| `ask` | `<leader>ca` | Ask about the current line/selection (normal + visual; unset by default) |
| `inline_edit` | `<C-k>` | Inline edit the visual selection (unset by default) |

## Commands

| Command | Action |
|---|---|
| `:Yana` / `:YanaToggle` | Toggle the panel |
| `:YanaOpen` / `:YanaClose` | Open or close the panel |
| `:YanaAsk [question]` | Ask about the current line or visual selection |
| `:YanaEdit [instruction]` | Edit the current line or visual selection through inline review |
| `:YanaNew` | Start a new chat |
| `:YanaNewPanel` | Open an additional panel (parallel session) |
| `:YanaSessions[!]` | Attach a session owned by the live yana daemon; `!` opens it in a new panel |
| `:YanaRecover [id]` | Recover a daemon-kept review after editor death; no id reopens the recovery picker |
| `:YanaMode` | Cycle the agent mode |
| `:YanaModel` | Pick the model (layer 2: within the active backend) |
| `:YanaBackend` | Pick the backend (layer 1: which binary/account/bill) |
| `:YanaDiff` | View agent file changes as a diff (read-only) |
| `:YanaRefusals` | List system-refused operations and recovery paths |
| `:YanaIgnore` | List the review ignore list; `:YanaIgnore <pattern>` adds one (gitignore syntax, effective immediately) |
| `:YanaReview` | Open a pending inline review |
| `:YanaAccept` / `:YanaReject` | Accept or reject the pending file change |
| `:YanaAbortReview` | Abort the open review: put the file back as it was before the hunks appeared |
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
