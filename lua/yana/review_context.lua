-- Workspace review state and review-window chrome.
local M = {}

--- The review palette: ONE set of shared highlight groups for every open
--- review, so it dies with the LAST one. Module level, not per-instance,
--- because `review_resources` calls the restore hook below from teardown --
--- outside any `M.new` closure -- and both sides must name the same groups.
local palette = {
  incoming = "YanaHlIncoming",
  deleted = "YanaHlDeleted",
  hint = "YanaHlHint",
}

local function clear_palette_highlights()
  for _, name in pairs(palette) do
    local ok, err = pcall(vim.api.nvim_set_hl, 0, name, {})
    if not ok then
      require("yana.log").write(
        "WARN",
        "yana.inline_diff: could not clear review palette highlight " .. tostring(name) .. ": " .. tostring(err)
      )
    end
  end
end

--- OWNER-SAFE window restore: the `restore_windows` hook `review_resources`
--- calls at close (F-TRL06-02). It restores exactly the windows the owner
--- table proved this state still holds -- `request.windows` is a list of
--- `{win, winhl}` -- and clears the shared palette only when
--- `request.clear_palette` says no other live review still needs it.
---
--- The difference from `restore_review_winhl` below is the whole point: that
--- one re-derives "my windows" from `state.winhl_restore` PLUS every window
--- currently showing `state.bufnr`, and then clears the palette
--- unconditionally -- so a superseded review closing on a shared buffer strips
--- the live one's highlighting. Ownership is not knowable here; it travels in
--- the request, computed by the owner table.
function M.restore_windows(request)
  for _, entry in ipairs((request or {}).windows or {}) do
    local win = entry.win or entry[1]
    local previous = entry.winhl or entry[2] or ""
    if type(win) == "number" and vim.api.nvim_win_is_valid(win) then
      vim.wo[win].winhl = previous
    end
  end
  if request and request.clear_palette then
    clear_palette_highlights()
  end
end

--- The live, unparked attachment shown in `bufnr`; with `bufnr` nil, prefer
--- the current window, then the previous window in this tab, then lowest rel.
--- Reads only `pool.open`, so doors outside the facade call it directly.
function M.state_for_buf(pool, bufnr, tab)
  local found, found_rel = nil, nil
  if bufnr == nil then
    tab = tab or vim.api.nvim_get_current_tabpage()
    if vim.api.nvim_tabpage_is_valid(tab) then
      local current_win = vim.api.nvim_tabpage_get_win(tab)
      local current = M.state_for_buf(pool, vim.api.nvim_win_get_buf(current_win))
      if current then return current end
      local tabnr = vim.api.nvim_tabpage_get_number(tab)
      local previous = vim.fn.win_getid(vim.fn.tabpagewinnr(tabnr, "#"), tabnr)
      if previous > 0 and vim.api.nvim_win_is_valid(previous)
        and vim.api.nvim_win_get_tabpage(previous) == tab then
        local prior = M.state_for_buf(pool, vim.api.nvim_win_get_buf(previous))
        if prior then return prior end
      end
    end
  end
  for change, state in pairs(pool and pool.open or {}) do
    if not state.closed and change._parked_state ~= state then
      local rel = tostring(change.rel or change.path)
      if bufnr ~= nil and state.bufnr == bufnr then
        return state
      elseif bufnr == nil and (found_rel == nil or rel < found_rel) then
        found, found_rel = state, rel
      end
    end
  end
  return found
end

-- The indexed attachment is still this exact live, unparked review. Resource
-- ownership can outlive parking, so resource currency alone is insufficient.
function M.is_live_attachment(pool, state)
  return state ~= nil and pool ~= nil and pool.open[state.change] == state
    and not state.closed and state.change._parked_state ~= state
end

function M.attach(pool, state)
  assert(pool and state and state.change, "review attachment needs a pool and change")
  pool.open[state.change] = state
end

function M.detach(pool, state)
  if pool and state and pool.open[state.change] == state then
    pool.open[state.change] = nil
    return true
  end
  return false
end

