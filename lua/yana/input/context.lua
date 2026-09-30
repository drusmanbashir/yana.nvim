-- yana: gathers editor context (current file, line, or visual selection)
-- to attach to a prompt.
local config = require("yana.config")
local selection_scope = require("yana.input.selection_scope")
local diff = require("yana.diff")

local M = {}

local function relpath(name)
  if not name or name == "" then
    return nil
  end
  local rel = vim.fn.fnamemodify(name, ":.")
  return rel ~= "" and rel or name
end

-- Find the first non-excluded normal-buffer window; return its context.
function M.current_origin(exclude)
  exclude = exclude or {}
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not exclude[buf] and vim.api.nvim_buf_is_valid(buf) then
      local bt = vim.bo[buf].buftype
      if bt == "" then
        local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
        return {
          win = win,
          buf = buf,
          name = relpath(vim.api.nvim_buf_get_name(buf)),
          filetype = vim.bo[buf].filetype,
          cursor = ok and cursor[1] or 1,
        }
      end
    end
  end
  return {}
end

local function filetype_for_buf(buf)
  local ft = vim.bo[buf].filetype
  if ft ~= "" then
    return ft
  end
  local name = vim.api.nvim_buf_get_name(buf)
  if name == "" then
    return ""
  end
  return vim.filetype.match({ filename = name }) or ""
end

-- opts.whole_buffer: a home-folder file's whole buffer goes to the agent uncut
-- the line cap does not apply.
function M.selection_from_range(buf, l1, l2, opts)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  l1 = math.max(l1 or 1, 1)
  l2 = math.max(l2 or l1, l1)
  local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  local cap = config.options.context.max_selection_lines
  local truncated = false
  if #lines > cap and not (opts and opts.whole_buffer) then
    local sliced = {}
    for i = 1, cap do
      sliced[i] = lines[i]
    end
    lines = sliced
    truncated = true
  end
  local selection = {
    name = relpath(vim.api.nvim_buf_get_name(buf)),
    filetype = filetype_for_buf(buf),
    buf = buf,
    l1 = l1,
    l2 = l2,
    lines = lines,
    truncated = truncated,
  }
  require("yana.log").buffer_event("selection", { bufnr = buf, selection = selection })
  return selection
end

-- Format selection.lines as "L<n>|text" strings for the prompt.
function M.numbered_lines(selection)
  if not selection or not selection.lines then
    return {}
  end
  local out = {}
  for i, line in ipairs(selection.lines) do
    table.insert(out, string.format("L%d|%s", selection.l1 + i - 1, line))
  end
  return out
end

local function at_path_from_question(question)
  return question:match("@(/[^\n:]+)")
end

local SEVERITY_NAME = {
  [vim.diagnostic.severity.ERROR] = "ERROR",
  [vim.diagnostic.severity.WARN] = "WARN",
  [vim.diagnostic.severity.INFO] = "INFO",
  [vim.diagnostic.severity.HINT] = "HINT",
}

-- @diagnostics mention support (mentions.lua strip-and-flag): current-buffer
-- diagnostics, formatted for the prompt. nil when there is nothing to show.
local function diagnostics_block(origin)
  if not origin or not origin.buf or not vim.api.nvim_buf_is_valid(origin.buf) then
    return nil
  end
  local diags = vim.diagnostic.get(origin.buf)
  if #diags == 0 then
    return nil
  end
  local lines = { "Diagnostics in `" .. (origin.name or "current buffer") .. "`:" }
  for _, d in ipairs(diags) do
    lines[#lines + 1] = string.format(
      "- L%d: [%s] %s",
      (d.lnum or 0) + 1,
      SEVERITY_NAME[d.severity] or "INFO",
      (d.message or ""):gsub("\n", " ")
    )
  end
  return table.concat(lines, "\n")
end

-- Assemble the full prompt (instructions, context, question); return it.
function M.build(question, origin, selection, opts)
  opts = opts or {}
  local o = config.options
  local parts = {}
  local label = nil
  local mode = config.resolve_mode(opts.mode)
  -- Stale HOME metadata must not override ask/agentic; only inline uses it.
  local home_buffer = mode == "inline" and selection and selection.home_buffer_capture
  -- Standalone default announces; callers suppress when the mini already heard this mode.
  local announce = opts.announce_mode
  if announce == nil then
    announce = true
  end

  if announce then
    local sentence = config.mode_instruction(mode)
    if sentence then
      table.insert(parts, sentence)
      table.insert(parts, "")
    end
  end

  -- Ordinary inline review/scope template only; HOME buffer-only skips it so
  -- it cannot contradict the request-only no-file JSON constraint.
  if mode == "inline" and not home_buffer and o.agent_instructions and o.agent_instructions ~= "" then
    table.insert(parts, "For this request only: " .. o.agent_instructions)
    table.insert(parts, "")
  end

  local at_path = at_path_from_question(question)
  if at_path then
    table.insert(parts, "Edit file: `" .. at_path .. "` (only this file unless the user names others).")
    table.insert(parts, "")
  end

  if selection and selection.lines and #selection.lines > 0 then
    local where = (selection.name or "buffer") .. ":" .. selection.l1 .. "-" .. selection.l2
    label = where
    local fence = selection.filetype and selection.filetype ~= "" and selection.filetype or ""

    -- Scope enforcement text is an inline restriction; selected bytes stay in all modes.
    if mode == "inline" and selection.scope then
      local describe = selection_scope.describe(selection.scope)
      if describe then
        table.insert(parts, "For this request only: " .. describe)
        table.insert(parts, "")
      end
    end

    table.insert(parts, "Selected code (line numbers are absolute file lines):")
    table.insert(parts, "```" .. fence)
    vim.list_extend(parts, M.numbered_lines(selection))
    table.insert(parts, "```")
    if selection.truncated then
      table.insert(parts, "(selection truncated)")
    end
    table.insert(parts, "")
  elseif o.context.include_file and origin and origin.name then
    label = origin.name
    table.insert(parts, string.format(
      "The user is editing `%s` (filetype: %s, cursor on line %d). Open it if you need its contents.",
      origin.name, origin.filetype ~= "" and origin.filetype or "none", origin.cursor or 1
    ))
    table.insert(parts, "")
  end

  if home_buffer then
    table.insert(parts, "This is a buffer-only HOME edit for this request only. Do not write any file. Your entire final response must be one JSON object with exactly one field, replacement_text, containing the complete proposed file text. Do not include a path, markdown fence, explanation, or trailing text.")
    table.insert(parts, "")
  end

  table.insert(parts, question)

  if opts.enable_diagnostics then
    local diag_text = diagnostics_block(origin)
    if diag_text then
      table.insert(parts, "")
      table.insert(parts, diag_text)
    end
  end

  return {
    prompt = table.concat(parts, "\n"),
    label = label,
  }
end

return M
