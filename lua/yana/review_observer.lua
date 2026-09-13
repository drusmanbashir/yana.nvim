-- Review decision logging and non-intervening render checks.
local ledger = require("yana.ledger")
local log = require("yana.log")
local render_check = require("yana.render_check")

local M = {}

function M.new(deps)
  local function change_ledger(change, opts)
    local panel_id = (change and change.panel_id)
      or (opts and opts.review_owner and opts.review_owner.panel_id)
      or 0
    return ledger.ensure(panel_id, (change and change.turn_gen) or 0)
  end

  -- The observer is logging only. Its whole capture, including recording, is
  -- protected so an observer defect cannot change the render it measures.
  local function render_invariant(desc)
    local ok, result = pcall(function()
      local res = render_check.run({
        site = desc.site,
        bufnr = desc.bufnr,
        blocks = desc.blocks,
        model = desc.model,
        model_source = desc.model_source,
        ns = deps.ns,
        hint_ns = deps.hint_ns,
        ext_hl = deps.ext_hl,
        palette = deps.palette,
        change_id = desc.change and desc.change.id or nil,
        rel = desc.change and (desc.change.rel or desc.change.path) or nil,
      })
      ledger.record_render_check(change_ledger(desc.change, desc.opts), res)
      local carrier = desc.change
      if not res.ok and carrier then
        local warns = carrier._render_check_warns or 0
        if carrier._render_check_sig ~= res.signature and warns < deps.max_render_warns then
          carrier._render_check_sig = res.signature
          carrier._render_check_warns = warns + 1
          log.write("WARN", "yana.inline_diff: " .. render_check.summarize(res))
        end
      end
      return res
    end)
    if not ok or type(result) ~= "table" then
      return nil
    end
    return result
  end

  -- These four per-hunk actions always carry a `model_index` -- or, when it
  -- is absent, a `model_index_reason` beside it. `accept_file`, `accept_turn`
  -- and `review_refused` decide no single hunk and are left alone.
  local HUNK_ACTIONS = {
    accept_hunk = true,
    reject_hunk = true,
    undo_decision = true,
    redo_decision = true,
  }

  -- Record one user decision in memory and in the durable lifecycle log.
  local function record_decision(state, action, fields)
    local change = state and state.change
    local decision = fields or {}
    decision.action = action
    decision.actor = "user"
    decision.undo_seq = deps.buf_undo_seq(state and state.bufnr)
    decision.change_id = change and change.id or nil
    decision.rel = change and (change.rel or change.path) or nil
    ledger.record_decision(change_ledger(change, state and state.opts), decision)
    -- `model_join` is the block's own record of why stamp_model_index (or a
    -- later split/merge) left it with no model_index; absent is never silent.
    local model_index_reason = nil
    if decision.model_index == nil and HUNK_ACTIONS[action] then
      model_index_reason = decision.model_join or "absent_at_open"
    end
    log.lifecycle_later("review.decision", {
      turn_id = change and (change.turn_id or change.turn_gen),
      generation = change and change.turn_gen,
      action = action,
      actor = decision.actor,
      path = decision.rel,
      change_id = decision.change_id,
      hunk = decision.hunk,
      model_index = decision.model_index,
      model_index_reason = model_index_reason,
      hunks_remaining = decision.hunks_remaining,
      reason = decision.reason,
    })
    return decision
  end

  -- The rec-plant `sticky_paint = {block = k}` aim, as a row span the painter can step
  -- around.
  local function sticky_keep(ledger)
    local planted = deps.fault and deps.fault.sticky_paint
    if type(planted) ~= "table" or not planted.block then
      return nil
    end
    local member = ledger:members()[planted.block]
    if not (member and member.new_start_line and member.new_end_line) then
      return nil
    end
    -- One row of slack past the hunk's last line: the incoming band's extmark
    -- ends (end_col 0) on the row AFTER its last, and a clear whose range
    -- starts there takes the whole mark with it.
    local first = math.max(member.new_start_line - 1, 0)
    return { first, math.max(member.new_end_line, first) }
  end

  local function render_blocks(bufnr, ledger, desc)
    deps.ensure_review_render_chrome(bufnr)
    deps.render(bufnr, ledger:paint_membership(), sticky_keep(ledger))
    desc = desc or {}
    desc.bufnr = bufnr
    desc.blocks = ledger:pending()
    desc.ledger = ledger
    render_invariant(desc)
  end

  return {
    change_ledger = change_ledger,
    render_invariant = render_invariant,
    record_decision = record_decision,
    render_blocks = render_blocks,
  }
end

return M
