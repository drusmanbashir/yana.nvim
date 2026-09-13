-- Focus / rotate navigation for ui_panel_layout (size split).
local views = require("yana.ui_panel_views")
local policy = require("yana.ui_panel_layout_policy")

local M = {}

function M.new(deps)
  local S = deps.state
  local panels = deps.panels
  local win_valid = deps.win_valid
  local open_windows = deps.open_windows
  local ensure_prompt_win = deps.ensure_prompt_win
  local hide_others = deps.hide_others
  local mark_prompt_owner = deps.mark_prompt_owner
  local focus_prompt_dep = deps.focus_prompt
  local cur_tab = deps.cur_tab

  local function focus_panel(p, tab)
    tab = tab or cur_tab()
    if not p then
      return
    end
    if policy.is_rotate() then
      if not (win_valid(views.conv(p, tab)) and win_valid(views.prompt(p, tab))) then
        hide_others(p, tab)
        open_windows(p, tab)
      end
    else
      if not win_valid(views.conv(p, tab)) then
        open_windows(p, tab)
      elseif not win_valid(views.prompt(p, tab)) then
        ensure_prompt_win(p, tab)
      end
    end
    mark_prompt_owner(p, tab)
    if focus_prompt_dep then
      focus_prompt_dep(p, tab)
    else
      local prompt = views.prompt(p, tab)
      if win_valid(prompt) then
        pcall(vim.api.nvim_set_current_win, prompt)
      end
    end
    S.last_panel = p
  end

  local function cycle_panels(p, step)
    local tab = cur_tab()
    local ordered = policy.ordered_panels(panels)
    if #ordered < 2 then
      return
    end
    local from = p or S.last_panel or ordered[1]
    local target = policy.step(ordered, from, step)
    if target then
      focus_panel(target, tab)
    end
  end

  local function next_panel(p)
    cycle_panels(p, 1)
  end

  local function prev_panel(p)
    cycle_panels(p, -1)
  end

  local function show_next_after_close(closed, tab)
    if not policy.is_rotate() then
      return
    end
    tab = tab or cur_tab()
    local ordered = policy.ordered_panels(panels)
    local survivors = {}
    for _, q in ipairs(ordered) do
      if q ~= closed then
        survivors[#survivors + 1] = q
      end
    end
    if #survivors == 0 then
      return
    end
    local at = policy.index_of(ordered, closed) or 1
    local prefer = nil
    for i = 0, #ordered - 1 do
      local cand = ordered[((at - 1 + i) % #ordered) + 1]
      if cand ~= closed then
        prefer = cand
        break
      end
    end
    prefer = prefer or survivors[1]
    open_windows(prefer, tab)
    mark_prompt_owner(prefer, tab)
    S.last_panel = prefer
  end

  return {
    focus_panel = focus_panel,
    next_panel = next_panel,
    prev_panel = prev_panel,
    show_next_after_close = show_next_after_close,
  }
end

return M
