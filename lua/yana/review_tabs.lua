-- Review tabs: the ONE place that decides where a reviewed file's window
-- lives, opens the tab when Yana must, mirrors the sidebar into it and
-- records ownership. "End review?" is the one dialog, and Yana-opened tabs
-- MIRROR the first tab's sidebar.
--
-- `owned` has ONE writer: `T.place`. review_tabs_record.lua mirrors the record to disk.
-- decide `placement_for`: pure and total; every caller obeys it.
local diff = require("yana.diff")
local log = require("yana.log")
local record = require("yana.review_tabs_record")

local M = {}

local function tab_for_path(path)
  local abs = diff.abs_path(path)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local bufnr = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(bufnr) then
        local name = vim.api.nvim_buf_get_name(bufnr)
        if name ~= "" and diff.abs_path(name) == abs then
          return tab, win, bufnr
        end
      end
    end
  end
  return nil, nil, nil
end

-- `config.review.tabs = false` is the operator saying "never spend a tab on a
-- review". Review opts carry the same answer (ui_review.lua fills
-- opts.review_tabs from config); config is read when no opts are at hand.
local function tabs_enabled(opts)
  if opts and opts.review_tabs ~= nil then
    return opts.review_tabs ~= false
  end
  local ok, cfg = pcall(require, "yana.config")
  local review = ok and type(cfg) == "table" and type(cfg.options) == "table" and cfg.options.review or nil
  return not (type(review) == "table" and review.tabs == false)
end

local function sidebar_ui()
  local ok, ui = pcall(require, "yana.ui")
  if not ok or type(ui) ~= "table" then
    return nil
  end
  if type(ui.is_open) ~= "function" or type(ui.open_in_tab) ~= "function" then
    return nil
  end
  return ui
end

-- The sidebar answer belongs to the originating tab and is sampled once per
-- turn: sidebar open there means a sidebar in every tab Yana opens for it.
local function origin_sidebar_open(tab)
  local ui = sidebar_ui()
  if not ui then
    return false
  end
  local ok, open = pcall(ui.is_open, tab)
  return ok and open == true
end

-- Show the EXISTING conversation in `tab`.
local function mirror_sidebar(tab)
  local ui = sidebar_ui()
  if not ui or not tab then
    return "no_ui"
  end
  local ok, panel = pcall(ui.open_in_tab, tab)
  if not ok then
    return "error"
  end
  return panel ~= nil and "mirrored" or "no_conversation"
end

local function turn_key(change)
  if not change then
    return nil
  end
  return tostring(change.turn_id or change.turn_gen or "")
end

-- PURE. Where does a reviewed file that has no window go? shown a window already shows
-- it: reuse, never Yana-owned.
local function placement_for(shown, tabs_on, multi, spare)
  if shown then
    return "shown"
  end
  if not tabs_on then
    return spare and "reuse_win" or "none"
  end
  if multi then
    return "yana_tab"
  end
  return spare and "reuse_win" or "yana_tab"
end

-- An empty, ordinary, non-panel window anywhere (the reuse target the old
-- focus_buf also preferred over spending a tab).
local function spare_window()
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    local b = vim.api.nvim_win_get_buf(w)
    if vim.api.nvim_win_get_config(w).relative == ""
      and vim.bo[b].buftype == ""
      and vim.api.nvim_buf_get_name(b) == ""
      and not vim.b[b].yana_panel
    then
      return w
    end
  end
  return nil
end

-- The ONE writer of `rt.owned` (rule: one owner per fact). Everything that
-- makes a tab Yana's goes through here.
local function adopt(rt, abs, tab, rel)
  rt.owned[abs] = { tab_id = tab, rel = rel }
  rt.ever_owned[abs] = true
  rt.all_paths[abs] = rel
end