function M.new(deps)
  local facade = deps.facade
  local diff = deps.diff
  local config = deps.config
  local pools = {}

  local function workspace_key(opts)
    if opts and opts.workspace and opts.workspace ~= "" then
      return diff.abs_path(opts.workspace)
    end
    return diff.abs_path(vim.fn.getcwd())
  end

  local function stamp_review_workspace(change, opts)
    if change and not change.review_workspace then
      change.review_workspace = workspace_key(opts)
    end
  end

  local function pool_for(opts)
    local key = workspace_key(opts or {})
    local state = pools[key]
    if not state then
      state = { queue = {}, open = {}, batched = {}, order = {}, order_seq = 0 }
      pools[key] = state
    end
    return state, key
  end

  local function pool_for_state(state)
    if state and state.opts then
      return pool_for(state.opts)
    end
    return pool_for({})
  end

  --- ONE lookup for a rel's live review state, active or parked. Owner: the pool's own
  --- writer (this module), never Turn -- Turn owns lifecycle only and never drives UI.
  local function state_for_rel(pool, rel)
    if not pool or rel == nil then
      return nil
    end
    for change, state in pairs(pool.open or {}) do
      if (change.rel or change.path) == rel and not state.closed then
        return state
      end
    end
    for _, item in ipairs(pool.queue or {}) do
      local c = item.change
      if c and (c.rel or c.path) == rel and type(c._parked_state) == "table" then
        return c._parked_state
      end
    end
    return nil
  end

  local state_for_buf = M.state_for_buf

  local function owners_match(a, b)
    if not a or not b then
      return false
    end
    return a.panel_id == b.panel_id and a.epoch == b.epoch
  end

  local function queue_item_owner(item)
    if not item then
      return nil
    end
    return item.owner or (item.opts and item.opts.review_owner)
  end

  local function freeze_review_owner(opts)
    if not opts or not opts.review_owner then
      return nil
    end
    return { panel_id = opts.review_owner.panel_id, epoch = opts.review_owner.epoch }
  end

  local function find_active_for_change(change)
    for _, state in pairs(pools) do
      if state.open[change] then
        return state
      end
    end
    return nil
  end

  function facade.mark_batched(path, opts)
    if path then
      local state = pool_for(opts or {})
      state.batched[diff.abs_path(path)] = true
    end
  end

  function facade.unmark_batched(path, opts)
    if path then
      local state = pool_for(opts or {})
      state.batched[diff.abs_path(path)] = nil
    end
  end

  local ext_hl = {
    incoming = "YanaDiffIncoming",
    deleted = "YanaDiffDeleted",
    hint = "YanaInlineHint",
  }
  local fault = {}
  facade._fault = fault

  function facade._fault_keeps_paint(blocks, block)
    local planted = fault.sticky_paint
    if not planted then
      return false
    end
    if planted == true then
      return true
    end
    for index, candidate in ipairs(blocks or {}) do
      if candidate == block then
        return planted.block == index
      end
    end
    return false
  end

  local function palette_defs()
    local highlights = config.options.diff_highlights
    return {
      [palette.incoming] = highlights.incoming,
      [palette.deleted] = highlights.deleted,
      [palette.hint] = highlights.hint,
    }
  end

  local function apply_palette_highlights()
    for name, spec in pairs(palette_defs()) do
      if spec.link and not spec.bg and not spec.fg then
        vim.api.nvim_set_hl(0, name, { link = spec.link, default = true, force = true })
      else
        local highlight = vim.tbl_extend("force", spec, { force = true })
        highlight.link = nil
        if name == palette.deleted then
          highlight.strikethrough = false
        end
        vim.api.nvim_set_hl(0, name, highlight)
      end
    end
  end

  local function wins_for_buf(bufnr)
    local wins = {}
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        table.insert(wins, win)
      end
    end
    return wins
  end

  local function strip_yana_winhl(winhl)
    if winhl == nil or winhl == "" then
      return ""
    end
    local kept = {}
    for part in winhl:gmatch("[^,]+") do
      local key = part:match("^([^:]+)")
      if key and not key:match("^Yana") then
        table.insert(kept, part)
      end
    end
    return table.concat(kept, ",")
  end

  local function review_winhl_spec()
    return table.concat({
      ext_hl.incoming .. ":" .. palette.incoming,
      ext_hl.deleted .. ":" .. palette.deleted,
      ext_hl.hint .. ":" .. palette.hint,
    }, ",")
  end

  local function apply_review_winhl(bufnr, state)
    apply_palette_highlights()
    state.winhl_restore = state.winhl_restore or {}
    local add = review_winhl_spec()
    for _, win in ipairs(wins_for_buf(bufnr)) do
      if vim.api.nvim_win_is_valid(win) and state.winhl_restore[win] == nil then
        local base = strip_yana_winhl(vim.wo[win].winhl or "")
        state.winhl_restore[win] = base
        vim.wo[win].winhl = base ~= "" and (base .. "," .. add) or add
      end
    end
  end

  local function ensure_review_render_chrome(bufnr)
    if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) or fault.skip_render_chrome then
      return
    end
    apply_palette_highlights()
    local add = review_winhl_spec()
    for _, win in ipairs(wins_for_buf(bufnr)) do
      if vim.api.nvim_win_is_valid(win) then
        local base = strip_yana_winhl(vim.wo[win].winhl or "")
        vim.wo[win].winhl = base ~= "" and (base .. "," .. add) or add
      end
    end
  end

  local function restore_review_winhl(state)
    local restored = {}
    for win, previous in pairs(state.winhl_restore or {}) do
      if vim.api.nvim_win_is_valid(win) then
        restored[win] = true
        vim.wo[win].winhl = previous
      end
    end
    local bufnr = state.bufnr
    if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      for _, win in ipairs(wins_for_buf(bufnr)) do
        if not restored[win] and vim.api.nvim_win_is_valid(win) then
          vim.wo[win].winhl = strip_yana_winhl(vim.wo[win].winhl or "")
        end
      end
    end
    clear_palette_highlights()
  end

  return {
    max_render_warns = 3,
    pools = pools,
    pool_for = pool_for,
    pool_for_state = pool_for_state,
    state_for_rel = state_for_rel,
    state_for_buf = state_for_buf,
    owners_match = owners_match,
    queue_item_owner = queue_item_owner,
    freeze_review_owner = freeze_review_owner,
    find_active_for_change = find_active_for_change,
    stamp_review_workspace = stamp_review_workspace,
    palette = palette,
    ext_hl = ext_hl,
    fault = fault,
    apply_palette_highlights = apply_palette_highlights,
    wins_for_buf = wins_for_buf,
    apply_review_winhl = apply_review_winhl,
    ensure_review_render_chrome = ensure_review_render_chrome,
    restore_review_winhl = restore_review_winhl,
    restore_windows = M.restore_windows,
  }
end

return M
