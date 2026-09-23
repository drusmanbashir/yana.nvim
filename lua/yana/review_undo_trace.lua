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

local function lines_info(lines)
  return { count = #(lines or {}), sha256 = vim.fn.sha256(vim.json.encode(lines or {})) }
end

local function block_info(block)
  return { id = block.lineage_id, parent = block.split_parent_lineage_id,
    model_index = block.model_index, verdict = block.verdict,
    first = block.new_start_line, last = block.new_end_line,
    owners = block.owned_rows, old = lines_info(block.old_lines), new = lines_info(block.new_lines) }
end

local function frames_info(frames)
  local out = {}
  for _, value in pairs(frames or {}) do
    local row = block_info(value.fields or {})
    row.id, row.first, row.last = value.lineage_id, value.start_line, value.end_line
    row.geometry_only = value.geometry_only == true
    out[#out + 1] = row
  end
  table.sort(out, function(a, b) return tostring(a.id) < tostring(b.id) end)
  return out
end

local function yana_state(subject)
  local ledger = subject.hunk_ledger
  if not ledger then return nil end
  local out = { members = {}, records = {}, captures = {} }
  for _, block in ipairs(ledger:members()) do out.members[#out.members + 1] = block_info(block) end
  local history = ledger.buffer_history
  out.observed_seq = history.current_seq
  for _, seq in ipairs(history.record_seqs or {}) do
    local rec = history.records[seq]
    if rec then
      local members = {}
      for block in pairs(rec.before_members or {}) do members[#members + 1] = block.lineage_id end
      table.sort(members)
      out.records[#out.records + 1] = { seq = seq, before_seq = rec.before_seq,
        before = frames_info(rec.before), after = frames_info(rec.after), before_members = members }
    end
  end
  for marker, group in pairs(history.before_groups or {}) do
    out.captures[#out.captures + 1] = { marker = marker, before_seq = group.before_seq,
      before = frames_info(group.before) }
  end
  local change = subject.change or {}
  local workspace = change.review_workspace or (subject.opts or {}).workspace or vim.fn.getcwd()
  local register = require("yana.turn.turn_register").for_workspace(workspace)
  out.register = { cursor = register.cursor, actions = {} }
  for i, action in ipairs(register.actions) do
    local structural = {}
    for _, entry in ipairs(action.hunk_merges or {}) do
      local children = {}
      for _, child in ipairs(entry.children or {}) do children[#children + 1] = child.lineage_id end
      structural[#structural + 1] = { kind = entry.kind,
        parent = entry.parent and entry.parent.lineage_id, children = children }
    end
    out.register.actions[i] = { kind = action.kind, rel = action.rel, turn_id = action.turn_id,
      undo_seq = action.undo_seq, count = action.count, halted = action.halted, structural = structural }
  end
  return out
end

local function capture(point, subject, extra)
  if not log.undo_trace_enabled() then
    return true
  end
  local bufnr = subject and subject.bufnr
  if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)) then
    return false
  end
  local tree, keymaps
  local function snapshot()
    tree = vim.fn.undotree(bufnr)
    keymaps = {
      normal = { u = map_owner("u", "n"), redo = map_owner("<C-r>", "n") },
      insert = { enter = map_owner("<CR>", "i"), leave = map_owner("jk", "i") },
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
    tick = vim.api.nvim_buf_get_changedtick(bufnr),
    synced = tree.synced,
    yana = yana_state(subject),
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

-- Failure is evidence loss, never permission to interrupt the edit being observed.
function M.capture(point, subject, extra)
  local ok, result = pcall(capture, point, subject, extra)
  if not ok or result == false then
    log.write("WARN", "review.undo_trace capture_failed point=" .. tostring(point)
      .. " reason=" .. tostring(result))
    return false
  end
  return result
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
  local history = state.hunk_ledger and state.hunk_ledger.buffer_history
  if history then
    history.trace = function(point, extra) M.capture(point, state, extra) end
  end
  M.capture("review_open", state)
  return true
end

function M.close(state)
  local bufnr = state and state.bufnr
  local subject = bufnr and watched[bufnr]
  if subject then
    subject.closed = true
  end
  local result = M.capture("review_close", state)
  if state.hunk_ledger then state.hunk_ledger.buffer_history.trace = nil end
  return result
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
