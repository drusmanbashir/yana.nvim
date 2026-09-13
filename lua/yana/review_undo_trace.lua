-- Undo-boundary diagnostics. Observes only buffers that opened a Yana review
-- and only state needed to explain undo/redo regressions (logging module).
local log = require("yana.log")

local M = {}
local watched = {}
local namespace = vim.api.nvim_create_namespace("YanaUndoTrace")
local ENTRY_LIMIT = 256

local function lifecycle_fields(subject)
  local change = subject and subject.change or {}
  return {
    bufnr = subject and subject.bufnr,
    path = change and (change.rel or change.path),
    change_id = change and change.id,
    turn_id = change and (change.turn_id or change.turn_gen),
  }
end

local function map_owner(lhs, mode)
  local info = vim.fn.maparg(lhs, mode, false, true)
  if type(info) ~= "table" or next(info) == nil then
    return { owner = "native", source = "native" }
  end
  local callback = type(info.callback) == "function" and tostring(info.callback) or nil
  return {
    owner = info.desc or (info.rhs ~= "" and info.rhs) or callback or "mapping",
    source = info.buffer == 1 and "buffer" or "global",
    desc = info.desc ~= "" and info.desc or nil,
    rhs = info.rhs ~= "" and info.rhs or nil,
    callback = callback,
    sid = info.sid,
    lnum = info.lnum,
  }
end

local function copy_entries(entries, budget)
  local out = {}
  for _, entry in ipairs(type(entries) == "table" and entries or {}) do
    if budget.left <= 0 then
      budget.truncated = true
      break
    end
    budget.left = budget.left - 1
    local row = {
      seq = entry.seq,
      time = entry.time,
      save = entry.save,
      newhead = entry.newhead == 1 or entry.newhead == true,
      curhead = entry.curhead == 1 or entry.curhead == true,
    }
    if type(entry.alt) == "table" then
      row.alt = copy_entries(entry.alt, budget)
    end
    out[#out + 1] = row
  end
  return out
end

function M.capture(point, subject, extra)
  if not log.undo_trace_enabled() then
    return true
  end
  local bufnr = subject and subject.bufnr
  if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end
  local tree, keymaps
  local function snapshot()
    tree = vim.fn.undotree()
    keymaps = {
      normal = { u = map_owner("u", "n"), redo = map_owner("<C-r>", "n") },
      visual = { u = map_owner("u", "x"), redo = map_owner("<C-r>", "x") },
    }
  end
  local ok
  if vim.api.nvim_get_current_buf() == bufnr then
    ok = pcall(snapshot)
  else
    ok = pcall(vim.api.nvim_buf_call, bufnr, snapshot)
  end
  if not ok or type(tree) ~= "table" then
    return false
  end
  local budget = { left = ENTRY_LIMIT, truncated = false }
  local fields = vim.tbl_extend("force", lifecycle_fields(subject), extra or {}, {
    point = point,
    mode = (vim.api.nvim_get_mode() or {}).mode,
    seq_cur = tree.seq_cur,
    seq_last = tree.seq_last,
    time_cur = tree.time_cur,
    time_last = tree.time_last,
    save_cur = tree.save_cur,
    save_last = tree.save_last,
    undo_entries = copy_entries(tree.entries, budget),
    undo_entries_truncated = budget.truncated,
    keymaps = keymaps,
  })
  return log.lifecycle_later("review.undo_state", fields)
end

function M.watch(state)
  local bufnr = state and state.bufnr
  if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end
  watched[bufnr] = {
    bufnr = bufnr,
    change = state.change,
    closed = false,
  }
  M.capture("review_open", state)
  return true
end

function M.close(state)
  local bufnr = state and state.bufnr
  local subject = bufnr and watched[bufnr]
  if subject then
    subject.closed = true
  end
  return M.capture("review_close", state)
end

local function key_name(key, typed)
  local raw = typed and typed ~= "" and typed or key
  if raw == "u" then
    return "u"
  end
  if raw == string.char(18) or raw == vim.keycode("<C-r>") then
    return "<C-r>"
  end
  return nil
end

vim.on_key(function(key, typed)
  local subject = watched[vim.api.nvim_get_current_buf()]
  -- Open-review u/<C-r> are recorded by their buffer-local callbacks. Observe
  -- raw keys only after cleanup has returned both keys to Neovim; entering a
  -- buffer call from on_key before dispatch can itself perturb that dispatch.
  if not (subject and subject.closed) then
    return
  end
  local name = key_name(key, typed)
  if name then
    M.capture(name == "u" and "key_u" or "key_redo", subject, { key = name })
  end
end, namespace)

vim.api.nvim_create_autocmd("BufWipeout", {
  callback = function(args)
    watched[args.buf] = nil
  end,
})

return M