function M.new(deps)
  assert(type(deps) == "table", "review_tabs dependencies required")
  assert(type(deps.pool_for) == "function", "review_tabs pool_for dependency required")
  assert(type(deps.undecided_hunks_for_change) == "function", "review_tabs undecided dependency required")
  assert(type(deps.notify_one_line) == "function", "review_tabs notify dependency required")

  local T = {}
  local close = require("yana.review_tabs_close").new({
    pool_for = deps.pool_for,
    undecided_hunks_for_change = deps.undecided_hunks_for_change,
    notify_one_line = deps.notify_one_line,
  })

  function T.collect_turn_changes(st, change)
    local out = {}
    local seen = {}
    local function same_turn(a, b)
      if a == b then
        return true
      end
      if not a or not b then
        return false
      end
      if a.turn_id ~= nil or b.turn_id ~= nil then
        return a.turn_id == b.turn_id
      end
      return a.turn_gen == b.turn_gen
    end
    for _, entry in ipairs(st.order or {}) do
      local candidate = (entry and entry.change) or entry
      if candidate and candidate.path and (change == nil or same_turn(candidate, change)) and not seen[candidate.path] then
        seen[candidate.path] = true
        out[#out + 1] = candidate
      end
    end
    for _, item in ipairs(st.queue or {}) do
      local candidate = item and item.change
      if candidate and candidate.path and (change == nil or same_turn(candidate, change)) and not seen[candidate.path] then
        seen[candidate.path] = true
        out[#out + 1] = candidate
      end
    end
    if change and change.path and not seen[change.path] then
      out[#out + 1] = change
    end
    table.sort(out, function(a, b)
      return tostring(a.rel or a.path) < tostring(b.rel or b.path)
    end)
    return out
  end

  -- THE placer. Total: always returns `{ kind = ... }` and never raises for a
  -- refusable reason; never moves the cursor (focusing is the caller's job,
  -- review_geometry.focus_buf). The only writer of `rt.owned`.
  function T.place(st, spec)
    local abs = diff.abs_path(spec.abs or spec.path)
    local rt = st and st.review_tabs or nil
    local rel = spec.rel or (rt and rt.all_paths and rt.all_paths[abs]) or vim.fn.fnamemodify(abs, ":.")
    local tabs_on = rt ~= nil and rt.tabs_on == true or (rt == nil and tabs_enabled(nil))
    local shown_tab, shown_win = tab_for_path(abs)
    local spare = spare_window()
    local out = { kind = placement_for(shown_tab ~= nil, tabs_on, rt ~= nil and rt.enabled == true, spare), path = rel }
    if out.kind == "shown" then
      out.tab, out.win = shown_tab, shown_win
      -- A tab this turn once owned keeps its owner when the file is still
      -- shown there; the handle is refreshed, never looked up by name later.
      if rt and rt.ever_owned[abs] then
        adopt(rt, abs, shown_tab, rel)
        out.owned = true
      end
    elseif out.kind == "yana_tab" then
      local prev_tab, prev_win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
      -- Keep the turn's tabs in order: each new one opens after the last one
      -- this turn placed, the first after the operator's tab.
      local after = rt and rt.last_tab and vim.api.nvim_tabpage_is_valid(rt.last_tab) and rt.last_tab or prev_tab
      if pcall(vim.cmd, vim.api.nvim_tabpage_get_number(after) .. "tabnew " .. vim.fn.fnameescape(abs)) then
        out.tab, out.win = vim.api.nvim_get_current_tabpage(), vim.api.nvim_get_current_win()
        if spec.bufnr and vim.api.nvim_win_get_buf(out.win) ~= spec.bufnr then
          pcall(vim.api.nvim_win_set_buf, out.win, spec.bufnr)
        end
        if rt then
          if rt.sidebar_open == nil then
            rt.sidebar_open = origin_sidebar_open(prev_tab)
          end
          out.mirror = rt.sidebar_open and mirror_sidebar(out.tab) or "sidebar_closed"
          adopt(rt, abs, out.tab, rel)
          rt.last_tab = out.tab
          out.owned = true
        else
          out.reason = "no_turn_record"
        end
        pcall(vim.api.nvim_set_current_tabpage, prev_tab)
        pcall(vim.api.nvim_set_current_win, prev_win)
      else
        out.kind, out.reason = "none", "tabnew_failed"
      end
    elseif out.kind == "reuse_win" then
      local bufnr = spec.bufnr or vim.fn.bufadd(abs)
      if pcall(vim.api.nvim_win_set_buf, spare, bufnr) then
        out.win, out.tab = spare, vim.api.nvim_win_get_tabpage(spare)
      else
        out.kind, out.reason = "none", "set_buf_failed"
      end
    end
    log.lifecycle_later("review.tab_placed", {
      path = rel,
      kind = out.kind,
      tab = out.tab,
      owned = out.owned == true,
      mirror = out.mirror,
      reason = out.reason,
    })
    if rt and out.owned then
      record.save(rt)
    end
    return out
  end

  function T.init_for_turn(st, change, opts)
    if not tabs_enabled(opts) then
      st.review_tabs = nil
      return nil
    end
    local key = turn_key(change)
    if (key == nil or key == "") and opts and opts.review_owner then
      key = tostring(opts.review_owner.panel_id or "?") .. ":" .. tostring(opts.review_owner.epoch or "?")
    end
    if key == nil or key == "" then
      key = "unknown"
    end
    local turn_changes = T.collect_turn_changes(st, change)
    local seen = {}
    for _, candidate in ipairs(turn_changes) do
      if type(candidate) == "table" and type(candidate.path) == "string" then
        seen[diff.abs_path(candidate.path)] = true
      end
    end
    if opts and type(opts.review_turn) == "table" and type(opts.review_turn.changes) == "table" then
      for _, candidate in ipairs(opts.review_turn.changes) do
        if type(candidate) == "table" and type(candidate.path) == "string" then
          local abs = diff.abs_path(candidate.path)
          if not seen[abs] then
            turn_changes[#turn_changes + 1] = {
              path = abs,
              rel = candidate.rel or candidate.path or abs,
              turn_id = candidate.turn_id,
              turn_gen = candidate.turn_gen,
            }
            seen[abs] = true
          end
        end
      end
    end
    if opts and type(opts.review_paths) == "table" then
      for _, path in ipairs(opts.review_paths) do
        local abs = diff.abs_path(path)
        if not seen[abs] then
          turn_changes[#turn_changes + 1] = {
            path = abs,
            rel = opts.workspace and abs:sub(#diff.abs_path(opts.workspace) + 2) or abs,
            turn_id = change and change.turn_id or nil,
            turn_gen = change and change.turn_gen or nil,
          }
          seen[abs] = true
        end
      end
      table.sort(turn_changes, function(a, b)
        return tostring(a.rel or a.path) < tostring(b.rel or b.path)
      end)
    end
    if st.review_tabs and st.review_tabs.turn_key ~= key then
      st.review_tabs = nil
    end
    local ever_owned = {}
    local function absorb_ever(source)
      if type(source) ~= "table" then
        return
      end
      for abs, value in pairs(source) do
        if value then
          ever_owned[tostring(abs)] = true
        end
      end
    end
    if st.review_tabs and st.review_tabs.turn_key == key then
      absorb_ever(st.review_tabs.ever_owned)
      absorb_ever(st.review_tabs.owned)
    end
    local state_path = record.state_path(opts)
    local disk = record.read_json(state_path)
    if type(disk) == "table" and tostring(disk.turn_key or "") == tostring(key) then
      absorb_ever(disk.ever_owned)
      absorb_ever(disk.owned)
    else
      disk = nil
    end
    local rt = st.review_tabs or {
      turn_key = key,
      owned = {},
      enabled = false,
      all_paths = {},
      ever_owned = {},
    }
    rt.turn_key = key
    rt.tabs_on = true
    rt.state_path = state_path
    rt.ever_owned = ever_owned
    if rt.sidebar_open == nil then
      if disk and type(disk.sidebar_open) == "boolean" then
        rt.sidebar_open = disk.sidebar_open
      else
        rt.sidebar_open = origin_sidebar_open(vim.api.nvim_get_current_tabpage())
      end
    end
    st.review_tabs = rt
    if #turn_changes < 2 and vim.tbl_isempty(ever_owned) then
      -- Single-file turn: the file is placed when its review focuses it
      -- (T.place via focus_buf), reusing an empty window when one exists.
      rt.enabled = false
      return rt
    end
    rt.enabled = true
    -- Every member of the turn gets its window now, the active file included:
    -- the strip, the sidebar mirror and End review all read `owned`, so the
    -- record must be right before the first review paints.
    for _, candidate in ipairs(turn_changes) do
      local abs = diff.abs_path(candidate.path)
      local rel = candidate.rel or candidate.path
      rt.all_paths[abs] = rel
      T.place(st, { abs = abs, rel = rel })
    end
    for abs, _ in pairs(ever_owned) do
      if rt.owned[abs] == nil then
        local tab = select(1, tab_for_path(abs))
        if tab then
          adopt(rt, abs, tab, rt.all_paths[abs] or abs)
        end
      end
    end
    record.save(rt)
    return rt
  end

  -- Place by path alone (focus_buf knows no pool): the pool is the one whose
  -- turn holds the file -- a review's opts name its workspace and cwd is only
  -- the fallback key -- so the record consulted is the file's own turn.
  function T.place_for_path(path, bufnr)
    local abs = diff.abs_path(path)
    local function holds(pool)
      if pool.active and pool.active.change and pool.active.change.path
        and diff.abs_path(pool.active.change.path) == abs then
        return true
      end
      for _, item in ipairs(pool.order or {}) do
        local c = (item and item.change) or item
        if c and c.path and diff.abs_path(c.path) == abs then
          return true
        end
      end
      for _, item in ipairs(pool.queue or {}) do
        local c = item and item.change
        if c and c.path and diff.abs_path(c.path) == abs then
          return true
        end
      end
      return false
    end
    local st
    for _, pool in pairs(type(deps.pools) == "table" and deps.pools or {}) do
      if holds(pool) then
        st = pool
        break
      end
    end
    return T.place(st or deps.pool_for({}), { abs = abs, bufnr = bufnr })
  end

  T.close_owned_tabs = close.close_owned_tabs
  -- Compat alias: callers and mutation plants still name the old entry.
  T.prompt_close_owned_tabs = close.close_owned_tabs
  T.state_path = record.state_path
  return T
end

M._placement_for = placement_for
return M
