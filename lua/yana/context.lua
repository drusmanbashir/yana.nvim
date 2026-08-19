-- yana: gathers editor context (current file, line, or visual selection)
-- to attach to a prompt.
local config = require("yana.config")
local selection_scope = require("yana.selection_scope")

local M = {}

local function relpath(name)
  if not name or name == "" then
    return nil
  end
  local rel = vim.fn.fnamemodify(name, ":.")
  return rel ~= "" and rel or name
end

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
  return {
    name = relpath(vim.api.nvim_buf_get_name(buf)),
    filetype = filetype_for_buf(buf),
    buf = buf,
    l1 = l1,
    l2 = l2,
    lines = lines,
    truncated = truncated,
  }
end

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

local function scope_instructions()
  local path = vim.fn.getcwd() .. "/avante.md"
  if vim.fn.filereadable(path) == 1 then
    return table.concat(vim.fn.readfile(path), "\n")
  end
  return nil
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

function M.build(question, origin, selection, opts)
  opts = opts or {}
  local o = config.options
  local parts = {}
  local label = nil
  local mode = opts.mode or config.resolve_mode(nil)

  if mode == "agent" and o.agent_instructions and o.agent_instructions ~= "" then
    table.insert(parts, o.agent_instructions)
    local scope_text = scope_instructions()
    if scope_text then
      table.insert(parts, scope_text)
    end
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

    if selection.scope then
      local describe = selection_scope.describe(selection.scope)
      if describe then
        table.insert(parts, describe)
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
