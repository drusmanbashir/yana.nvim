-- End review's silent consequence: close the tabs Yana owns for the turn.
-- Silent means the operator's tab and cursor never move; each owned tab is
-- closed by number from where the operator stands (`:{N}tabclose`).
-- "End review?" is the one dialog; tab close is its silent consequence.
local diff = require("yana.diff")
local log = require("yana.log")
local record = require("yana.review_tabs_record")

local M = {}

function M.new(deps)
  local pool_for = deps.pool_for
  local undecided_hunks_for_change = deps.undecided_hunks_for_change
  local notify_one_line = deps.notify_one_line
  local C = {}

  local function pending_paths(st, owned)
    local pending = {}
    local function mark_if_pending(change)
      if not change or not change.path then
        return
      end
      local abs = diff.abs_path(change.path)
      local undecided = undecided_hunks_for_change(change, st)
      if owned[abs] and type(undecided) == "number" and undecided > 0 then
        pending[abs] = true
      end
    end
    for _, item in ipairs(st.queue or {}) do
      mark_if_pending(item and item.change)
    end
    for _, item in ipairs(st.order or {}) do
      mark_if_pending(item and item.change)
    end
    if st.active then
      mark_if_pending(st.active.change)
    end
    return pending
  end

  -- Which tabs does this turn own? The live record wins; the disk record is
  -- the fallback, and the answer says which (`live_fallback`).
  local function load_owned_record(st, opts)
    local path = record.state_path(opts)
    local function valid_owned(source)
      local owned = {}
      for abs, entry in pairs(source or {}) do
        if type(abs) == "string"
          and type(entry) == "table"
          and type(entry.tab_id) == "number"
          and vim.api.nvim_tabpage_is_valid(entry.tab_id)
        then
          owned[abs] = { tab_id = entry.tab_id, rel = entry.rel or abs }
        end
      end
      return owned
    end
    local function live_record()
      local live = st and st.review_tabs
      return {
        path = path,
        turn_key = tostring((live and live.turn_key) or "unknown"),
        owned = valid_owned(live and live.owned),
        live_fallback = true,
      }
    end
    if not path then
      return live_record()
    end
    local disk = record.read_json(path)
    if type(disk) ~= "table" or disk.turn_key == nil or type(disk.owned) ~= "table" then
      return live_record()
    end
    return { path = path, turn_key = tostring(disk.turn_key), owned = valid_owned(disk.owned) }
  end

  local function owned_snapshot(owned)
    local snapshot = {}
    for abs, entry in pairs(owned or {}) do
      snapshot[abs] = { tab_id = entry.tab_id, rel = entry.rel or abs }
    end
    return snapshot
  end

  local function tab_shows_path(tab, abs)
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local buf = vim.api.nvim_win_get_buf(win)
      if vim.api.nvim_buf_is_valid(buf) then
        local name = vim.api.nvim_buf_get_name(buf)
        if name ~= "" and diff.abs_path(name) == abs then
          return true
        end
      end
    end
    return false
  end

  local function keys_of(set)
    local out = {}
    for k, _ in pairs(set) do
      out[#out + 1] = k
    end
    table.sort(out)
    return out
  end

  function C.close_owned_tabs(opts)
    opts = opts or {}
    local st = pool_for(opts)
    local owned_record = load_owned_record(st, opts)
    if vim.tbl_isempty(owned_record.owned) then
      if owned_record.path then
        pcall(vim.fn.delete, owned_record.path)
      end
      st.review_tabs = nil
      log.lifecycle_later("review.tabs_closed", {
        turn_key = owned_record.turn_key,
        closed = {},
        refused = {},
        live_record = owned_record.live_fallback == true,
        reason = "none_owned",
        workspace = opts.workspace,
      })
      local result = { ok = true, reason = "none_owned", closed = {}, refused = {} }
      if type(opts.after_close) == "function" then
        pcall(opts.after_close, result)
      end
      return result
    end
    local captured_turn_key = owned_record.turn_key
    local captured_owned = owned_snapshot(owned_record.owned)
    local pending = pending_paths(st, captured_owned)
    local closed, refused = {}, {}
    for abs, entry in pairs(captured_owned) do
      local rel = entry.rel or abs
      local tab = entry.tab_id
      if tab and vim.api.nvim_tabpage_is_valid(tab) then
        -- The path check remains the fallback for disk-only records, which cannot prove
        -- live handle ownership.
        local live = st and st.review_tabs
        local live_entry = live and live.owned and live.owned[abs]
        local still_live_owned_handle = type(live_entry) == "table" and live_entry.tab_id == tab
        if not still_live_owned_handle and not tab_shows_path(tab, abs) then
          -- Drop silently: neither live ownership nor the recorded path survives.
        elseif pending[abs] then
          refused[rel] = true
          notify_one_line("yana: keeping tab open for pending hunks in " .. rel, vim.log.levels.WARN)
        else
          -- `:tabclose` refuses the last tabpage: hand Neovim a blank one first.
          if #vim.api.nvim_list_tabpages() == 1 then
            pcall(vim.cmd, "tabnew")
          end
          local number = vim.api.nvim_tabpage_get_number(tab)
          if pcall(vim.cmd, tostring(number) .. "tabclose") then
            closed[rel] = true
          else
            notify_one_line("yana: failed to close tab for " .. rel .. "; leaving open", vim.log.levels.WARN)
          end
        end
      end
    end
    if owned_record.path then
      pcall(vim.fn.delete, owned_record.path)
    end
    if st.review_tabs and tostring(st.review_tabs.turn_key or "") == tostring(captured_turn_key) then
      st.review_tabs = nil
    end
    log.lifecycle_later("review.tabs_closed", {
      turn_key = captured_turn_key,
      closed = keys_of(closed),
      refused = keys_of(refused),
      live_record = owned_record.live_fallback == true,
    })
    local result = { ok = true, reason = "closed", closed = closed, refused = refused }
    if type(opts.after_close) == "function" then
      pcall(opts.after_close, result)
    end
    return result
  end

  return C
end

return M
