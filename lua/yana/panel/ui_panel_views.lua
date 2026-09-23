-- Bookkeeping for which windows show a panel's conversation in which tabpage. SOLE OWNER of `p.views`: everything else
-- reads and writes through these functions. Pure bookkeeping: never creates or closes a window, touches `panels`,
-- calls `destroy_panel`, or deletes a buffer.
--
-- V.find_win compares recorded handles only: `nvim_win_get_tabpage` THROWS on a window Neovim already freed, and
-- WinClosed fires after the window is gone. Pruning likewise decides liveness from the record's own stored tab.
local M = {}

-- Sentinel for V.set: clears a field (a plain table cannot tell `{ prompt = nil }` from `{}`).
M.NONE = {}

local WRITABLE = { conv = true, prompt = true, closing = true }

local function win_valid(w)
  return type(w) == "number" and w > 0 and vim.api.nvim_win_is_valid(w)
end

local function tab_valid(t)
  return type(t) == "number" and t > 0 and vim.api.nvim_tabpage_is_valid(t)
end

-- Prune and return the record at p.views[tab]; tabpage validity is checked before the record's window is touched.
local function prune_one(p, tab)
  local view = p.views[tab]
  if view == nil then
    return nil
  end
  if not tab_valid(tab) or not win_valid(view.conv) then
    p.views[tab] = nil
    return nil
  end
  if not win_valid(view.prompt) then
    view.prompt = nil
  end
  return view
end

-- Tab keys ascending; callers snapshot BEFORE mutating p.views so a V.each callback cannot corrupt the walk.
local function sorted_tabs(p)
  local out = {}
  for tab in pairs(p.views) do
    out[#out + 1] = tab
  end
  table.sort(out)
  return out
end

function M.get(p, tab)
  if p == nil then
    return nil
  end
  tab = tab or vim.api.nvim_get_current_tabpage()
  p.views = p.views or {}
  return prune_one(p, tab)
end

function M.conv(p, tab)
  local view = M.get(p, tab)
  if view == nil then
    return nil
  end
  return view.conv
end

function M.prompt(p, tab)
  local view = M.get(p, tab)
  if view == nil then
    return nil
  end
  return view.prompt
end

-- THE only write. Keys are validated first so a typo fails loudly.
function M.set(p, tab, fields)
  fields = fields or {}
  for key in pairs(fields) do
    if not WRITABLE[key] then
      error("yana.ui_panel_views: V.set cannot write field '" .. tostring(key) .. "'", 2)
    end
  end
  if p == nil then
    return nil
  end
  tab = tab or vim.api.nvim_get_current_tabpage()
  p.views = p.views or {}
  local view = p.views[tab] or { tab = tab }
  p.views[tab] = view
  for key, value in pairs(fields) do
    view[key] = (value == M.NONE) and nil or value
  end
  return view
end

-- Drop the record for `tab`. Closes NO windows.
function M.clear(p, tab)
  if p == nil or p.views == nil then
    return nil
  end
  tab = tab or vim.api.nvim_get_current_tabpage()
  p.views[tab] = nil
  return nil
end

-- Reverse lookup for a possibly dead window (WinClosed): handle comparison only, never an API call on `win`.
function M.find_win(p, win)
  if p == nil or p.views == nil or win == nil then
    return nil
  end
  for tab, view in pairs(p.views) do
    if view.conv == win or view.prompt == win then
      return view, tab
    end
  end
  return nil
end

function M.forget_win(p, win)
  local view, tab = M.find_win(p, win)
  if view == nil then
    return nil
  end
  if view.conv == win then
    p.views[tab] = nil
  else
    view.prompt = nil
  end
  return view
end

-- fn(view, tab), ascending tab; walks a snapshot so fn may mutate p.views.
function M.each(p, fn)
  if p == nil or p.views == nil then
    return nil
  end
  for _, tab in ipairs(sorted_tabs(p)) do
    local view = prune_one(p, tab)
    if view ~= nil then
      fn(view, tab)
    end
  end
  return nil
end

function M.tabs(p)
  if p == nil or p.views == nil then
    return {}
  end
  M.prune(p)
  return sorted_tabs(p)
end

function M.count(p)
  if p == nil or p.views == nil then
    return 0
  end
  M.prune(p)
  local n = 0
  for _ in pairs(p.views) do
    n = n + 1
  end
  return n
end

-- No tab, no answer: unlike V.get/V.conv/V.prompt this does NOT default to the current tabpage.
function M.panel_in_tab(panels, tab)
  if not panels or not tab then
    return nil
  end
  for _, p in ipairs(panels) do
    if M.get(p, tab) ~= nil then
      return p
    end
  end
  return nil
end

-- Drop records whose tabpage or `.conv` window has gone; pruning a view is not destroying a panel.
function M.prune(p)
  if p == nil or p.views == nil then
    return nil
  end
  for _, tab in ipairs(sorted_tabs(p)) do
    prune_one(p, tab)
  end
  return nil
end

return M
