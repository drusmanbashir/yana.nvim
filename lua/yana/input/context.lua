-- yana: gathers editor context (current file, line, or visual selection)
-- to attach to a prompt.
local config = require("yana.config")
local prompts = require("yana.prompts")

local M = {}

-- A buffer's absolute path, or nil for an unnamed buffer.
local function buffer_path(buf)
  local name = vim.api.nvim_buf_get_name(buf)
  return name ~= "" and name or nil
end

-- The file window the operator is in or just left, else the first in the tab.
function M.current_origin(exclude)
  exclude = exclude or {}
  local wins = { vim.api.nvim_get_current_win(), vim.fn.win_getid(vim.fn.winnr("#")) }
  vim.list_extend(wins, vim.api.nvim_tabpage_list_wins(0))
  for _, win in ipairs(wins) do
    local buf = vim.api.nvim_win_get_buf(win)
    if not exclude[buf] and vim.api.nvim_buf_is_valid(buf) then
      local bt = vim.bo[buf].buftype
      if bt == "" then
        local ok, cursor = pcall(vim.api.nvim_win_get_cursor, win)
        return {
          win = win,
          buf = buf,
          name = buffer_path(buf),
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

function M.selection_from_range(buf, l1, l2)
  if not (buf and vim.api.nvim_buf_is_valid(buf)) then
    return nil
  end
  l1 = math.max(l1 or 1, 1)
  l2 = math.max(l2 or l1, l1)
  local lines = vim.api.nvim_buf_get_lines(buf, l1 - 1, l2, false)
  local cap = config.options.context.max_selection_lines
  local truncated = false
  if #lines > cap then
    local sliced = {}
    for i = 1, cap do
      sliced[i] = lines[i]
    end
    lines = sliced
    truncated = true
  end
  local selection = {
    name = buffer_path(buf),
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
  local lines = { prompts.render("diagnostics_header", { file = origin.name or "current buffer" }) }
  for _, d in ipairs(diags) do
    lines[#lines + 1] = prompts.render("diagnostics_line", {
      line = (d.lnum or 0) + 1,
      severity = SEVERITY_NAME[d.severity] or "INFO",
      message = ((d.message or ""):gsub("\n", " ")),
    })
  end
  return table.concat(lines, "\n")
end

-- The sentence naming the operator's file and cursor line, or nil with no file.
function M.file_hint(origin)
  if not (origin and origin.name) then
    return nil
  end
  return prompts.render("editing_file_hint", {
    file = origin.name,
    filetype = origin.filetype ~= "" and origin.filetype or "none",
    line = origin.cursor or 1,
  })
end

-- Assemble the full prompt (instructions, context, question); return it.
function M.build(question, origin, selection, opts)
  opts = opts or {}
  local parts = {}
  local label = nil
  local file = nil
  local mode = config.resolve_mode(opts.mode)
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

  if selection and selection.lines and #selection.lines > 0 then
    label = (selection.name or "buffer") .. ":" .. selection.l1 .. "-" .. selection.l2
    file = selection.name
    local fence = selection.filetype and selection.filetype ~= "" and selection.filetype or ""

    table.insert(parts, prompts.render("selected_code_header", {
      file = selection.name or "unnamed buffer",
    }))
    table.insert(parts, "```" .. fence)
    vim.list_extend(parts, M.numbered_lines(selection))
    table.insert(parts, "```")
    if selection.truncated then
      table.insert(parts, prompts.render("selection_truncated"))
    end
    if mode == "inline" then
      table.insert(parts, prompts.render("selection_not_a_limit"))
    end
    table.insert(parts, "")
  else
    local hint = M.file_hint(origin)
    if hint then
      label = origin.name
      file = origin.name
      -- Standalone default names the file; callers suppress when the mini already heard it.
      if opts.announce_file ~= false then
        table.insert(parts, hint)
        table.insert(parts, "")
      end
    end
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
    file = file,
  }
end

return M
