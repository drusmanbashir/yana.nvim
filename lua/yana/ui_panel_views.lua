-- Bookkeeping for which windows show a panel's conversation in which tabpage. SOLE
-- OWNER of `p.views` -- nothing outside this module may assign to `p.views`,
-- `p.views[tab]`, or any field of a view; every other module reads and writes through
-- the functions below. Pure bookkeeping: this file never creates or closes a window,
-- never touches `panels`, never calls `destroy_panel`, never deletes a buffer.
--
--
-- Why V.find_win exists: `nvim_win_get_tabpage` THROWS on a window Neovim has already
-- freed ("Invalid window id: ..."), and WinClosed always fires after the window is
-- gone. Every view already carries its own tab (both as the p.views key and as .tab),
-- so nothing here ever needs to ask Neovim which tab a window belonged to -- find_win
-- just compares handles it already has. That is also why pruning below never calls
-- nvim_win_get_tabpage: liveness is decided from the record's own stored tab, checked
local M = {}

-- Sentinel: pass as a field's value in V.set to CLEAR that field to nil. A
-- plain Lua table can't tell `{ prompt = nil }` apart from `{}` -- assigning
-- nil to a table key just removes the key, so `pairs(fields)` sees the same
-- thing either way. "Clear this field" needs a value distinct from both nil
-- and absent.
M.NONE = {}

local WRITABLE = { conv = true, prompt = true, closing = true }

local function win_valid(w)
  return type(w) == "number" and w > 0 and vim.api.nvim_win_is_valid(w)
end

local function tab_valid(t)
  return type(t) == "number" and t > 0 and vim.api.nvim_tabpage_is_valid(t)
end

-- Prune and return the record at p.views[tab]. Assumes p.views already
-- exists (every caller below checks that first). Tabpage validity is
-- checked before the record's window is touched at all -- see file header.
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

-- Tab keys, ascending. Callers snapshot this BEFORE mutating p.views (V.each
-- walks the snapshot, not the live table), so a callback that adds, drops or
-- prunes records mid-walk can never corrupt the walk.
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

-- THE only write. Field keys are validated before anything else runs, so a
-- typo'd key fails loudly instead of silently no-op'ing or half-applying.
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

-- Drop the whole record for `tab`. Closes NO windows -- the caller already
-- closed, or is about to close, whatever it built.
function M.clear(p, tab)
  if p == nil or p.views == nil then
    return nil
  end
  tab = tab or vim.api.nvim_get_current_tabpage()
  p.views[tab] = nil
  return nil
end

-- Reverse lookup for a window that may already be dead -- WinClosed's whole
-- reason to call this instead of nvim_win_get_tabpage. Plain handle
-- comparison against handles this module already recorded; never an API
-- call on `win` itself, so a freed window can't make this throw.
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

-- fn(view, tab), ascending tabpage handle. Safe against fn mutating
-- p.views: the walk is over a snapshot taken up front, not the live table.
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

-- Replaces panel_in_tab at ui_panel_lifecycle.lua:128-138. Mirrors that
-- function's own guard -- no tab, no answer -- so unlike V.get/V.conv/
-- V.prompt this does NOT default to the current tabpage.
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

-- Drop every record whose tabpage or `.conv` window has gone. Never touches
-- `panels`, never calls `destroy_panel`, never deletes a buffer -- pruning a
-- view record is not destroying a panel.
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
