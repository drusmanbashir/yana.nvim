-- End review's silent consequence: close the tabs Yana owns for the turn.
-- Silent means the operator's tab and cursor never move; each owned tab is
-- closed by number from where the operator stands (`:{N}tabclose`).
-- "End review?" is the one dialog; tab close is its silent consequence.
local diff = require("yana.diff")
local log = require("yana.log")

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
    for change, state in pairs(st.open or {}) do
      if not state.closed then mark_if_pending(change) end
    end
    return pending
  end

  -- The tabs this turn owns that are still open.
  local function open_owned(st)
    local owned = {}
    local live = st and st.review_tabs
    for abs, entry in pairs(live and live.owned or {}) do
      if vim.api.nvim_tabpage_is_valid(entry.tab_id) then
        owned[abs] = { tab_id = entry.tab_id, rel = entry.rel or abs }
      end
    end
    return owned
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
    local captured_owned = open_owned(st)
    local captured_turn_key = tostring((st.review_tabs and st.review_tabs.turn_key) or "unknown")
    if vim.tbl_isempty(captured_owned) then
      st.review_tabs = nil
      log.lifecycle_later("review.tabs_closed", {
        turn_key = captured_turn_key,
        closed = {},
        refused = {},
        reason = "none_owned",
        workspace = opts.workspace,
      })
      local result = { ok = true, reason = "none_owned", closed = {}, refused = {} }
      if type(opts.after_close) == "function" then
        pcall(opts.after_close, result)
      end
      return result
    end
    local pending = pending_paths(st, captured_owned)
    local closed, refused = {}, {}
    for abs, entry in pairs(captured_owned) do
      local rel = entry.rel or abs
      local tab = entry.tab_id
      if tab and vim.api.nvim_tabpage_is_valid(tab) then
        if (opts.keep_paths or {})[abs] then
          refused[rel] = true
          notify_one_line("yana: keeping unsaved file open for manual write: " .. rel, vim.log.levels.WARN)
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
    if st.review_tabs and tostring(st.review_tabs.turn_key or "") == tostring(captured_turn_key) then
      st.review_tabs = nil
    end
    log.lifecycle_later("review.tabs_closed", {
      turn_key = captured_turn_key,
      closed = keys_of(closed),
      refused = keys_of(refused),
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
