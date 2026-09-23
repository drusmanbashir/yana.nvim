-- Close/quit helpers for ui_panel_lifecycle (size split).
local ledger = require("yana.ledger")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local V = require("yana.panel.ui_panel_views")

local M = {}

function M.new(deps)
  local focus = deps.focus
  local depth = deps.depth
  local cancel_inflight = deps.cancel_inflight
  local panels = deps.panels
  local win_valid = deps.win_valid
  local buf_valid = deps.buf_valid
  local panel_index = deps.panel_index
  local current_panel = deps.current_panel
  local prune_panels = deps.prune_panels
  local destroy_panel = deps.destroy_panel
  local stop_spinner = deps.stop_spinner
  local ensure_prompt_win = deps.ensure_prompt_win
  local relayout = deps.relayout
  local panel_open_in = deps.panel_open_in
  local get_show_next = deps.get_show_next
  local set_show_next = deps.set_show_next
  local open = deps.open

  local function preserve_survivor_prompt(tab, prefer)
    if not (tab and vim.api.nvim_tabpage_is_valid(tab)) then
      return
    end
    local survivors = {}
    for _, q in ipairs(panels) do
      if win_valid(V.conv(q, tab)) then
        survivors[#survivors + 1] = q
      end
    end
    if #survivors == 0 then
      return
    end
    local target = prefer
    if not (target and win_valid(V.conv(target, tab))) then
      target = survivors[1]
    end
    if win_valid(V.prompt(target, tab)) then
      return
    end
    -- The rebuild may enter the target's buffer; restore whatever held the recent
    -- reference so closing one chat does not silently promote another.
    local saved_recent = focus:last()
    depth:enter()
    pcall(ensure_prompt_win, target, tab)
    depth:leave()
    focus:set_last(saved_recent)
  end

  local function quit_panel(p)
    local idx = panel_index(p)
    if idx == 0 then
      return false
    end

    local strip_tabs = {}
    pcall(function()
      strip_tabs = require("yana.panel.ui_review_buttons").detach_panel(p) or {}
    end)

    cancel_inflight(p)
    stop_spinner(p)
    p.closing = true
    local tabs = V.tabs(p)
    V.each(p, function(view, tab)
      local prev_ea = vim.o.equalalways
      vim.o.equalalways = false
      pcall(require("yana.panel.ui_review_buttons").detach_windows, tab, p)
      local prompt_win = V.prompt(p, tab)
      if win_valid(prompt_win) then
        pcall(vim.api.nvim_win_close, prompt_win, true)
      end
      if win_valid(view.conv) then
        pcall(vim.api.nvim_win_close, view.conv, true)
      end
      vim.o.equalalways = prev_ea
      V.clear(p, tab)
    end)
    destroy_panel(p)
    table.remove(panels, idx)
    focus:forget(p)

    local bufs = { p.prompt_buf, p.conv_buf }
    for _, buf in ipairs(bufs) do
      if buf_valid(buf) then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
      end
    end
    local show_next = get_show_next and get_show_next() or nil
    for _, tab in ipairs(tabs) do
      if show_next then
        show_next(p, tab)
      end
      preserve_survivor_prompt(tab, focus:last())
    end
    p.closing = false
    ledger.drop_panel(p.id)
    local reattach = {}
    for _, tab in ipairs(tabs) do
      relayout(tab)
      reattach[tab] = true
    end
    for _, tab in ipairs(strip_tabs) do
      reattach[tab] = true
    end
    for tab in pairs(reattach) do
      vim.schedule(function()
        if vim.api.nvim_tabpage_is_valid(tab) then
          pcall(require("yana.panel.ui_review_buttons").attach_tab, tab)
        end
      end)
    end
    return true
  end

  local function quit_current()
    prune_panels()
    local p = current_panel()
    if not p then
      notify_one_line("yana: no panel to quit", vim.log.levels.INFO)
      return false
    end
    return quit_panel(p)
  end

  local function quit_all()
    prune_panels()
    local count = #panels
    for i = #panels, 1, -1 do
      quit_panel(panels[i])
    end
    return count
  end

  local function close_panel_windows(p, tab)
    stop_spinner(p)
    V.set(p, tab, { closing = true })
    local survivors = {}
    local skip = {
      [V.prompt(p, tab) or -1] = true,
      [V.conv(p, tab) or -1] = true,
    }
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if not skip[w] then
        survivors[#survivors + 1] = { win = w, height = vim.api.nvim_win_get_height(w) }
      end
    end
    local prev_ea = vim.o.equalalways
    vim.o.equalalways = false
    pcall(require("yana.panel.ui_review_buttons").detach_windows, tab, p)
    local prompt_win = V.prompt(p, tab)
    if win_valid(prompt_win) then
      pcall(vim.api.nvim_win_close, prompt_win, true)
    end
    local conv_win = V.conv(p, tab)
    if win_valid(conv_win) then
      pcall(vim.api.nvim_win_close, conv_win, true)
    end
    V.clear(p, tab)
    local show_next = get_show_next and get_show_next() or nil
    if show_next then
      show_next(p, tab)
    end
    preserve_survivor_prompt(tab, focus:last())
    vim.o.equalalways = prev_ea
    for _, s in ipairs(survivors) do
      if win_valid(s.win) and vim.api.nvim_win_get_height(s.win) ~= s.height then
        pcall(vim.api.nvim_win_set_height, s.win, s.height)
      end
    end
  end

  local function close_panel(p, tab)
    p = p or current_panel()
    if not p then
      return
    end
    tab = tab or vim.api.nvim_get_current_tabpage()
    return close_panel_windows(p, tab)
  end

  local function close()
    local tab = vim.api.nvim_get_current_tabpage()
    local closing = {}
    for _, p in ipairs(panels) do
      if panel_open_in(p, tab) then
        closing[#closing + 1] = p
      end
    end
    local saved = get_show_next and get_show_next() or nil
    if set_show_next then
      set_show_next(nil)
    end
    for _, p in ipairs(closing) do
      close_panel_windows(p, tab)
    end
    if set_show_next then
      set_show_next(saved)
    end
  end

  local function toggle()
    local tab = vim.api.nvim_get_current_tabpage()
    local p = V.panel_in_tab(panels, tab)
    if panel_open_in(p, tab) then
      close()
    else
      open()
    end
  end

  return {
    quit_panel = quit_panel,
    quit_current = quit_current,
    quit_all = quit_all,
    close_panel = close_panel,
    close = close,
    toggle = toggle,
  }
end

return M
