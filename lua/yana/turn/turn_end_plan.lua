-- One confirmed End's private values and exact execution destinations.
-- The canonical values never leave this module; public inspection is a copy.
local snapshot = require("yana.turn.turn_settle_snapshot")
local diff = require("yana.diff")

local M = {}
local plans = setmetatable({}, { __mode = "k" })
local change_fields = {
  "path", "rel", "root", "kind", "status", "before", "after",
  "base_hash", "base_hash_captured_ts", "base_state", "base_mode",
  "base_link_target", "after_mode", "turn_id", "turn_gen",
  "review_workspace", "buffer_capture", "_yanad_claim_held",
}

local function route_change(change)
  local out = {}
  for _, name in ipairs(change_fields) do
    if change[name] ~= nil then out[name] = vim.deepcopy(change[name]) end
  end
  return out
end

local function route_context(opts, change)
  local turn = type(opts.review_turn) == "table" and opts.review_turn or {}
  return {
    review_turn = {
      turn_id = turn.turn_id,
      workspace = turn.workspace,
      stream = turn.stream,
      yanad_session_id = turn.yanad_session_id,
      session_id = turn.session_id,
    },
    turn_id = change.turn_id or change.turn_gen,
    yanad_session_id = opts.yanad_session_id,
    session_id = opts.session_id,
    workspace = opts.workspace,
  }
end

function M.prepare(turn, cause)
  if plans[turn] ~= nil then return false, "End plan already exists" end
  local candidate = { identity = {}, items = {}, bindings = {} }
  for index, f in ipairs(turn.files) do
    local change = type(f.change) == "table" and f.change or {}
    local opts = type(f.review_opts) == "table" and f.review_opts or {}
    local bufnr = f.bufnr
    local loaded = snapshot.valid_buffer(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
    local buffer_bytes
    if loaded then
      local err
      buffer_bytes, err = diff.buffer_bytes_snapshot(bufnr)
      -- A binary buffer had no canonical byte snapshot in the old End path;
      -- preserve its modified-bit obligation. A text snapshot failure cannot
      -- safely decide whether a saved proposal needs terminal reconciliation.
      if buffer_bytes == nil and not vim.bo[bufnr].binary then
        error(err or "End buffer snapshot failed")
      end
    end
    local item = {
      index = index,
      identity = f.change_id or f.path,
      path = f.path,
      cause = cause,
      owner = vim.deepcopy(f.review_owner or opts.review_owner),
      input = vim.deepcopy(snapshot.snapshot_of(f, "exit")),
      buffer_modified = loaded and vim.bo[bufnr].modified == true or false,
      buffer_bytes = buffer_bytes,
      route = {
        change = route_change(change),
        context = route_context(opts, change),
        shadow_apply = opts.shadow_apply == true,
      },
    }
    candidate.items[index] = item
    candidate.bindings[index] = {
      file = f,
      change = change,
      accept = opts.on_shadow_accept,
      close = opts.on_close,
      close_opts = opts,
      review_state = f.review_state,
      parked_state = change._parked_state,
      parked_review = change._parked_review,
      bufnr = f.bufnr,
    }
  end
  return candidate
end

function M.publish(turn, candidate)
  assert(plans[turn] == nil, "End plan already published")
  plans[turn] = candidate
  turn.end_plan = vim.deepcopy(candidate.items)
end

function M.count(turn)
  local plan = assert(plans[turn], "End plan missing")
  return #plan.items
end

-- Presentation at cleanup uses the confirmed verdict, never a File re-read
-- after an asynchronous close. Permission approval alone is not acceptance.
function M.accepted(item)
  local input = assert(item.input, "End plan input missing")
  if input.operation_verdict == "accepted" or input.carried == true then return true end
  for _, hunk in ipairs(input.hunks or {}) do
    if hunk.verdict == "accepted" then return true end
  end
  return false
end

function M.item(turn, index)
  local plan = assert(plans[turn], "End plan missing")
  local item = plan.items[index]
  if item == nil then return nil end
  local binding = assert(plan.bindings[index], "End execution binding missing")
  assert(rawequal(turn.files[index], binding.file),
    "End membership changed after confirmation")
  return vim.deepcopy(item), binding
end

function M.bindings(turn)
  local plan = assert(plans[turn], "End plan missing")
  local out = {}
  for index = 1, #plan.items do
    local item, binding = M.item(turn, index)
    out[index] = { item = item, binding = binding }
  end
  assert(#turn.files == #out, "End gained an unplanned member")
  return out
end

return M
