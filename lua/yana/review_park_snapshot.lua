-- Decision-stack snapshot and in-place resume for a review that is parking, and
-- one file's review endpoint capture/install (bottom of this file).
--
-- Park-time teardown is NOT here any more. The removed park teardown stripped
-- this review's buffer-local keymaps by `state.keys` on a bare buffer number, which is
-- the same identity mistake `review_lifecycle.cleanup` made: the lhs it deleted
-- belongs to whichever review currently holds the buffer, not necessarily to the
-- state doing the parking. `review_resources.park` is the one implementation now,
-- reached through `review_lifecycle.park_review`, and it releases keys only while
-- the parking state is still the recorded owner.
local hunk_ledger = require("yana.hunk_ledger")

-- Hand-test tracing (tools/handtest). Inert unless YANA_HANDTEST_TRACE is set.
local function _ht_trace(msg)
  local p = os.getenv("YANA_HANDTEST_TRACE")
  if not p then return end
  local f = io.open(p, "a")
  if f then f:write(msg .. "\n"); f:close() end
end

local M = {}

-- One decision anchor's rows, 1-based inclusive, or nil once the mark is gone.
local function anchor_rows(bufnr, id)
  if not id then
    return nil
  end
  local anchor_ns = vim.api.nvim_create_namespace("YanaInlineDiffDecisionAnchor")
  local ok, ext = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, anchor_ns, id, { details = true })
  if not ok or type(ext) ~= "table" or ext[1] == nil then
    return nil
  end
  local meta = ext[3] or {}
  return { ext[1] + 1, (meta.end_row or ext[1]) + 1 }
end

