# Roadmap

Nothing here ships until it has tests.

- Review polish: a few known non-blocking rough edges left over from the last
  review rebuild are still being cleaned up.
- Prompt history: `<Up>`/`<Down>` in the prompt pane recall earlier prompts,
  newest first, like an agent CLI.
- File-keyed resume: opening a file offers the LIVE (daemon-owned) sessions
  that touched it; there is no disk-only history yet.
- Chat picker: see and switch between ongoing chats from the keyboard.
- Install automation: `:YanaInstallDeps` fetches user-space dependencies.
- Agent profile file (Lua): a declarative alternative to configuring
  backends only in Lua.
- ACP driver (Agent Client Protocol): one JSON-RPC dialect for every agent
  instead of a per-vendor flag table. Turn, resume, mode and edit permission
  become `session/prompt`, `session/load`, `session/set_mode` and
  `session/request_permission`; the three stream parsers become one. Per
  vendor only the launch command and its capability gaps remain. Trigger: two
  vendors shipping `session/load`. Known limit: `cursor-agent` over ACP cannot
  say "edit yes, shell no" at session create.
- macOS confined (`ask`/`inline`) support: still unsupported (see [Known issues](known-issues.md)). Agentic on macOS is documented. Closing the overlay hole means a
  Darwin confinement backend that still satisfies the real-path + separable-
  writes rules — not a brew package list.
- Windows support: unsupported. Same audit as the macOS overlay hole, plus
  process spawn and crash/restart paths.
- Per-decision time travel: `:earlier`/`:later`/`g-`/`g+` stepping Yana's
  accept/reject decisions back and forth one at a time, in lockstep with
  Neovim's own undo history. Not planned. Accepting or rejecting a hunk in an
  open buffer changes no text, and Neovim's undo tree only records text
  changes, so four accepts share one undo sequence and there is no state for
  `:earlier` to step through per decision; building it means manufacturing a
  synthetic undo boundary for every decision, which puts Yana's bookkeeping
  inside Neovim's undo tree. What IS built instead is the whole-review
  rewind: crossing the proposal insertion backward withdraws the whole review
  and every decision in it together, and crossing it forward restores the
  exact proposal and reopens the same review with all hunks pending.
- Undocked panel: run the Yana panel in its own kitty window (or cockpit pane)
  instead of a split, so the editor keeps the full width. Neovim's UI protocol
  draws one screen per instance, so this is a second Neovim talking to the
  editing one over its RPC socket, not a detached window. Window placement and
  socket discovery reuse the pattern the REPL integration already uses for
  kitty; the transport is Neovim RPC rather than `kitty @ send-text`, because
  the panel must paint hunks back into the editing instance, not only push text
  out. Measured locally: 0.016 ms per synchronous round trip, 0.21 ms to place
  100 extmarks batched in one `nvim_exec_lua` (1.66 ms unbatched), so repaint
  cost is transport-free — provided pushes batch and use `rpcnotify`.
