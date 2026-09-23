-- Decision-stack snapshot and in-place resume for a review that is parking.
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

function M.capture(state, bufnr)
  local anchor_ns = vim.api.nvim_create_namespace("YanaInlineDiffDecisionAnchor")
  local function anchor_rows(id)
    if not id then
      return nil
    end
    local ok, ext = pcall(vim.api.nvim_buf_get_extmark_by_id, bufnr, anchor_ns, id, { details = true })
    if not ok or type(ext) ~= "table" or ext[1] == nil then
      return nil
    end
    local meta = ext[3] or {}
    return { ext[1] + 1, (meta.end_row or ext[1]) + 1 }
  end

  local sealed = vim.deepcopy(state.sealed_decisions or {})
  for _, d in ipairs(state.decisions or {}) do
    local copy = vim.deepcopy(d)
    -- Cleanup clears the anchor namespace; preserve rows, not a dead id.
    copy.anchor_rows = anchor_rows(d.anchor) or copy.anchor_rows
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
    if st.active then
      return false
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
    -- ORDER IS LOAD-BEARING, and it is the fresh-open path's order
    -- (review_open_bind.lua:245 sets `st.active` before its own strip open at
    -- :512, and has never carried this bug).
    --
    -- `is_reviewing` is published to outside callers -- review_api.lua:266-268 says so
    -- in the product's own words -- and answers off `st.active`. Opening the strip
    -- calls `nvim_win_set_buf` (ui_review_buttons.lua:312), which fires `BufLeave` on
    -- the review buffer.
    --
    -- Nothing in the open reads pool state: the only `active` in
    -- ui_review_buttons.lua is `inline.abort_active` at :226, inside the abort
    -- button's press handler, which runs on a click long after this. And the
    -- `if st.active then return false end` guard above is unaffected -- it
    -- runs before `reinstall_keys`, which is still the last thing that can
    -- refuse this revival.
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
    st.active = state
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
    -- never this file's to open. `st.active` one line above is what that
    -- subscriber reads, which is why the assignment stays first. A direct
    -- `ui_review_buttons.open` here was the last render route outside the bus:
    -- it put a panel on screen without the Turn ever announcing the review was
    -- alive again, so the panel and the lifecycle could disagree.
    require("yana.turn.turn_bind").announce_review(st)
    change._parked_state = nil
    change._parked_review = nil
    change.status = "pending"
    announce_state()
    return true
  end
end

return M
