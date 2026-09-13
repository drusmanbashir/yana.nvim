-- Yana's own sidebar width, and nothing else's.
--
-- It records the width it was given, and when a foreign layout change takes columns
-- from it -- or hands it columns it never asked for -- it sets its OWN width back to
-- the record. Neovim then takes the difference from the adjacent window, which is the
-- window that moved.
--
-- This replaces `with_external_heights_fixed`, which froze every other window for the
-- duration of a yana operation.
--
-- WHO CALLS WHAT
--   ui_panel_layout.open_windows -> M.observe(tab)   after the panel is built
--   ui_panel_layout.open_windows -> M.desired(tab)   the width to open at
--   autocmds (M.setup)           -> M.reassert(tab)  after anyone's layout change
--
-- The record OUTLIVES the panel. A competing sidebar closes yana and reopens it
-- (nvim-tree does exactly this through the exclusivity manager), and dropping
-- the record on close handed the user back the configured default instead of
-- the width they dragged.
--
-- A resize of a panel window with no split or close in the same tick is the
-- user dragging the border, so it becomes the new record instead of being
-- undone. A terminal resize (VimResized) drops the record: the configured
-- width may be a fraction of the screen, so the next open recomputes it.

local M = {}

local widths = {} -- tabpage handle -> desired width in columns
local layout_dirty = false -- a split or close happened, this tick's resizes are its consequence
local applying = false -- a reassert is in flight; its own resize is not a drag
local scheduled = false

local function tab_valid(tab)
  return type(tab) == "number" and vim.api.nvim_tabpage_is_valid(tab)
end

--- Every non-floating window in `tab` that carries a yana panel buffer.
local function panel_wins(tab)
  local out = {}
  if not tab_valid(tab) then
    return out
  end
  for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
    if vim.api.nvim_win_get_config(win).relative == "" then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].yana_panel then
        out[#out + 1] = win
      end
    end
  end
  return out
end

local function current_width(tab)
  local wins = panel_wins(tab)
  if #wins == 0 then
    return nil
  end
  -- Sidebar span from the leftmost to the rightmost yana window (one column
  -- under default split; still correct if a layout opens multiple columns).
  local left, right = nil, nil
  for _, win in ipairs(wins) do
    local wi = vim.fn.getwininfo(win)[1]
    if wi then
      local l = wi.wincol
      local r = wi.wincol + wi.width - 1
      if left == nil or l < left then
        left = l
      end
      if right == nil or r > right then
        right = r
      end
    end
  end
  if left == nil or right == nil then
    return vim.api.nvim_win_get_width(wins[1])
  end
  return right - left + 1
end

--- Record whatever width the panel currently has in `tab`.
function M.observe(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local w = current_width(tab)
  if w then
    widths[tab] = w
  end
end

--- Record an explicit width for `tab`.
function M.remember(tab, width)
  if tab_valid(tab) and type(width) == "number" and width > 0 then
    widths[tab] = width
  end
end

function M.forget(tab)
  if tab ~= nil then
    widths[tab] = nil
  end
end

function M.desired(tab)
  return widths[tab or vim.api.nvim_get_current_tabpage()]
end

--- Put the panel back to its recorded width. Returns the columns reclaimed
--- (negative when yana handed columns back), or nil when there is nothing to do.
function M.reassert(tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  local want = widths[tab]
  if not want then
    return nil
  end
  local wins = panel_wins(tab)
  if #wins == 0 then
    return nil
  end
  local have = current_width(tab)
  if not have or have == want then
    return nil
  end
  -- One column: set that column's width. Multiple columns (legacy/non-default)
  -- share the recorded span; open_windows owns their rebuild, so skip here.
  local col_keys = {}
  for _, win in ipairs(wins) do
    local wi = vim.fn.getwininfo(win)[1]
    if wi then
      col_keys[wi.wincol] = true
    end
  end
  local ncols = 0
  for _ in pairs(col_keys) do
    ncols = ncols + 1
  end
  if ncols ~= 1 then
    return nil
  end
  local ok = pcall(vim.api.nvim_win_set_width, wins[1], want)
  if not ok then
    return nil
  end
  return want - have
end

local function schedule()
  if scheduled then
    return
  end
  scheduled = true
  vim.schedule(function()
    scheduled = false
    local tab = vim.api.nvim_get_current_tabpage()
    applying = true
    pcall(M.reassert, tab)
    applying = false
    layout_dirty = false
    for t in pairs(widths) do
      if not tab_valid(t) then
        widths[t] = nil
      end
    end
  end)
end

--- True when the windows named by a WinResized event include a panel window.
local function resize_touched_panel(tab)
  local wins = vim.v.event and vim.v.event.windows or nil
  if type(wins) ~= "table" then
    return #panel_wins(tab) > 0
  end
  for _, win in ipairs(wins) do
    if vim.api.nvim_win_is_valid(win) then
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.b[buf].yana_panel then
        return true
      end
    end
  end
  return false
end

local attached = false

function M.setup()
  if attached then
    return
  end
  attached = true
  local group = vim.api.nvim_create_augroup("YanaGeometry", { clear = true })

  -- WinClosed runs while the closing window is still valid and the layout is still
  -- intact, so it is the last honest look at the panel's width before somebody
  -- redistributes its columns. That is where a width the user dragged gets recorded --
  -- including the case that matters most, an exclusivity manager closing yana to put
  -- its own sidebar there. The record therefore survives a close untouched.
  vim.api.nvim_create_autocmd("WinClosed", {
    group = group,
    callback = function()
      layout_dirty = true
      schedule()
    end,
  })

  -- WinNew fires AFTER the new window already took its columns, so observing
  -- here would record the theft as the user's wish. Only reconcile.
  vim.api.nvim_create_autocmd("WinNew", {
    group = group,
    callback = function()
      layout_dirty = true
      schedule()
    end,
  })

  vim.api.nvim_create_autocmd("WinResized", {
    group = group,
    callback = function()
      if applying then
        return
      end
      local tab = vim.api.nvim_get_current_tabpage()
      if layout_dirty then
        schedule()
      elseif resize_touched_panel(tab) then
        -- Nothing opened or closed, so this is the user dragging the border.
        -- NOT PROVEN: WinResized never fires in the driven harness -- zero events
        -- across splits, API resizes and plugin opens -- so this path is
        -- unverified. The WinClosed observe above is what the matrix exercises.
        M.observe(tab)
      end
    end,
  })

  vim.api.nvim_create_autocmd("TabEnter", {
    group = group,
    callback = schedule,
  })

  vim.api.nvim_create_autocmd("VimResized", {
    group = group,
    callback = function()
      widths = {}
    end,
  })
end

-- Test seam: the oracle's sidepane-geometry adapter drives these directly
-- rather than reaching into the locals.
M._test = {
  panel_wins = panel_wins,
  current_width = current_width,
  state = function()
    return { widths = widths, layout_dirty = layout_dirty, applying = applying }
  end,
  reset = function()
    widths, layout_dirty, applying, scheduled = {}, false, false, false
  end,
}

return M
