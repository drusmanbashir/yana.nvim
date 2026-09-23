-- Prompt-window helpers for ui_panel_layout (size split).
local config = require("yana.config")
local views = require("yana.panel.ui_panel_views")

local M = {}

function M.new(deps)
  local depth = deps.depth
  local win_valid = deps.win_valid
  local cur_tab = deps.cur_tab
  local views_in_tab = deps.views_in_tab
  local split_in = deps.split_in
  local win_opts = deps.win_opts
  local update_winbar = deps.update_winbar
  local mark_prompt_owner = deps.mark_prompt_owner

  -- Steal height from sibling conversation/prompt windows so `conv` can hold a prompt.
  local function make_room_for_prompt(tab, conv, ph)
    if not win_valid(conv) then
      return
    end
    local need = math.max(3, (ph or 3) + 2)
    if vim.api.nvim_win_get_height(conv) >= need then
      return
    end
    local prev_min = vim.o.winminheight
    vim.o.winminheight = 1
    local function steal(win, floor)
      if not win_valid(win) or win == conv then
        return
      end
      local have = vim.api.nvim_win_get_height(conv)
      if have >= need then
        return
      end
      local ch = vim.api.nvim_win_get_height(win)
      if ch > floor then
        local give = math.min(ch - floor, need - have)
        pcall(vim.api.nvim_win_set_height, win, ch - give)
        pcall(vim.api.nvim_win_set_height, conv, have + give)
      end
    end
    for _, e in ipairs(views_in_tab(tab)) do
      steal(e.conv, 3)
      steal(e.prompt, 1)
    end
    vim.o.winminheight = prev_min
  end

  -- Create this panel's own prompt under its conversation; never take another
  -- chat's prompt window.
  local function ensure_prompt_win(p, tab)
    tab = tab or cur_tab()
    if win_valid(views.prompt(p, tab)) then
      return
    end
    local conv = views.conv(p, tab)
    if not win_valid(conv) then
      return
    end
    depth:enter()
    local ok, err = pcall(function()
      local prev_ea = vim.o.equalalways
      vim.o.equalalways = false
      local ph = config.options.ui.prompt_height
      make_room_for_prompt(tab, conv, ph)
      local created = split_in(conv, "belowright split")
      if created then
        vim.api.nvim_win_set_buf(created, p.prompt_buf)
        views.set(p, tab, { prompt = created })
        win_opts(created, true)
        pcall(vim.api.nvim_win_set_height, created, ph)
        update_winbar(p)
        mark_prompt_owner(p, tab)
      end
      vim.o.equalalways = prev_ea
    end)
    depth:leave()
    if not ok then
      error(err)
    end
  end

  return {
    make_room_for_prompt = make_room_for_prompt,
    ensure_prompt_win = ensure_prompt_win,
  }
end

return M
