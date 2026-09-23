-- Inline edit (Ctrl-K): a one-shot instruction float over a selection. Owns the ENTRY only (float, keymaps,
-- instruction history); on submit it hands (selection, instruction) to yana.ui and returns. Everything after is
-- the ordinary agent turn path, with no special case for inline edit. A float, not the panel prompt, so the
-- cursor never leaves the buffer being read.

local config = require("yana.config")

local M = {}

-- Instruction history, newest last; process-wide (repeated instructions are habits, not per-file).
local history = {}

-- The single live float: inline edit is modal, one cursor cannot answer two questions.
local active = nil

local function opts()
  return config.options.inline_edit
end

local function warn(msg)
  require("yana.notify").one_line(msg, vim.log.levels.WARN)
end

-- `default = true` so a colourscheme wins; without the groups winhighlight renders cleared colours.
local function ensure_highlights()
  vim.api.nvim_set_hl(0, "YanaInlineEditFloat", { link = "NormalFloat", default = true })
  vim.api.nvim_set_hl(0, "YanaInlineEditBorder", { link = "FloatBorder", default = true })
end

local function float_width()
  local w = opts().width
  if w <= 1 then
    return math.max(20, math.floor(vim.o.columns * w))
  end
  return math.max(20, math.floor(w))
end

