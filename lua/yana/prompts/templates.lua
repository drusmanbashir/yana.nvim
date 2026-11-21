-- Every text Yana sends to the agent, by name. Edit wording here only.
-- `{name}` is filled by `require("yana.prompts").render(key, vars)`.
-- Mode instructions have no secondary file or fallback prompt.

return {
  ---------------------------------------------------------------- mode sentences
  -- Sent on a mini-conversation's first request and whenever the mode changes.
  mode_ask = "Yana ask mode: answer without changing any files.",
  mode_ask_mcp = "Yana ask mode: answer without changing any files. {read_tools} are available. Use them for all reads.",
  mode_inline = "Yana inline mode: you are an inline editor I'm using inside Neovim. Make the requested changes, in every file they need, by writing the files directly with your normal tools; you can read any file. Don't run tests. I may keep editing while you work. Yana reviews at most {max_files} files per turn, and a moved file counts twice.",
  -- Replaces mode_inline when the backend runs the inline Turn through Yana MCP.
  mode_inline_mcp = "Yana inline mode: you are an inline editor I'm using inside Neovim. {read_tools} are available. Use them for all reads. Prefer Yana's replace_text with exact old and new text for changes to existing text. For new files and whole rewrites, use open_buffer followed by edit_buffer with the complete after_text. Use delete_file for file deletion. Use rename_file to rename or move a file; edit its returned buffer_ref for any accompanying text changes. All proposals wait for review. Do not write or save files through other tools. Don't run tests. I may keep editing while you work. Yana reviews at most {max_files} files per turn.",
  mode_agentic = "Yana agentic mode: make the requested changes directly and test them as needed.",

  ---------------------------------------------------------------- the request
  selected_code_header = "Selected lines of `{file}` (line numbers are absolute file lines):",
  selection_not_a_limit = "The selection shows where I'm pointing, not a limit: make any other changes the request needs, in this file or others.",
  selection_truncated = "(selection truncated)",
  editing_file_hint = "The user is editing `{file}` (filetype: {filetype}, cursor on line {line}). Open it if you need its contents.",
  diagnostics_header = "Diagnostics in `{file}`:",
  diagnostics_line = "- L{line}: [{severity}] {message}",
  attached_image = "{token} (attached image: {path})",

  ---------------------------------------------------------------- prefixes added at submit
  -- Default for setup `redirect.marker`.
  redirect_marker = "[redirect — previous turn interrupted]",
  carried_context_header = "[Context carried from the earlier part of this conversation, which ran in a different mode]",
  followup_open_review = "[Yana] This prompt continues the open review of your previous changes in this conversation; the operator rejected hunks in: {files}. The user may keep editing while you work.",
  followup_no_files = "none",
  followup_more_files = " and {count} more",

  ---------------------------------------------------------------- mode switch: ask answer, other seat
  apply_ask_answer = "Apply exactly what we agreed in the previous ask answer.\nTreat this artifact as the source of truth for the edits.\n\n{artifact}",
  other_seat_header = "[Context from the other seat on this panel]",
  other_seat_request = "Previous request:",
  other_seat_answer = "Previous answer:",

  ---------------------------------------------------------------- renewal brief (mode switch carry)
  brief_opening = "Continuing an existing conversation in a new mode.",
  brief_workspace = "Workspace: {path}",
  brief_mode = "Mode: {to} (was {from})",
  brief_previous_instruction = "Previous instruction: {text}",
  brief_previous_outcome = "Previous outcome: {outcome}",
  brief_accepted_last_turn = "Accepted last turn: {files}",
  brief_rejected_last_turn = "Rejected last turn: {files}",
  brief_artifact_code_blocks = "Artifact from the previous answer (its code blocks, verbatim):",
  brief_artifact_full_answer = "The previous answer, carried in full:",
  brief_more_files = "… and {count} more",
  brief_unsaved_accepted = "{file} (accepted, unsaved — not yet on disk)",
  outcome_cancelled = "cancelled",
  outcome_error = "ended with an error (exit {code})",
  outcome_completed = "completed",
  outcome_no_result = "ended without a result",

  ---------------------------------------------------------------- decision note (same-mode next turn)
  decision_note_header = "Yana record from the previous turn; operator decisions are authoritative, not agent claims:",
  decision_accepted = "Accepted: {files}",
  decision_rejected = "Rejected: {files}",
  -- Also the brief's refusal line.
  refused_files = "Refused: {files}",
}