function M.capture(state, bufnr)
  local sealed = vim.deepcopy(state.sealed_decisions or {})
  for _, d in ipairs(state.decisions or {}) do
    local copy = vim.deepcopy(d)
    -- Cleanup clears the anchor namespace; preserve rows, not a dead id.
    copy.anchor_rows = anchor_rows(bufnr, d.anchor) or copy.anchor_rows
    copy.anchor = nil
    sealed[#sealed + 1] = copy
  end

  local undone = {}
  for _, d in ipairs(state.undone_decisions or {}) do
    local copy = vim.deepcopy(d)
    -- Scrub this fallback copy; resume normally rebinds the decision to that member.
    copy.block = hunk_ledger.scrub_paint(copy.block)
    copy.anchor = nil
    undone[#undone + 1] = copy
  end
  return sealed, undone
end

--- `pool_for`/`announce_state` are handed in (review_queue.lua's own) rather than
--- required, so this stays a plain function with no `deps`/env magic of its own.
--- Returns a closure so review_queue.lua can bind them once and call the result like
--- any other local helper. Reuses `change._parked_state` (set by `park_and_open_state`,
--- review_navigate.lua) IN PLACE -- no fresh diff, no new `hunk_ledger.open`, no
--- `_parked_review` seal read -- because the park (`review_resources.park`) never
--- touched its
function M.reactivate_factory(pool_for, announce_state)
  return function(change, opts)
    local state = change and change._parked_state
    if type(state) ~= "table" then
      return false
    end
    if change._parked_already_staged then
      return false
    end
    if state.opts and state.opts.preview then
      return false
    end
    local bufnr = state.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      change._parked_state = nil
      return false
    end
    -- Reusing the parked state in place repaints NOTHING -- it reinstalls the keymaps
    -- and the button strip and hands the buffer back exactly as the park left it. That
    -- is correct only while the buffer still HOLDS what the park snapshotted.
    --
    -- Refusing unwinds to the caller's `M.open` rebuild, the single owner of
    -- putting `parked.staged_text` back. Restoring the text here would make
    -- this a SECOND writer of the review buffer's content.
    --
    -- PAIRED WITH the `land_after_removal` split in review_navigate.lua: until
    -- that landed, a second park had already overwritten `staged_text` with
    -- the blank, so there was nothing left to restore and this refusal bought
    -- nothing. Each defect hid the other; neither fix closes the row alone.
    local parked = change._parked_review
    _ht_trace(("REACT rel=%s parked=%s emptied=%s"):format(
      tostring(change.rel or change.path), tostring(type(parked) == "table"),
      tostring(type(parked) == "table" and parked.buffer_emptied)))
    if type(parked) == "table" and parked.buffer_emptied then
      _ht_trace("REACT refused -> M.open rebuild")
      return false
    end
    local bufnr = state.bufnr
    if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
      change._parked_state = nil
      return false
    end
    local st = pool_for(opts or state.opts or {})
    for other_change, other in pairs(st.open or {}) do
      if other ~= state and not other.closed and other_change._parked_state ~= other
        and other.bufnr == state.bufnr then return false end
    end
    local review_open_bind = require("yana.review_open_bind")
    if type(review_open_bind.reinstall_keys) ~= "function" then
      return false
    end
    -- THE ONLY STEP OF THIS RESUME THAT CAN FAIL HALFWAY. `reinstall_keys` loops
    -- over the state's key definitions and registers them one at a time, so a
    -- throw on the third leaves two of them bound to a review that is not back
    -- on screen. Left to propagate, that throw also unwound the CALLER --
    -- `open_target_item` never returned, so `park_and_open_state`'s own recovery
    -- (reopen the file we just parked) never ran, and the operator was left with
    -- no live review and no `[x` on the buffer they were in: no route to retry
    -- from at all (F-TRL03-07).
    --
    -- Caught here, unwound here, and reported as a FAILURE rather than a
    -- refusal. The distinction is load-bearing: a refusal (`false, nil`) means
    -- "not resumable in place, rebuild it", and the rebuild is the one route
    -- that discards `_parked_review`. A replacement that has already started
    -- binding and could not finish must keep its recovery snapshot, so this
    -- answers `false, err` and the caller stands the review down instead.
    local bind_ok, bound = pcall(review_open_bind.reinstall_keys, state)
    if not bind_ok then
      -- Back to exactly the parked condition: park releases the keys this
      -- attempt managed to register (while this state still owns the buffer, and
      -- only those it actually described at claim time) and re-invalidates the
      -- watcher attachment the resume was about to replace.
      pcall(require("yana.review_lifecycle").park_review, state)
      return false, tostring(bound)
    end
    if not bound then
      return false
    end
    -- The park invalidated this buffer's watch ownership (`review_resources.park`) and
    -- the first edit made while parked uninstalled that attachment's callback
    -- outright. A resume that reuses the state in place must therefore RE-ATTACH
    -- it, which is what `Watcher.resume` now does.
    --
    -- AND IT IS A REFUSAL POINT. An in-place resume that cannot re-attach would
    -- put the review back on screen watching nothing -- every keystroke absorbed
    -- by no ledger and recorded in no history, silently, for as long as the file
    -- stays open. That is worse than a rebuild, so a failed re-attach unwinds to
    -- the caller's `M.open` rebuild like every other refusal here; the rebuild
    -- attaches a watcher of its own.
    local watch_ok, watch_resumed = pcall(require("yana.review_watch").resume, bufnr, state)
    if not watch_ok or not watch_resumed then
      -- Still a refusal that unwinds to the caller's `M.open` rebuild, as it has
      -- always been -- but the keys reinstalled a moment ago are part of a
      -- replacement that is not going to bind, so they go back with it.
      pcall(require("yana.review_lifecycle").park_review, state)
      return false
    end
    change._parked_state = nil
    -- ONE LIVE LEDGER. A restored review is not re-bound, so a decision made
    -- while it was parked (cA) leaves the Turn File counting that ledger copy
    -- while this review decides its own. Re-attach this review the way a bind
    -- does, before the Turn announces it, so every decision path lands on the one
    -- ledger the Turn counts.
    local live_turn = require("yana.turn.turn_bind").get()
    local live_file = live_turn and change.path
      and live_turn:file(vim.fn.fnamemodify(change.path, ":p")) or nil
    if live_file and state.hunk_ledger and not rawequal(live_file.ledger, state.hunk_ledger) then
      live_turn:attach_review(live_file.path, state)
    end
    -- The panel is the Turn's `review_alive` subscriber's to render,
    -- never this file's to open. Clear the parked marker before announcing
    -- so the strip's live-attachment lookup can see it. A direct
    -- `ui_review_buttons.open` here was the last render route outside the bus:
    -- it put a panel on screen without the Turn ever announcing the review was
    -- alive again, so the panel and the lifecycle could disagree.
    require("yana.turn.turn_bind").announce_review(st)
    change._parked_review = nil
    change.status = "pending"
    announce_state()
    return true
  end
end

-- ENDPOINT CAPTURE AND INSTALL (follow-up plan, "M0: history
-- mapping": S1 record schema `EndpointState`, blocker B1; Reuse decisions row). One file's complete review state at one register endpoint,
-- composed from the existing doors: the ledger half (`capture_ledger_endpoint` over
-- `capture_buffer_snapshot` and the retained history), the decision stacks, the
-- model mirror (`review_hunk_split`) and the facts that validate a landing. Neovim
-- owns the bytes, so neither function writes buffer text; the register owns the
-- endpoint, its `NativePos` and its revisions, so neither keeps a record.
local STACKS = { "decisions", "undone_decisions", "sealed_decisions" }

local function copy_entry(entry)
  local copy = {}
  for key, value in pairs(entry) do
    copy[key] = value
  end
  return copy
end

local function same_rows(a, b)
  return type(a) == "table" and type(b) == "table" and a[1] == b[1] and a[2] == b[2]
end

-- What installing `ep`'s stacks does to decision anchors, which mark exactly the
-- live stacks' decided hunks. `stale`: target entries whose anchor no longer marks
-- the rows it was captured on (only an entry that held an anchor at capture
-- qualifies) and is re-parked there. `drop`: live anchors no installed entry keeps.
local function anchor_plan(state, ep)
  local stale, keep, drop = {}, {}, {}
  for _, name in ipairs(STACKS) do
    for _, entry in ipairs(ep[name] or {}) do
      if entry.anchor ~= nil and type(entry.anchor_rows) == "table"
        and not same_rows(anchor_rows(state.bufnr, entry.anchor), entry.anchor_rows) then
        stale[entry] = true
      elseif entry.anchor ~= nil then
        keep[entry.anchor] = true
      end
    end
  end
  for _, name in ipairs(STACKS) do
    for _, entry in ipairs(state[name] or {}) do
      if entry.anchor ~= nil and not keep[entry.anchor] then
        keep[entry.anchor] = true
        drop[#drop + 1] = entry.anchor
      end
    end
  end
  return stale, drop
end

--- `env.revision`: the endpoint revision the caller is sealing, stored with the
--- ledger history. `env.file`: the Turn's File for this path, owner of the
--- operation and mode verdicts; nil when no Turn holds the file. Returns the
--- EndpointState, or nil and a reason. Stack entries are new tables keeping
--- `block` by identity (it names a ledger member) with each live anchor's rows
--- resolved now, while the bytes are the endpoint's.
function M.capture_endpoint(state, env)
  env = env or {}
  local ledger = type(state) == "table" and state.hunk_ledger or nil
  if not (ledger and ledger:is_open()) then
    return nil, "endpoint capture needs an open ledger"
  end
  local bufnr = state.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil, "endpoint capture needs a live review buffer"
  end
  local bytes, bytes_err = require("yana.diff").buffer_bytes_snapshot(bufnr)
  if bytes == nil then
    return nil, "endpoint capture: " .. tostring(bytes_err)
  end
  local ep = ledger:capture_ledger_endpoint(env.revision)
  for _, name in ipairs(STACKS) do
    local out = {}
    for i, entry in ipairs(state[name] or {}) do
      out[i] = copy_entry(entry)
      out[i].anchor_rows = anchor_rows(bufnr, entry.anchor) or entry.anchor_rows
    end
    ep[name] = out
  end
  ep.model_hunks = require("yana.review_hunk_split").snapshot_model(state.model_hunks)
  local change = state.change or {}
  local file = env.file
  local kind = file and file.operation or change.kind
  local verdict = file and file.operation_verdict or nil
  local mv = file and type(file.mode_verdict) == "table" and copy_entry(file.mode_verdict) or nil
  ep.proposal_view = { before = change.before, after = change.after, after_mode = change.after_mode,
    kind = change.kind, turn_gen = change.turn_gen }
  ep.operation_view = { exists = kind ~= "delete", kind = kind, mode = change.after_mode,
    operation_verdict = verdict, mode_verdict = mv }
  ep.staged_text_ref = state.staged_text
  ep.bytes_ref = bytes
  ep.existence = not ((kind == "create" and verdict == "rejected") or (kind == "delete" and verdict == "accepted"))
  ep.eol = { fileformat = vim.bo[bufnr].fileformat, endofline = vim.bo[bufnr].endofline, bomb = vim.bo[bufnr].bomb }
  ep.mode = (mv and mv.verdict == "allow" and change.after_mode) or change.base_mode or change.before_mode
  ep.attachment_state = { bufnr = bufnr, watch_generation = state._watch_generation,
    watch_detached = state.watch_detached == true, closed = state.closed == true }
  return ep
end

-- The review half of an install, after the ledger half: the stacks as fresh entry
-- copies (stale anchors re-parked), the staged text the decision doors keep beside
-- them, the model mirror in place from fresh entry copies (so the record's entries
-- never become live), and last the anchors no installed entry keeps, so a failure
-- before it leaves the start's anchors live. Anchors parked before the stacks
-- go live belong to nobody yet: any failure there releases them before raising,
-- and a release that fails raises `{msg, leaked}` so the caller cannot claim
-- unchanged. `env.park_anchor(block, first, last)` / `env.drop_anchor(id)` are
-- the review's own pair (review_decisions' `park_anchor` / `drop_anchor`).
local function install_review_half(state, ep, env)
  local stale, drop = anchor_plan(state, ep)
  local stacks, parked = {}, {}
  local built, err = pcall(function()
    for _, name in ipairs(STACKS) do
      local out = {}
      for i, entry in ipairs(ep[name] or {}) do
        out[i] = copy_entry(entry)
        if stale[entry] then
          local rows = entry.anchor_rows
          out[i].anchor = env.park_anchor(entry.block, rows[1], rows[2] or rows[1])
          parked[#parked + 1] = out[i].anchor
        end
      end
      stacks[name] = out
    end
  end)
  if not built then
    local leaked = 0
    for _, id in ipairs(parked) do
      if not pcall(env.drop_anchor, id) then leaked = leaked + 1 end
    end
    error(leaked > 0 and { msg = tostring(err), leaked = leaked } or err, 0)
  end
  for name, out in pairs(stacks) do
    state[name] = out
  end
  state.staged_text = ep.staged_text_ref
  if ep.model_hunks ~= nil then
    local split = require("yana.review_hunk_split")
    split.restore_model_snapshot(state.model_hunks, split.snapshot_model(ep.model_hunks))
  end
  for _, id in ipairs(drop) do
    env.drop_anchor(id)
  end
end

local function same_entry(a, b, skip)
  for key, value in pairs(a) do
    if key ~= skip and b[key] ~= value then return false end
  end
  for key in pairs(b) do
    if key ~= skip and a[key] == nil then return false end
  end
  return true
end

-- What of the review half differs from `ep`, or nil: staged text, each stack entry
-- by value (its anchor by the rows it marks), and each model entry by value.
local function review_half_error(state, ep)
  if state.staged_text ~= ep.staged_text_ref then
    return "staged text differs"
  end
  for _, name in ipairs(STACKS) do
    local live, want = state[name] or {}, ep[name] or {}
    if #live ~= #want then
      return name .. " length differs"
    end
    for i, entry in ipairs(want) do
      if not same_entry(entry, live[i], "anchor") or (entry.anchor ~= nil and type(entry.anchor_rows) == "table"
        and not same_rows(anchor_rows(state.bufnr, live[i].anchor), entry.anchor_rows)) then
        return name .. " entry " .. i .. " differs"
      end
    end
  end
  local model = ep.model_hunks
  if model ~= nil then
    if #state.model_hunks ~= model.n then
      return "model length differs"
    end
    for i = 1, model.n do
      local want, got = model[i], state.model_hunks[i]
      if type(want) == "table" and type(got) == "table" then
        if not same_entry(want, got) then return "model entry " .. i .. " differs" end
      elseif want ~= got then
        return "model entry " .. i .. " differs"
      end
    end
  end
  return nil
end

local function refused(reason)
  return { ok = false, changed = false, code = "refused", reason = reason, byte_location = "pre_call" }
end

local function reason_of(err)
  return type(err) == "table" and err.msg or tostring(err)
end

-- Where the buffer is, against where the endpoint says it must be; nil when it is there.
local function position_error(state, ep, env)
  local seq = env.current_seq()
  if seq ~= env.seq then
    return string.format("native history is at %s, the endpoint at %s", tostring(seq), tostring(env.seq))
  end
  if require("yana.diff").buffer_bytes_snapshot(state.bufnr) ~= ep.bytes_ref then
    return "buffer bytes differ from the endpoint's"
  end
  return nil
end

--- Install EndpointState `ep` on review `state`, whose buffer Neovim has already
--- put at the endpoint. `env.seq`: the endpoint's native sequence (its NativePos);
--- `env.current_seq()`: reads the buffer's; `env.park_anchor` / `env.drop_anchor`:
--- the review's anchor pair, needed only when an anchor must move;
--- `env.revision`/`env.file`: label the start capture used for compensation.
--- Order: ledger history, members, frames, decision stacks, model. Native seq and
--- bytes are verified before anything is written and again before ok.
--- Outcome {ok, changed, code, reason, byte_location, stuck}. An install never moves
--- bytes, so byte_location is always "pre_call". changed=false: nothing moved --
--- refused before writing, or written and compensated back to the start.
--- ok=false with changed=true ("install_stuck") is a halt naming what stayed out.
function M.install_endpoint(state, ep, env)
  env = env or {}
  local ledger = type(state) == "table" and state.hunk_ledger or nil
  if not (ledger and ledger:is_open()) then
    return refused("endpoint install needs an open ledger")
  end
  if state.closed or not (state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then
    return refused("endpoint install needs a live review buffer")
  end
  if state.watch_timeline then
    return refused("endpoint install needs the watcher finalized first")
  end
  if type(ep) ~= "table" or type(env.current_seq) ~= "function" or type(env.seq) ~= "number" then
    return refused("endpoint install needs an EndpointState, its native seq and a seq reader")
  end
  if type(ep.attachment_state) ~= "table" or ep.attachment_state.bufnr ~= state.bufnr then
    return refused("endpoint was captured on another buffer; its native sequence means nothing here")
  end
  if (ep.model_hunks == nil) ~= (type(state.model_hunks) ~= "table") then
    return refused("endpoint and review disagree on the model mirror")
  end
  local stale, drop = anchor_plan(state, ep)
  -- Both helpers whenever any anchor moves: undoing a park needs a drop, and
  -- compensating a drop needs a park.
  if (next(stale) ~= nil or #drop > 0)
    and (type(env.park_anchor) ~= "function" or type(env.drop_anchor) ~= "function") then
    return refused("endpoint install must move decision anchors and lacks park_anchor/drop_anchor")
  end
  local position = position_error(state, ep, env)
  if position then
    return refused(position)
  end
  local start, start_err = M.capture_endpoint(state, { revision = env.revision, file = env.file })
  if not start then
    return refused("endpoint install cannot capture its start: " .. tostring(start_err))
  end
  local called, installed, why = pcall(ledger.install_ledger_endpoint, ledger, ep)
  if called and not installed then
    return refused(why)
  end
  local failure = not called and tostring(installed) or nil
  local stuck = {}
  if not failure then
    local ok, err = pcall(install_review_half, state, ep, env)
    if not ok and type(err) == "table" and err.leaked then
      stuck[#stuck + 1] = "anchors: " .. err.leaked .. " parked anchor(s) not released"
    end
    failure = not ok and reason_of(err) or position_error(state, ep, env) or review_half_error(state, ep)
  end
  if not failure then
    ledger:request_paint()
    return { ok = true, changed = true, code = "installed", byte_location = "pre_call" }
  end
  -- Compensation: the captured start, through the same two halves, each verified
  -- exact (the ledger half checks itself) before anyone reports unchanged.
  local back_called, back_ok, back_why = pcall(ledger.install_ledger_endpoint, ledger, start)
  if not (back_called and back_ok) then
    stuck[#stuck + 1] = "ledger: " .. tostring(back_called and back_why or back_ok)
  end
  local review_ok, review_err = pcall(install_review_half, state, start, env)
  local mismatch = review_ok and review_half_error(state, start) or nil
  if not review_ok or mismatch then
    stuck[#stuck + 1] = "review: " .. (mismatch or reason_of(review_err))
  end
  pcall(ledger.request_paint, ledger)
  if #stuck == 0 then
    return { ok = false, changed = false, code = "rolled_back", reason = failure, byte_location = "pre_call" }
  end
  return { ok = false, changed = true, code = "install_stuck", byte_location = "pre_call",
    reason = failure .. "; compensation failed: " .. table.concat(stuck, "; "), stuck = stuck }
end

return M