--- Push an instruction onto the history, newest last, without adjacent repeats.
local function remember(text)
  local cap = opts().history
  if cap <= 0 or text == "" then
    return
  end
  if history[#history] == text then
    return
  end
  history[#history + 1] = text
  while #history > cap do
    table.remove(history, 1)
  end
end

local function close_float(state)
  if state.closed then
    return
  end
  state.closed = true
  require("yana.log").buffer_event("selection_closed", { selection = state.selection,
    outcome = state.submitted and "submitted" or "cancelled" })
  if state.win and vim.api.nvim_win_is_valid(state.win) then
    pcall(vim.api.nvim_win_close, state.win, true)
  end
  if state.buf and vim.api.nvim_buf_is_valid(state.buf) then
    pcall(vim.api.nvim_buf_delete, state.buf, { force = true })
  end
  if active == state then
    active = nil
  end
  -- Return the cursor unconditionally (not only on cancel) so submit never steals focus into the sidebar.
  if state.origin_win and vim.api.nvim_win_is_valid(state.origin_win) then
    pcall(vim.api.nvim_set_current_win, state.origin_win)
  end
end

local function float_text(state)
  local lines = vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)
  return vim.trim(table.concat(lines, "\n"))
end

local function set_float_text(state, text)
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, vim.split(text, "\n", { plain = true }))
  local last = vim.api.nvim_buf_line_count(state.buf)
  pcall(vim.api.nvim_win_set_cursor, state.win, { last, #(vim.api.nvim_buf_get_lines(state.buf, last - 1, last, false)[1] or "") })
end

local function step_history(state, delta)
  if #history == 0 then
    return
  end
  -- idx 0 = not browsing; entering history stashes the typed draft so stepping back past the newest restores it.
  if state.hist_idx == 0 then
    state.hist_draft = float_text(state)
    state.hist_idx = #history + 1
  end
  local idx = state.hist_idx + delta
  if idx < 1 then
    idx = 1
  end
  if idx > #history + 1 then
    idx = #history + 1
  end
  state.hist_idx = idx
  set_float_text(state, idx > #history and (state.hist_draft or "") or history[idx])
end

local function submit(state)
  local text = float_text(state)
  if text == "" then
    -- An empty instruction is a cancel; sending it would burn a turn on noise.
    close_float(state)
    return
  end
  remember(text)
  local selection = state.selection
  state.submitted = true
  close_float(state)
  require("yana.panel.ui").inline_edit(selection, text)
end

local function apply_keymaps(state)
  local k = config.options.mappings
  local function map(modes, lhs, fn)
    if type(lhs) ~= "string" or lhs == "" then
      return
    end
    vim.keymap.set(modes, lhs, fn, { buffer = state.buf, silent = true, nowait = true })
  end
  map({ "n", "i" }, k.submit, function()
    submit(state)
  end)
  -- close in normal mode, stop in insert mode; insert-mode <CR> still inserts a newline.
  map("n", k.close, function()
    close_float(state)
  end)
  map("i", k.stop, function()
    close_float(state)
  end)
  if opts().history > 0 then
    map({ "n", "i" }, k.history_prev, function()
      step_history(state, -1)
    end)
    map({ "n", "i" }, k.history_next, function()
      step_history(state, 1)
    end)
  end
end

--- Grow the float as the instruction wraps or gains lines, up to max_height.
local function fit_height(state)
  if not (state.win and vim.api.nvim_win_is_valid(state.win)) then
    return
  end
  local width = vim.api.nvim_win_get_width(state.win)
  local rows = 0
  for _, line in ipairs(vim.api.nvim_buf_get_lines(state.buf, 0, -1, false)) do
    rows = rows + math.max(1, math.ceil(vim.fn.strdisplaywidth(line) / math.max(width, 1)))
  end
  local height = math.max(1, math.min(rows, opts().max_height))
  if height ~= vim.api.nvim_win_get_height(state.win) then
    pcall(vim.api.nvim_win_set_height, state.win, height)
  end
end

--- Open the instruction float over a line range.
---@param buf integer  buffer holding the lines (0 = current)
---@param l1 integer    first line, 1-indexed inclusive
---@param l2 integer    last line, 1-indexed inclusive
---@param instruction string|nil  if given and non-empty, skip the float entirely
function M.open(buf, l1, l2, instruction)
  if not opts().enable then
    warn("yana: inline edit is disabled (inline_edit.enable = false)")
    return
  end
  if buf == nil or buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  if not vim.api.nvim_buf_is_valid(buf) then
    return
  end
  if l1 > l2 then
    l1, l2 = l2, l1
  end

  -- Refuse scratch/plugin buffers at the entry: no path to name, so the agent could only guess where the lines live.
  if vim.bo[buf].buftype ~= "" or vim.api.nvim_buf_get_name(buf) == "" then
    warn("yana: inline edit needs a saved file buffer")
    return
  end

  local selection = require("yana.input.context").selection_from_range(buf, l1, l2)
  if not selection then
    warn("yana: could not read the selected lines")
    return
  end

  -- `:YanaEdit fix the loop` skips the float: the instruction is already known.
  if type(instruction) == "string" and vim.trim(instruction) ~= "" then
    remember(vim.trim(instruction))
    require("yana.panel.ui").inline_edit(selection, vim.trim(instruction))
    return
  end

  -- Re-entry replaces rather than stacks.
  if active then
    close_float(active)
  end

  local state = {
    selection = selection,
    origin_win = vim.api.nvim_get_current_win(),
    hist_idx = 0,
    hist_draft = nil,
  }
  state.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[state.buf].buftype = "nofile"
  vim.bo[state.buf].bufhidden = "wipe"
  vim.bo[state.buf].swapfile = false
  vim.bo[state.buf].filetype = "yana_inline_edit"

  local label = string.format("  edit %s L%d-%d ", selection.name or "buffer", selection.l1, selection.l2)
  ensure_highlights()
  local width = float_width()
  state.win = vim.api.nvim_open_win(state.buf, true, {
    relative = "cursor",
    row = 1,
    col = 0,
    width = width,
    height = 1,
    style = "minimal",
    border = "rounded",
    title = label,
    title_pos = "left",
    -- The footer is the only key discoverability: a transient window has no help page.
    footer = string.format(
      " %s send · %s close ",
      config.options.mappings.submit or "",
      config.options.mappings.close or ""
    ),
    footer_pos = "right",
  })
  vim.wo[state.win].wrap = true
  vim.wo[state.win].winhighlight = "NormalFloat:YanaInlineEditFloat,FloatBorder:YanaInlineEditBorder"

  apply_keymaps(state)

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    buffer = state.buf,
    callback = function()
      -- Typing after history browsing takes the entry over; <C-p> then browses from a fresh index.
      state.hist_idx = 0
      fit_height(state)
    end,
  })
  -- Leaving the float is a cancel; otherwise an orphan window's keymaps fire into a dead selection.
  vim.api.nvim_create_autocmd("WinLeave", {
    buffer = state.buf,
    once = true,
    callback = function()
      vim.schedule(function()
        close_float(state)
      end)
    end,
  })

  active = state
  vim.cmd("startinsert")
  return state
end

--- Open over the current visual selection, leaving visual mode first.
function M.open_visual()
  local l1 = vim.fn.line("v")
  local l2 = vim.fn.line(".")
  if l1 > l2 then
    l1, l2 = l2, l1
  end
  vim.cmd("normal! \27")
  M.open(0, l1, l2, nil)
end

M._test = M._test or {}
M._test.history = function()
  return history
end
M._test.active = function()
  return active
end
M._test.close = close_float
M._test.submit = submit
M._test.step_history = step_history

return M
