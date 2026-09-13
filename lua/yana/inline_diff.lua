-- yana: in-buffer per-hunk diff review (Avante replace_in_file parity).
-- Restores the pre-edit snapshot on disk, previews agent edits as extmarked hunks,
-- and writes the resolved buffer only after the user accepts.
local diff = require("yana.diff")
local config = require("yana.config")
local control_plane = require("yana.safety.control_plane")
local log = require("yana.log")
local ledger = require("yana.ledger")
local render_check = require("yana.render_check")

local M = {}

local NS = vim.api.nvim_create_namespace("YanaInlineDiff")
local HINT_NS = vim.api.nvim_create_namespace("YanaInlineHint")
-- N8-A: the PAINT span and the POSITION AUTHORITY are two different questions
-- and one extmark cannot answer both.
--
--   Paint  wants an EXCLUSIVE end at (last_new_row + 1, col 0), because that is
--          the only encoding that colours the hunk's last new row even when
--          that row is empty (the N8 fix).
--   Authority wants an end that STOPS at the hunk's last new row, because a
--          human line typed at column 0 of the row AFTER the hunk sits exactly
--          at the paint mark's end position; with end_right_gravity the paint
--          end slides over it, live_block_range widens by one, and rejecting
--          the hunk hands the human's line to nvim_buf_set_lines as part of the
--          replaced range. That is silent edit loss, and it happens at EOF too.
--
-- So the authority is its own extmark, in its own namespace, carrying the
-- PRE-N8 geometry: end at (last_new_row, col 0), right_gravity = false,
-- end_right_gravity = true. That end position is strictly BEFORE the row after
-- the hunk, so a boundary insert cannot move it, while an insert or delete
-- INSIDE the hunk still shifts/shrinks it exactly as before. It carries no
-- hl_group, no virt_lines and no priority: it decorates nothing.
--
-- A separate namespace, not a bare unhighlighted mark in NS, because NS is the
-- namespace render_check sweeps for `leaked_decoration` and that the N8 gate
-- counts marks in. An authority mark there would be a leak to one and an extra
-- hunk mark to the other. Everything that clears NS clears AUTH_NS beside it.
local AUTH_NS = vim.api.nvim_create_namespace("YanaInlineDiffAuthority")
-- A THIRD namespace, and it exists because highlight_blocks clears the other
-- two. When a hunk is decided its authority mark goes with the repaint that
-- follows -- highlight_blocks does `nvim_buf_clear_namespace(AUTH_NS)` and
-- rebuilds marks only for the blocks still in the list -- so a resolved hunk
-- cannot keep its authority mark as the anchor an un-decide would need. This
-- namespace is never cleared by a repaint: one mark per DECIDED hunk, spanning
-- the range that hunk occupied at the moment it was decided, deleted when the
-- decision is taken back or when the review closes. It paints nothing.
local ANCHOR_NS = vim.api.nvim_create_namespace("YanaInlineDiffDecisionAnchor")
local INCOMING_PRIO = (vim.hl or vim.highlight).priorities.user

local function park_decision_anchor(bufnr, start_line, end_line)
  if not (start_line and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local last = vim.api.nvim_buf_line_count(bufnr) - 1
  local srow = math.min(math.max(start_line - 1, 0), math.max(last, 0))
  local erow = math.min(math.max((end_line or start_line) - 1, srow), math.max(last, 0))
  local ok, id = pcall(vim.api.nvim_buf_set_extmark, bufnr, ANCHOR_NS, srow, 0, {
    end_row = erow,
    end_col = 0,
    right_gravity = false,
    end_right_gravity = true,
  })
  return ok and id or nil
end

-- WARN records per change from the rung-1 invariant capture. A review
-- re-renders on every resolved hunk, so an unrecorded cap would turn one
-- defect into one record per keystroke and bury the first occurrence. The
-- ledger keeps every check either way; this only bounds what reaches disk.
local MAX_RENDER_WARNS = 3

-- Per-workspace review pools. CORE limits one live layered turn per workspace;
-- queue/active/batched state is keyed by workspace root, not truly global.
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
  local st = pools[key]
  if not st then
    st = { queue = {}, active = nil, batched = {}, order = {}, order_seq = 0 }
    pools[key] = st
  end
  return st, key
end

local function pool_for_state(state)
  if state and state.opts then
    return pool_for(state.opts)
  end
  return pool_for({})
end

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
  return {
    panel_id = opts.review_owner.panel_id,
    epoch = opts.review_owner.epoch,
  }
end

local function find_active_for_change(change)
  for _, st in pairs(pools) do
    if st.active and st.active.change == change then
      return st
    end
  end
  return nil
end

function M.mark_batched(path, opts)
  if path then
    local st = pool_for(opts or {})
    st.batched[diff.abs_path(path)] = true
  end
end

function M.unmark_batched(path, opts)
  if path then
    local st = pool_for(opts or {})
    st.batched[diff.abs_path(path)] = nil
  end
end

-- Without noice, vim.notify is a plain echo: anything wider than 'columns'
-- raises a hit-enter prompt, which blocks the main loop and every scheduled
-- callback queued behind it. A review that opens and then freezes the editor
-- is the worst shape this module has. Budget in DISPLAY CELLS, not characters
-- -- a CJK path is two cells per char, so a character-budgeted cut still
-- overflows -- and trim until the ellipsis fits.
-- Hoisted to yana.notify: ui.lua raises the same hit-enter deadlock from
-- its own long notifications, so the budget belongs in one shared place.
local notify = require("yana.notify")
local notify_one_line = notify.one_line

-- TIMELINE RECORDING. One helper, called at the three review events the
-- timeline lists: a review opening, a hunk decided (buffer regime -- the bytes
-- are Neovim's undo tree), and a durable applier write (durable regime -- the
-- bytes are the diary's). It is wrapped so a failure to record never touches
-- the review: the timeline is an INDEX, and a review that works without an
-- index is strictly better than one that halts because the index could not be
-- written. What it must never do is HOLD bytes; it passes ids, integers and a
-- workspace-relative path, nothing more.
local function tl_observe(bufnr)
  local ok, rec = pcall(require, "yana.timeline.record")
  if not ok or type(rec) ~= "table" or type(rec.observe_buffer) ~= "function" then
    return {}
  end
  local obs = rec.observe_buffer(bufnr)
  return obs or {}
end

local function tl_record(state, kind, label, extra, async)
  local change = state and state.change
  if not change then
    return
  end
  local ws = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
  local rel = change.rel or change.path
  if not rel then
    return
  end
  local ok, tl = pcall(require, "yana.timeline")
  if not ok or type(tl) ~= "table" or type(tl.intent) ~= "function" then
    return
  end
  local entry = {
    kind = kind,
    label = label,
    regime = (extra and extra.regime) or "buffer",
    rel = rel,
    workspace = ws,
    -- WHICH TURN WROTE THIS ROW (operator ruling #99 + the stamp ruling,
    -- 2026-08-23). Read off the change, never minted here: the turn's id is
    -- `turn_lifecycle.new_turn_id`'s, put on every change by
    -- `shadow/ops.changes_from_session`. `turn_gen` is the same fallback the
    -- rest of this file already uses when a change predates the durable id
    -- (see `same_turn`), so the stamp names a turn by exactly the identity the
    -- product already agrees on.
    turn_id = change.turn_id or change.turn_gen,
    -- ONE FILE-LEVEL DECISION, ONE REGISTER ROW (ruling 75): `accept_all`/
    -- `reject_all` record a SINGLE `file_accepted`/`file_rejected` row
    -- (never one row per hunk) and carry the hunks it covers here, for the
    -- reopen path (`M._register_decisions`) to paint them all pending
    -- again. Every other caller omits it.
    members = extra and extra.members,
  }
  if entry.regime == "buffer" then
    entry.buffer_epoch = extra and extra.buffer_epoch
    entry.undo_seq = extra and extra.undo_seq
    entry.expected_hash = extra and extra.expected_hash
  else
    entry.diary_dir = extra and extra.diary_dir
    entry.op_id = extra and extra.op_id
  end
  if async and type(tl.intent_async) == "function" then
    local called, id, err = pcall(tl.intent_async, entry, function(ok, async_err)
      if not ok then
        log.write("WARN", "timeline event was appended but not durable: " .. tostring(async_err))
      end
    end)
    if not called or not id then
      log.write("WARN", "timeline event could not be queued: " .. tostring(called and err or id))
      return nil
    end
    return id
  end
  -- The minted row id, returned so a decision can name its OWN register row
  -- later (`tl_head_row`); every existing caller ignores it, exactly as before.
  local ok_intent, id = pcall(tl.intent, entry)
  return ok_intent and id or nil
end

--- ROW 112 / ruling 75: the in-review `u`/`<C-r>` and the cross-file register
--- are ONE register, so a decision taken back HERE must stop reading `done`
--- THERE. Without this the row stays `done` after the review has already given
--- the hunk back, and the next `u` -- once this review parks or closes --
--- spends itself walking the SAME decision a second time (measured on the
--- row-112 sequence: press 8 undid b.py's accept again, so a.py's own older
--- accept never got its press).
--- The mechanism is the one `walk_impl.step_buffer` already ends every buffer
--- step with: move THIS buffer's recorded head to the row the register now
--- rests on, and `record.entries` reads every buffer row after it as
--- `reverted`. `land_before = true` rests it on the row BEFORE `id` (undo),
--- `false` on `id` itself (redo). The POSITION written is always the LIVE one:
--- an accept moved no bytes, and a reject's own `:undo` has already put the
--- buffer where the older row describes -- so the head keeps naming where this
--- buffer actually is, which is what `retrace.on_u_key` compares against.
--- On `M` rather than a file-local: the review closure that calls it is at
--- Lua's 60-upvalue ceiling, and one more local would push it over (measured:
--- "function at line 3913 has more than 60 upvalues"). `M` is already an
--- upvalue there, exactly as `M._park_and_open_state` and
--- `M._redo_staged_restores` already are.
function M._tl_head_row(state, id, land_before)
  if type(id) ~= "string" or id == "" then
    return
  end
  local bufnr = state and state.bufnr
  local change = state and state.change
  if not (bufnr and change and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local rel = change.rel or change.path
  if not rel then
    return
  end
  local ws = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
  local ok, tl = pcall(require, "yana.timeline")
  if not ok or type(tl) ~= "table" or type(tl.entries) ~= "function" then
    return
  end
  local ok_entries, entries = pcall(tl.entries, ws, rel)
  if not ok_entries or type(entries) ~= "table" then
    return
  end
  local target
  for i, e in ipairs(entries) do
    if e.id == id then
      if not land_before then
        target = e
      else
        for j = i - 1, 1, -1 do
          if entries[j].regime == "buffer" then
            target = entries[j]
            break
          end
        end
      end
      break
    end
  end
  if not target then
    return
  end
  local ok_rec, rec = pcall(require, "yana.timeline.record")
  if not ok_rec or type(rec.sync_buffer_head) ~= "function" or type(rec.observe_buffer) ~= "function" then
    return
  end
  local obs = rec.observe_buffer(bufnr)
  if not obs then
    return
  end
  obs.id = target.id
  rec.sync_buffer_head(bufnr, obs)
  -- The explicit mark (see `record.mark_reverted`): a pop reverts `id`, a
  -- redo puts it back. Head position alone cannot say this for a byte-less
  -- row.
  if type(rec.mark_reverted) == "function" then
    rec.mark_reverted(id, land_before and true or false)
  end
end

local function tl_same_observation(a, b)
  return type(a) == "table"
    and type(b) == "table"
    and a.buffer_epoch == b.buffer_epoch
    and a.undo_seq == b.undo_seq
    and a.expected_hash == b.expected_hash
end

--- Is this buffer sitting exactly where YANA'S OWN bookkeeping last put it?
---
--- `record.buffer_head` is written at every `timeline.intent` and at the end of
--- every buffer-regime `walk_impl.step_buffer` / `retrace.redo`, so it always
--- names the position the product itself moved this buffer to. If the live
--- observation still equals it, nothing else has touched the buffer since --
--- which is the SAME two-owner test `retrace.on_u_key` already uses to decide
--- whether a press belongs to the register or to Neovim's own undo, asked here
--- about a movement instead of a keypress.
local function tl_buffer_at_register_head(bufnr)
  local ok, rec = pcall(require, "yana.timeline.record")
  if not ok or type(rec) ~= "table" or type(rec.buffer_head) ~= "function" or type(rec.observe_buffer) ~= "function" then
    return false
  end
  local head = rec.buffer_head(bufnr)
  local cur = rec.observe_buffer(bufnr)
  return head ~= nil
    and cur ~= nil
    and type(head.undo_seq) == "number"
    and head.buffer_epoch == cur.buffer_epoch
    and head.undo_seq == cur.undo_seq
end

--- Record typing that occurred since the last review event. The row stores the
--- post-edit undo bookmark; the walker resolves its destination from the
--- nearest older buffer row.
---
--- WHOSE MOVEMENT WAS IT (issue-log row 113, the det3d screencast). A review's
--- `state.timeline_obs` is refreshed at this review's OWN events, and a
--- CROSS-FILE walk moves buffers this review never hears about: `u` in b.py
--- walks b.py's own decisions back, and the next press's reintegration parks
--- b.py -- at which point this function used to see b.py's buffer sitting
--- somewhere other than where it last looked and record a `human_edit` row for
--- typing NOBODY DID. Measured: after the first press reopened a.py, a phantom
--- `human_edit` row for b.py (undo_seq 1, one BEHIND its predecessor's 2) sat
--- newest in the cross-file order, so every later press selected it, tripped
--- `retrace.M.undo`'s backwards-undo_seq guard and answered "undo sequence
--- drift: buffer is at seq 1, but Yana's register head is seq 2" for ever --
--- the walk never reached hunks 2 and 1 at all (the same stuck drift loop the
--- localiser replay recorded, REPLAY.md).
---
--- The register already knows the answer, so ASK IT rather than infer from the
--- bytes: a buffer that sits exactly on Yana's own recorded head was moved by
--- Yana, and a movement the product performed is not the human's typing. Only
--- a buffer that has drifted OFF that head can carry a human edit, which is
--- the only case that records one now.
local function tl_capture_human_edit(state)
  if not (state and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then
    return
  end
  -- Force any classification `attach_buffer_watch`'s on_lines watcher left
  -- queued (`state.watch_pending`) to run NOW, before `state.free_standing_edit`
  -- is read below. Without this, a decision key pressed before the watcher's
  -- deferred `vim.schedule` callback had run read a STALE flag left over from
  -- the previous decision boundary and silently downgraded a genuine
  -- free-standing edit to an `absorbed_edit` marker (issue 15).
  -- Idempotent: `process_pending_watch` no-ops if there is nothing queued,
  -- including when the scheduler already ran it first.
  if type(state.flush_pending_watch) == "function" then
    state.flush_pending_watch()
  end
  local obs = tl_observe(state.bufnr)
  if
    state.timeline_obs
    and not tl_same_observation(state.timeline_obs, obs)
    and not tl_buffer_at_register_head(state.bufnr)
  then
    obs.regime = "buffer"
    local rel = state.change.rel or state.change.path or "?"
    -- RULING 75/73/57: typing absorbed into a still-pending hunk (decision
    -- 57's `absorb_human_edits`, ruling 73's hunk-edge rule) is NOT a
    -- register STEP of its own -- it becomes part of that hunk's own bytes
    -- and is undone/redone with whichever decision the hunk gets. But its
    -- position in the buffer's own undo tree is still real, and the
    -- decision that follows it must land back exactly there rather than
    -- skipping past it into the file's older history -- so it is recorded
    -- as a MARKER (`absorbed_edit`, `record.UNDOABLE_KIND` excludes it),
    -- never as an actionable `human_edit`. Without this distinction a walk
    -- edge that typed at a hunk boundary and then decided it (`o<Esc>`,
    -- `dd`, `ct`) either minted an extra press-consuming step between the
    -- two, or (recording nothing at all) let the decision's own undo skip
    -- straight past the typing to the file's turn-start bytes, losing it --
    -- both measured on the four-file mirror walk
    -- (`r75_four_file_walk_mirror`).
    -- `state.free_standing_edit` is set true only when some part of the
    -- drift since the last observation landed OUTSIDE every pending hunk
    -- (the buffer watcher below); reset here regardless of which way this
    -- goes, so the next round of edits starts fresh.
    if state.free_standing_edit then
      tl_record(state, "human_edit", "edit " .. rel, obs)
    else
      tl_record(state, "absorbed_edit", "absorbed edit " .. rel, obs)
    end
  end
  state.timeline_obs = obs
  state.free_standing_edit = false
end

local function tl_sync_observation(state)
  if state and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    state.timeline_obs = tl_observe(state.bufnr)
  end
end


-- Returned by open_review_buffer when the payload carried no
-- beforeFullFileContent. Matched by string in M.open to decide whether a
-- refusal means "keep the unrevertible edit" rather than "retry later".
local NO_SNAPSHOT_ERR = "no pre-edit snapshot; review cannot offer revert"

-- Palette hl groups (YanaHl*). Applied with force=true; only visible in review
-- windows via winhl — does not touch DiffAdd/DiffDelete or global editor chrome.
local PALETTE = {
  incoming = "YanaHlIncoming",
  deleted = "YanaHlDeleted",
  hint = "YanaHlHint",
}

local EXT_HL = {
  incoming = "YanaDiffIncoming",
  deleted = "YanaDiffDeleted",
  hint = "YanaInlineHint",
}

-- FAULT INJECTION, default OFF, the same `_test.fault` shape
-- lua/yana/shadow/apply.lua uses. Armed only by the recorder's synthetic-bug
-- menu (oracle/adapters/yana-v2/rec/plant) to put a KNOWN paint defect on
-- camera so the cold video read-back can be scored against ground truth.
-- Module-level because `M._test` is REASSIGNED twice below (a fresh table per
-- open review, and once more at the module tail); both sites re-expose this
-- same table as `M._test.fault`, and `M._fault` is the handle no reassignment
-- can clobber.
local FAULT = {}
M._fault = FAULT

--- Does the `sticky_paint` plant cover THIS block? `true` means every decided
--- hunk; `{block = k}` names one by the ordinal a viewer would count on
--- screen, top to bottom, which is exactly the live block list's order.
--- Reached through `M` rather than as a bare local so the review's own big
--- closure gains no upvalue for it (Lua caps a function at 60).
function M._fault_keeps_paint(blocks, block)
  local f = FAULT.sticky_paint
  if not f then
    return false
  end
  if f == true then
    return true
  end
  for i, b in ipairs(blocks or {}) do
    if b == block then
      return f.block == i
    end
  end
  return false
end

local function palette_defs()
  local h = config.options.diff_highlights or {}
  local git = {
    incoming = { link = "DiffAdd" },
    deleted = { link = "DiffDelete" },
    hint = { link = "Comment" },
  }
  return {
    [PALETTE.incoming] = h.incoming or git.incoming,
    [PALETTE.deleted] = h.deleted or git.deleted,
    [PALETTE.hint] = h.hint or git.hint,
  }
end

local function apply_palette_highlights()
  for name, spec in pairs(palette_defs()) do
    -- Explicit bg/fg wins over link (deep-merge used to leave DiffAdd link behind).
    if spec.link and not spec.bg and not spec.fg then
      vim.api.nvim_set_hl(0, name, { link = spec.link, default = true, force = true })
    else
      local hl = vim.tbl_extend("force", spec, { force = true })
      hl.link = nil
      if name == PALETTE.deleted then
        hl.strikethrough = false
      end
      vim.api.nvim_set_hl(0, name, hl)
    end
  end
end

local function wins_for_buf(bufnr)
  local wins = {}
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      table.insert(wins, w)
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
    EXT_HL.incoming .. ":" .. PALETTE.incoming,
    EXT_HL.deleted .. ":" .. PALETTE.deleted,
    EXT_HL.hint .. ":" .. PALETTE.hint,
  }, ",")
end

local function apply_review_winhl(bufnr, state)
  apply_palette_highlights()
  state.winhl_restore = state.winhl_restore or {}
  local add = review_winhl_spec()
  for _, win in ipairs(wins_for_buf(bufnr)) do
    if vim.api.nvim_win_is_valid(win) and state.winhl_restore[win] == nil then
      -- N15: record the baseline WITHOUT our own entries. A window opened
      -- during a review (`:split`) inherits the review mapping from the window
      -- it was split from, so its raw winhl is not a pre-review baseline —
      -- recording it verbatim would make teardown "restore" the review mapping
      -- and pin it there for good. Stripping first makes the recorded value a
      -- true baseline whether the window predates the review or not, and is a
      -- no-op for a window that never carried our entries.
      local prev = vim.wo[win].winhl or ""
      local base = strip_yana_winhl(prev)
      state.winhl_restore[win] = base
      vim.wo[win].winhl = base ~= "" and (base .. "," .. add) or add
    end
  end
end

-- Blank the review palette groups when the review closes.
--
-- N14: this used to call `nvim_set_hl(0, name, { clear = true })`. `clear` is
-- NOT a valid nvim_set_hl key — the API raises "invalid key: clear" — and the
-- bare pcall swallowed it, so the palette was never cleared and stayed defined
-- globally for the rest of the session. Probed on this build (v0.12.0-dev):
--
--   { clear = true } -> ok=false, "invalid key: clear", group UNCHANGED
--   {}               -> ok=true,  group resolves to an empty attribute set,
--                       for a plain group and for a `link`ed one alike
--
-- so the empty table is the clearing idiom here. The pcall stays (teardown must
-- not throw) but the failure is no longer discarded: a palette that cannot be
-- blanked is exactly the state that turns a surviving winhl entry into visible
-- colour damage, so it is RECORDED at WARN through the product's own log. WARN,
-- not vim.notify: this observes, it must never interrupt or change control flow.
local function clear_palette_highlights()
  for _, name in pairs(PALETTE) do
    local ok, err = pcall(vim.api.nvim_set_hl, 0, name, {})
    if not ok then
      log.write(
        "WARN",
        "yana.inline_diff: could not clear review palette highlight "
          .. tostring(name)
          .. ": "
          .. tostring(err)
      )
    end
  end
end

-- N15: teardown must restore every window that ended up carrying the review
-- mapping, not only the windows that existed when the review opened.
--
-- Mechanism: RECORD-AND-SWEEP, both halves, because neither alone is enough.
--   * Record. For a window apply_review_winhl patched we hold its true
--     pre-review baseline and write exactly that back — the only way to give a
--     user's own `NormalNC:Comment` back byte for byte.
--   * Sweep. A window can acquire the mapping without this engine ever
--     patching it: `:split` copies window-local options into the new window,
--     and `nvim_open_win{enter=false}` does so without firing the WinEnter
--     autocmd that would have recorded it. So every remaining window still
--     showing the review buffer is swept, and only the entries this product
--     installed are removed (strip_yana_winhl). Deliberately NOT a blanket
--     `winhl = ""`: that would clobber a value the user or another plugin set
--     on a window we never had a baseline for.
local function restore_review_winhl(state)
  local restored = {}
  for win, prev in pairs(state.winhl_restore or {}) do
    if vim.api.nvim_win_is_valid(win) then
      restored[win] = true
      vim.wo[win].winhl = prev
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

local function split_lines(text)
  if text == nil or text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

-- Buffer lines for a snapshot string. A trailing "\n" splits into a final ""
-- element, which as a buffer line is a real blank line: harmless while resolve
-- wrote an exact string through io.open, but now that resolve saves the buffer
-- itself that phantom line lands on disk as an extra newline. Drop it here and
-- let 'endofline'/'fixendofline' decide the final newline at write time.
local function buffer_lines(text)
  local lines = split_lines(text)
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function M.build_diff_blocks(before, after)
  local old_str = before or ""
  local new_str = after or ""
  if old_str == new_str then
    return {}
  end

  local old_lines = split_lines(old_str)
  local new_lines = split_lines(new_str)
  local patch = vim.diff(old_str, new_str, {
    algorithm = "histogram",
    result_type = "indices",
    ctxlen = vim.o.scrolloff,
  })

  local blocks = {}
  for _, hunk in ipairs(patch) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    local start_line, end_line
    if count_a == 0 then
      -- Pure insert: nvim_buf_set_lines uses [start_line-1, end_line) with end_line < start_line.
      -- vim.diff: start_a = line AFTER which to insert (0 = BOF).
      start_line = start_a + 1
      end_line = start_a
    else
      start_line = start_a
      end_line = start_a + count_a - 1
    end
    local block = {
      old_lines = count_a > 0 and vim.list_slice(old_lines, start_a, start_a + count_a - 1) or {},
      new_lines = count_b > 0 and vim.list_slice(new_lines, start_b, start_b + count_b - 1) or {},
      start_line = start_line,
      end_line = end_line,
    }
    table.insert(blocks, block)
  end

  local base = 0
  for _, block in ipairs(blocks) do
    block.new_start_line = block.start_line + base
    block.new_end_line = block.new_start_line + #block.new_lines - 1
    base = base + #block.new_lines - #block.old_lines
  end
  return blocks
end

local function win_for_buf(bufnr)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      if vim.api.nvim_win_get_buf(w) == bufnr then
        return w, tab
      end
    end
  end
  return nil, nil
end

local function tab_for_path(path)
  local abs = diff.abs_path(path)
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
      local b = vim.api.nvim_win_get_buf(w)
      if vim.api.nvim_buf_is_valid(b) then
        local name = vim.api.nvim_buf_get_name(b)
        if name ~= "" and diff.abs_path(name) == abs then
          return tab, w, b
        end
      end
    end
  end
  return nil, nil, nil
end

local function focus_buf(path, bufnr)
  local win, tab = win_for_buf(bufnr)
  if win and vim.api.nvim_win_is_valid(win) then
    if tab and vim.api.nvim_tabpage_is_valid(tab) then
      pcall(vim.api.nvim_set_current_tabpage, tab)
    end
    vim.api.nvim_set_current_win(win)
  else
    -- vim.cmd("edit ...") can throw E37 asynchronously (inside vim.schedule)
    -- when the current buffer is modified and 'hidden' is off; switching the
    -- window's buffer directly never touches the current buffer's state.
    -- Prefer a window already showing a normal file so the review does not
    -- evict the yana panel, and pcall the switch: this runs scheduled,
    -- and E211 fires here if the file vanished since the agent wrote it.
    local target
    for _, w in ipairs(vim.api.nvim_list_wins()) do
      if vim.bo[vim.api.nvim_win_get_buf(w)].buftype == "" then
        target = w
        break
      end
    end
    target = target or 0
    if pcall(vim.api.nvim_win_set_buf, target, bufnr) then
      -- The hunk keymaps are buffer-local, so a review parked in an unfocused
      -- window is unreachable: focusing is the whole job of this function.
      pcall(vim.api.nvim_set_current_win, target)
    else
      -- Could not place the buffer in any window, and no window already
      -- showed it: the review would be displayed nowhere, so its buffer-
      -- local keymaps would be unreachable. Return nil so the caller can
      -- detect this and abort the review instead of leaving it stuck.
      return nil
    end
  end
  return bufnr, win_for_buf(bufnr)
end

local function review_tabs_state_path(opts)
  if opts and type(opts.review_tabs_state_path) == "string" and opts.review_tabs_state_path ~= "" then
    return opts.review_tabs_state_path
  end
  return nil
end

local function review_tabs_enabled(opts)
  if opts and opts.review_tabs == false then
    return false
  end
  return true
end

local function review_turn_key(change)
  if not change then
    return nil
  end
  return tostring(change.turn_id or change.turn_gen or "")
end

local function read_json_file(path)
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local raw = fh:read("*a")
  fh:close()
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

local function write_json_file(path, value)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" then
    pcall(vim.fn.mkdir, dir, "p")
  end
  local ok, payload = pcall(vim.json.encode, value)
  if not ok or type(payload) ~= "string" then
    return false
  end
  local fh = io.open(path, "wb")
  if not fh then
    return false
  end
  fh:write(payload)
  fh:close()
  return true
end

local function review_tabs_save_state(st, opts)
  local path = review_tabs_state_path(opts)
  local rt = st and st.review_tabs
  if not path or not rt or not rt.turn_key then
    return
  end
  local owned = {}
  for abs, entry in pairs(rt.owned or {}) do
    owned[abs] = {
      tab_id = entry.tab_id,
      rel = entry.rel,
    }
  end
  write_json_file(path, {
    version = 1,
    turn_key = rt.turn_key,
    owned = owned,
  })
end

local function review_tabs_collect_turn_changes(st, change)
  local out = {}
  local seen = {}
  local function same_turn_local(a, b)
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
    local c = (entry and entry.change) or entry
    if c and c.path and (change == nil or same_turn_local(c, change)) and not seen[c.path] then
      seen[c.path] = true
      out[#out + 1] = c
    end
  end
  for _, item in ipairs(st.queue or {}) do
    local c = item and item.change
    if c and c.path and (change == nil or same_turn_local(c, change)) and not seen[c.path] then
      seen[c.path] = true
      out[#out + 1] = c
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

function M._review_tabs_init_for_turn(st, change, opts)
  if not review_tabs_enabled(opts) then
    st.review_tabs = nil
    return nil
  end
  local turn_key = review_turn_key(change)
  if (turn_key == nil or turn_key == "") and opts and opts.review_owner then
    turn_key = tostring(opts.review_owner.panel_id or "?") .. ":" .. tostring(opts.review_owner.epoch or "?")
  end
  if turn_key == nil or turn_key == "" then
    turn_key = "unknown"
  end
  local turn_changes = review_tabs_collect_turn_changes(st, change)
  if opts and type(opts.review_paths) == "table" then
    local seen = {}
    for _, c in ipairs(turn_changes) do
      seen[diff.abs_path(c.path)] = true
    end
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
  if st.review_tabs and st.review_tabs.turn_key ~= turn_key then
    st.review_tabs = nil
  end
  local rt = st.review_tabs or {
    turn_key = turn_key,
    owned = {},
    enabled = false,
    all_paths = {},
  }
  rt.turn_key = turn_key
  if #turn_changes < 2 then
    rt.enabled = false
    st.review_tabs = rt
    return rt
  end
  rt.enabled = true
  local cur_tab = vim.api.nvim_get_current_tabpage()
  local cur_win = vim.api.nvim_get_current_win()
  local existed = {}
  for _, c in ipairs(turn_changes) do
    local abs = diff.abs_path(c.path)
    local rel = c.rel or c.path
    rt.all_paths[abs] = rel
    existed[abs] = select(1, tab_for_path(abs))
  end

  -- ownership is decided at open time: tabs pre-existing for a file are reused
  -- and never owned; tabs this turn creates are owned.
  for _, c in ipairs(turn_changes) do
    local abs = diff.abs_path(c.path)
    local rel = c.rel or c.path
    local tab = existed[abs]
    if not tab then
      if change and abs == diff.abs_path(change.path) then
        tab = cur_tab
      else
        local ok = pcall(vim.cmd, "tabnew " .. vim.fn.fnameescape(abs))
        if ok then
          tab = vim.api.nvim_get_current_tabpage()
        end
      end
    end
    if tab and not existed[abs] and rt.owned[abs] == nil then
      rt.owned[abs] = { tab_id = tab, rel = rel }
    elseif tab and rt.owned[abs] ~= nil then
      rt.owned[abs].tab_id = tab
      rt.owned[abs].rel = rel
    end
  end

  st.review_tabs = rt
  if cur_tab and vim.api.nvim_tabpage_is_valid(cur_tab) then
    pcall(vim.api.nvim_set_current_tabpage, cur_tab)
  end
  if cur_win and vim.api.nvim_win_is_valid(cur_win) then
    pcall(vim.api.nvim_set_current_win, cur_win)
  end
  review_tabs_save_state(st, opts)
  return rt
end

-- 16 hex chars of the content hash, for refusal records only. Never the
-- contents: a staleness dispute needs to know WHICH bytes each side saw, not
-- what they said. Computed on refusal branches only, so the cost is off the
-- hot path by construction.
local function fingerprint(text)
  if type(text) ~= "string" then
    return nil
  end
  local ok, digest = pcall(function()
    return require("yana.safety.hash").hash_bytes(text)
  end)
  if not ok or type(digest) ~= "string" then
    return nil
  end
  return digest:sub(1, 16)
end

-- Full 64-hex content fingerprint, the shape the diary's CAS compares
-- (`safety/diary.lua` rejects anything shorter). `fingerprint` above truncates
-- to 16 for human-readable evidence and must not be used where the applier
-- will compare the value.
local function base_fingerprint(text)
  if type(text) ~= "string" then
    return nil
  end
  local ok, digest = pcall(function()
    return require("yana.safety.hash").hash_bytes(text)
  end)
  if not ok or type(digest) ~= "string" then
    return nil
  end
  return digest
end

-- Refusals return (nil, message, detail). `detail.reason` is the machine
-- classification the log records — a system refusal is not a user decision,
-- and reading the two as one is what made review churn unattributable.
local function stale_refusal(msg, expected, actual)
  return nil, msg, {
    reason = "stale_file",
    expected_fp = fingerprint(expected),
    actual_fp = fingerprint(actual),
  }
end

-- WHO moved the file. `stale_file` says only that disk stopped matching the
-- turn-start bytes; it cannot say whether a HUMAN saved during review or the
-- AGENT overwrote its own edit inside the same turn, and those are opposite
-- diagnoses -- a race with the operator versus the agent fighting itself. The
-- corpus showed 18 refusals in one session with no way to split them.
--
-- The datum that separates them is already in hand at every drift refusal:
-- when the agent self-wrote, the bytes on disk ARE this change's own
-- after-content, so `actual_fp` equals fingerprint(change.after). Nothing else
-- produces that collision by accident. It was recorded and never compared.
--
-- Returns (origin, reason):
--   "agent"     disk holds this change's own after-content -> agent_self_write
--   "external"  disk holds something else -> the reason class is left alone
--   "unknown"   there is nothing to compare against, so no claim is made:
--               deletes and creates carry no `after`, and a hash that could not
--               be computed leaves the question open. Guessing "external" here
--               would dress an absence of evidence up as a finding.
-- Nil origin means this refusal is not a drift refusal at all (no `actual_fp`),
-- where a missing field is honest and an "unknown" would imply a comparison was
-- attempted.
local SELF_WRITE_REASON = "agent_self_write"

local function attribute_drift(change, reason, actual_fp)
  if type(actual_fp) ~= "string" then
    return nil, reason
  end
  if type(change) ~= "table" or type(change.after) ~= "string" then
    return "unknown", reason
  end
  local after_fp = fingerprint(change.after)
  if type(after_fp) ~= "string" then
    return "unknown", reason
  end
  if after_fp == actual_fp then
    return "agent", SELF_WRITE_REASON
  end
  return "external", reason
end

--- Close the buffer's current undo block, so the NEXT buffer change starts a
--- new one and plain `u` stops one step short of it.
---
--- THE MECHANISM, and why it is this one. Neovim exposes no API for it: undo
--- blocks are closed by `u_sync`, which the editor runs by itself every time
--- the main loop goes idle waiting for the operator's next key. Setting
--- 'undolevels' to its own value is Vim's OWN documented way to ask for that
--- sync out of band (`:h undo-blocks`), and it is the only one. It is scoped
--- to `bufnr` through nvim_buf_call so a decision on one review cannot split a
--- block in whatever buffer happens to be current.
---
--- WHERE IT ACTUALLY MATTERS. MEASURED under a real main loop (NVIM v0.12.4,
--- `nvim --headless --listen`, keys delivered by `--remote-send`, i.e. through
--- nvim_input and the real normal-mode loop): three `co` presses on a
--- three-hunk review already land in three separate undo blocks with nothing
--- added here -- the idle between two keypresses closes them. What does NOT
--- get a boundary for free is several buffer changes made inside ONE
--- keypress, and reject-file (`cb`) is exactly that: finish_session restores
--- every hunk in one loop, so before this the whole file collapsed into one
--- undo state and a single `u` took back all three hunks together.
---
--- MEASURED, and it is why this is safe to call unconditionally: with no
--- pending buffer change the sync creates NO undo state. A decision that
--- rewrites no bytes therefore cannot cost the operator a `u` that appears to
--- do nothing.
local function break_undo_block(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("let &undolevels = &undolevels")
  end)
end

--- Where this buffer currently sits in ITS OWN undo tree. An INTEGER, and
--- that is the whole point: Yana bookmarks positions in Neovim's history
--- and never holds a copy of the bytes at one. Every byte restoration in this
--- file's undo paths is `:undo {seq}` -- the editor moving its own buffer --
--- so there is no second copy of the text that could disagree with it. The
--- product's worst measured defect was exactly the other shape (pre-ce50120
--- reject wrote a held `change.before` snapshot over the human's buffer and
--- marked it clean), and the vendor's is the same shape one layer in
--- (the upstream rejection behavior, FileChangeTracker.reject).
local function buf_undo_seq(bufnr)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return nil
  end
  local seq
  pcall(vim.api.nvim_buf_call, bufnr, function()
    seq = (vim.fn.undotree() or {}).seq_cur
  end)
  return seq
end

local function replace_line_span(lines, start_line, end_line, replacement)
  local out = {}
  for i = 1, math.max(0, start_line - 1) do
    out[#out + 1] = lines[i]
  end
  for _, line in ipairs(replacement or {}) do
    out[#out + 1] = line
  end
  for i = math.max(start_line, end_line + 1), #lines do
    out[#out + 1] = lines[i]
  end
  return out
end

local function lines_after_pending_withheld(lines, blocks)
  local out = vim.deepcopy(lines or {})
  local ordered = vim.deepcopy(blocks or {})
  table.sort(ordered, function(a, b)
    return (a.new_start_line or math.huge) < (b.new_start_line or math.huge)
  end)
  local offset = 0
  for _, block in ipairs(ordered) do
    local start_line = (block.new_start_line or block.start_line or 1) + offset
    local end_line = start_line + math.max(#(block.new_lines or {}), 1) - 1
    if #(block.new_lines or {}) == 0 then
      end_line = start_line - 1
    end
    out = replace_line_span(out, start_line, end_line, block.old_lines or {})
    offset = offset + #(block.old_lines or {}) - #(block.new_lines or {})
  end
  return out
end

local function lines_after_sealed_accepts(before, decisions)
  local out = buffer_lines(before or "")
  local accepted = {}
  for _, decision in ipairs(decisions or {}) do
    if decision.action == "accept" and decision.block then
      accepted[#accepted + 1] = decision.block
    end
  end
  if #accepted == 0 then
    return nil
  end
  table.sort(accepted, function(a, b)
    return (a.start_line or math.huge) < (b.start_line or math.huge)
  end)
  local offset = 0
  for _, block in ipairs(accepted) do
    local start_line = (block.start_line or 1) + offset
    local end_line = (block.end_line or start_line) + offset
    out = replace_line_span(out, start_line, end_line, block.new_lines or {})
    offset = offset + #(block.new_lines or {}) - #(block.old_lines or {})
  end
  return out
end

function M._parked_dirty_explained_by_decisions(change, parked)
  if not (type(change) == "table" and type(parked) == "table" and type(parked.staged_text) == "string") then
    return false
  end
  local expected = lines_after_sealed_accepts(change.before or "", parked.sealed_decisions or {})
  if not expected then
    return false
  end
  local buffer_owned = lines_after_pending_withheld(buffer_lines(parked.staged_text), parked.blocks or {})
  if #buffer_owned ~= #expected then
    return false
  end
  for i, line in ipairs(buffer_owned) do
    if line ~= expected[i] then
      return false
    end
  end
  return true
end

local function open_review_buffer(change, preview)
  if preview then
    local bufnr = vim.api.nvim_create_buf(false, true)
    vim.bo[bufnr].buftype = "nofile"
    vim.bo[bufnr].bufhidden = "hide"
    vim.bo[bufnr].modifiable = true
    local lines = buffer_lines(change.before or "")
    if #lines == 0 then
      lines = { "" }
    end
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
    -- Left MODIFIABLE on purpose. M.open's insert_new_lines writes the diff
    -- blocks into this buffer next, and locking it here made the theme
    -- preview throw "Buffer is not 'modifiable'" every single time -- the
    -- sample before/after always differ, so the block list is never empty.
    -- The buffer is a scratch buffer nobody saves; there is nothing to guard.
    pcall(vim.api.nvim_buf_set_name, bufnr, "yana://diff-theme-preview")
    change.path = change.path or "yana://diff-theme-preview"
    change.rel = "diff-theme-preview"
    return bufnr, nil
  end

  -- ONE staging path for every review, shadow-apply and legacy alike (E9).
  -- Nothing below writes, creates, deletes, or reverts the real file: the
  -- review is composed in the buffer from the change set, and the only real
  -- write happens at accept in finish_session.
  --
  -- The path this replaced assumed cursor-agent had already written `after` to
  -- the real file and deliberately refused to revert it, because reverting
  -- taught the still-running agent its edit had been undone and it re-applied
  -- it forever. That premise died with E7: the agent now runs inside the
  -- overlay and never writes the real tree, so there is nothing on disk to
  -- reconcile against and nothing to revert. The one real write that premise
  -- justified -- creating an agent-created file on disk just to open its
  -- review -- is gone with it; a create is now reviewed against an empty base.
  local path = diff.abs_path(change.path)
  change.path = path
  -- Do NOT overwrite a rel the producer already set. diff.relpath is relative
  -- to nvim's CWD, but a shadow change set keys `rel` to the TURN WORKSPACE,
  -- which preview.workspace_for_turn routinely narrows to the directory of the
  -- file under edit. Overwriting it used to make the whole-tree base-hash
  -- lookup in shadow/apply.lua miss whenever cwd differed from the workspace,
  -- so base_hash fell back to the empty hash and every modify accept refused
  -- with "this file differs from the agent's starting copy". The fingerprint
  -- now rides on the change itself, so that lookup is gone — but rel still
  -- names the operation for the applier and the journal, and a cwd-relative
  -- one is still wrong. Only synthesize a rel when the producer supplied none.
  change.rel = change.rel or diff.relpath(path)

  -- THE TURN-START PAIR, captured at the FIRST open of this change and never
  -- again (issue-log row 113). `change.before` legitimately MOVES later: the
  -- save and reload handlers advance it with the file's fingerprint (see
  -- their own comments at the `change.before = on_disk` / `= disk_now`
  -- sites -- they are read as a pair with `base_hash`). A model captured
  -- lazily at REOPEN time is therefore the SAVED bytes, not the turn's, and
  -- the `hunk N` ordinals the register recorded no longer index it -- which
  -- is how a `:w` between two decisions made the reopen see "every hunk
  -- decided" and hand back nothing. Captured here it is the pair the review,
  -- and the register's labels, were actually built from.
  if
    change._retrace_model == nil
    and not change._retrace_reintegration
    and type(change.before) == "string"
    and type(change.after) == "string"
  then
    change._retrace_model = { before = change.before, after = change.after }
  end

  local existing = vim.fn.bufnr(path, false)

  -- RETRACE REINTEGRATION FAST PATH (FIX-UNDO lane, this session).
  -- `lua/yana/timeline/retrace.lua`'s `reintegrate` builds `change.after`
  -- from the CURRENT buffer's own bytes, precisely so the buffer it hands
  -- back needs no rewrite. The ordinary path below stages `change.before`
  -- into the buffer FIRST and patches it back to `target` with
  -- `insert_new_lines` afterwards -- two real `nvim_buf_set_lines` calls,
  -- each its own undo-tree entry, even when the net bytes end up exactly
  -- where they started. That is fine for a fresh agent turn (the operator
  -- has never seen this buffer's content before, so a staging boundary is
  -- information, not noise) but wrong here: the buffer already IS the
  -- reviewable state, and rewriting it anyway would insert a phantom
  -- undo/redo step into the operator's OWN buffer history purely as a side
  -- effect of `u` making a hunk decidable again. Measured 2026-08-21: it
  -- broke the undo-survives-a-reload row's case, which counts exact
  -- plain-`u` press counts against a closed review's LEFTOVER Neovim
  -- history -- the phantom step is real and REAL undo has to walk past it.
  -- So when the existing buffer already holds exactly `change.after`, this
  -- returns it AS-IS -- no reload, no stage, no `insert_new_lines` later in
  -- `M.open` (guarded there by the same `_retrace_reintegration` marker) --
  -- and `M.build_diff_blocks`'s own positions still line up, because
  -- `target` (below) never diverges from what is already on screen.
  if change._retrace_reintegration and existing > 0 and vim.api.nvim_buf_is_loaded(existing) then
    local cur = diff.buffer_text_normalized(existing)
    local target = change.after or ""
    -- `rewind_restore` parks `rec.open_text` (the watched proposal snapshot,
    -- which may include absorbed human edits) while `change.after` stays the
    -- raw agent turn. Native `<C-r>` after a floor `u` lands on the watched
    -- bytes, not necessarily on `change.after` (property seed 87008 step 35).
    if change._rewind_restored and type(change._parked_review) == "table" and type(change._parked_review.staged_text) == "string" then
      target = change._parked_review.staged_text
    end
    if diff.text_equal_snapshot(cur, target) then
      change.disk_at_open = diff.read_file_bytes(path)
      change.undo_pre_stage_seq = buf_undo_seq(existing)
      return existing, nil
    end
  end

  -- PARKED-ALREADY-STAGED FAST PATH (class fix, issue 7 / ruling 75's redo
  -- corruption row, r75_redo_paint_matches_proposal's `redo3-extra`).
  --
  -- The retrace fast path above only fires when THIS press's own mechanism
  -- (a cross-file undo reintegration) stamped `_retrace_reintegration`. An
  -- ORDINARY parked review -- the queue simply handing the file back after
  -- some OTHER file's decision closed it, never touched by any undo/redo --
  -- has the exact same property that fast path exists to protect: its
  -- buffer was never edited while parked, so it already holds precisely
  -- `change._parked_review.staged_text`. Falling through to the ordinary
  -- path below (`diff.reload_file` + `stage()`, then `M.open`'s own
  -- `insert_new_lines` + `set_lines(parked.staged_text)`) writes that SAME
  -- content back, sealing real, undo-tree-visible entries that are
  -- byte-identical to what was already there -- invisible to Yana's own
  -- decision/redo bookkeeping (they name no hunk, no register row), but
  -- REAL forward branches a later cross-file `u` can walk BEHIND (via its
  -- own `:undo <pre_seq>`, landing at an earlier, real decision boundary)
  -- and a subsequent native `:redo` fallback -- nothing left in Yana's own
  -- cross-file redo register, ruling #100's "a press Yana does nothing for
  -- must look exactly as if Yana were not installed" -- can then walk BACK
  -- INTO, landing on a stale intermediate state instead of reporting
  -- nothing to redo.
  --
  -- MEASURED: `r75_redo_paint_matches_proposal`'s `redo3-extra`.
  -- `diff.reload_file`'s own disk-reload state (raw pre-agent bytes, every
  -- hunk's proposal stripped -- disk never carries the agent's proposal at
  -- all, E7) sat as an orphaned child one step ahead of where the cross-file
  -- walk's own `:undo` had left the buffer, and a plain `<C-r>` landed on
  -- it, corrupting the paint to 0 painted rows against 1 pending line
  -- ("hunk 3 no longer matches the buffer -- its highlight is withdrawn").
  --
  -- `_parked_already_staged` is named SEPARATELY from `_retrace_reintegration`
  -- on purpose: it must skip only the restage writes (here, and mirrored in
  -- `M.open`'s own `insert_new_lines`/`set_lines(parked.staged_text)`), not
  -- the other retrace-specific behaviour that flag also gates (reviews_opened
  -- counting, `M._announce_open_failure`'s suppressed notice) -- this reopen
  -- is an ordinary queue advance, not a retrace event, and must keep looking
  -- like one everywhere except the phantom-write it shares the same fix with.
  if
    not change._retrace_reintegration
    and existing > 0
    and vim.api.nvim_buf_is_loaded(existing)
    and type(change._parked_review) == "table"
    and type(change._parked_review.staged_text) == "string"
  then
    local cur = diff.buffer_text_normalized(existing)
    if diff.text_equal_snapshot(cur, change._parked_review.staged_text) then
      -- Snapshot equality alone cannot separate Yana-owned park state from an
      -- outside-hunk human edit captured into the same park snapshot (P118).
      -- Discriminator is the buffer's modified bit after reject_block_at's
      -- truthful recompute (ruling 79): review-owned park leaves modified
      -- false (or dirty explained by sealed accepts); unrelated dirtiness
      -- keeps modified true and must fall through to the refusal below.
      -- Do NOT require cur == before — that breaks parked reopen with
      -- still-pending green hunks (r75 redo paint).
      local dirty = vim.bo[existing].modified
      if dirty
        and not M._parked_dirty_explained_by_decisions(change, change._parked_review)
      then
        -- fall through
      else
        change._parked_already_staged = true
        change.disk_at_open = diff.read_file_bytes(path)
        change.undo_pre_stage_seq = buf_undo_seq(existing)
        return existing, nil
      end
    end
  end

  local existing_modified = existing > 0
    and vim.api.nvim_buf_is_loaded(existing)
    and vim.bo[existing].modified
  if existing_modified then
    local parked = change._parked_review
    local parked_matches = parked
      and type(parked.staged_text) == "string"
      and diff.buffer_bytes_snapshot(existing) == parked.staged_text
    if parked_matches and M._parked_dirty_explained_by_decisions(change, parked) then
      existing_modified = false
    end
  end
  if existing_modified then
    -- The buffer holds unsaved human work that is not the turn-start content.
    -- Staging over it would destroy it, so refuse by name instead.
    --
    -- `modified` is trusted at face value here on purpose: the guard's real
    -- job is upstream, at every site that decides bytes on the operator's
    -- behalf (accept moves none; per-hunk reject in reject_block_at resets
    -- the flag it dirties -- see the comment there, MEASURED 2026-08-21,
    -- FIX-NAV lane) -- so that by the time a `]x`/`[x` park+reopen lands
    -- here, `modified` means exactly what this refusal says it means: bytes
    -- this review did not put there. Comparing against a second baseline
    -- `change._parked_review.staged_text` is the one exception: a parked
    -- review may contain sealed accept decisions, so its dirty bit can be
    -- expected review state rather than unrelated work. It is allowed only
    -- when the current buffer still exactly equals the bytes recorded at park
    -- time AND the buffer-owned bytes are explained by those sealed accepts.
    -- An outside-hunk human edit captured by the park snapshot is still
    -- unrelated work and must keep this refusal alive.
    local cur = diff.buffer_text_normalized(existing)
    if not diff.text_equal_snapshot(cur, change.before or "") then
      -- R1 + R2, issue-log row 113: this refusal is for a FRESH open, and a
      -- REOPEN is not one. Ask `M.reopen_from_register` whether the register
      -- already holds decisions for this file: if it does, the buffer's
      -- `modified` bit is yana's OWN staged text (accepts move no bytes,
      -- ruling 87) and the review's pair is re-derived from the register and
      -- the buffer, never from disk and never from this guard. Only a file
      -- with NO decisions recorded -- a genuinely fresh open over work the
      -- human did before the turn -- reaches the refusal.
      --
      -- STRUCTURAL, not an exception keyed on one text comparison: the
      -- discriminator IS R2's own definition of "fresh".
      local reopen_ws = nil
      if type(change.path) == "string" and type(change.rel) == "string"
        and #change.path > #change.rel + 1
        and change.path:sub(-#change.rel) == change.rel then
        reopen_ws = change.path:sub(1, #change.path - #change.rel - 1)
      end
      local pair = M.reopen_from_register(reopen_ws, change.rel, existing, nil)
      if pair then
        change.disk_at_open = diff.read_file_bytes(path)
        change.undo_pre_stage_seq = buf_undo_seq(existing)
        return existing, nil
      end
      return nil, "buffer has unsaved edits unrelated to this review"
    end
  end

  local function stage(bufnr, text)
    vim.fn.bufload(bufnr)
    -- Seal whatever undo block is still open on this buffer BEFORE the review
    -- writes its first byte into it. The `:edit!` two lines up
    -- (diff.reload_file) opens one and nothing closes it -- the main loop never
    -- idles between the reload and the staging -- so without this the reload,
    -- the staging and M.open's insert_new_lines all land in ONE undo block, and
    -- no undo seq can name the buffer as it was before the agent's proposal
    -- went in. Measured that way round first, twice: `U` returned the staged
    -- hunks instead of the file.
    break_undo_block(bufnr)
    -- The state the buffer is in BEFORE the agent's proposal goes into it. This
    -- is the only bookmark that names "the file as it was before any hunk
    -- appeared"; `undo_open_seq`, recorded later, names the review as it OPENED,
    -- which is one block further on and still holds every staged hunk. `U`
    -- walks to that one; an ABORT walks to this one.
    change.undo_pre_stage_seq = buf_undo_seq(bufnr)
    local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, buffer_lines(text or ""))
    if not ok then
      -- A target buffer the user (or a generated-file guard) has set
      -- 'nomodifiable' throws here. Report it as a named refusal instead: a raw
      -- "Buffer is not 'modifiable'" review_error re-fails deterministically on
      -- every retry and tells the user nothing about what to do.
      return nil, "cannot stage review in this buffer (" .. tostring(err) .. ")"
    end
    vim.bo[bufnr].modified = false
    return bufnr, nil
  end

  if change.kind == "delete" then
    if vim.fn.filereadable(path) ~= 1 then
      -- Already absent. Nothing to stage against and nothing to protect.
      change.disk_at_open = nil
      local bufnr = vim.fn.bufnr(path, true)
      return bufnr, nil
    end
    local disk_bytes, derr = diff.read_file_bytes(path)
    if disk_bytes == nil then
      return nil, derr or "could not read file for review"
    end
    if change.before ~= nil and not diff.text_equal_snapshot(disk_bytes, change.before) then
      return stale_refusal("file on disk changed since turn start", change.before, disk_bytes)
    end
    change.disk_at_open = disk_bytes
    local bufnr = vim.fn.bufnr(path, true)
    if not existing_modified then
      diff.reload_file(path, { force = true })
    end
    return stage(bufnr, change.before or "")
  end

  if change.after == nil then
    -- Three different causes used to emit ONE identical string, which is why
    -- this bug class survived days of work: "stale or externally modified" was
    -- printed for a deletion that never happened, for a payload with no
    -- after-content, and for genuine disk divergence alike.
    return nil, "agent payload carried no after-content for this edit (nothing to review)"
  end

  if change.before == nil then
    -- Agent-created file: reviewed against an empty base. It does not exist on
    -- disk and must not be created there until accept.
    if vim.fn.filereadable(path) == 1 then
      return nil,
        "file already exists on disk; the agent-created file has no empty base to review against",
        { reason = "stale_file" }
    end
    if vim.fn.getftype(path) ~= "" then
      return nil, "path exists but is not a regular file"
    end
    change.disk_at_open = nil
    change.disk_absent_at_open = true
    local bufnr = vim.fn.bufnr(path, true)
    return stage(bufnr, "")
  end

  if vim.fn.filereadable(path) ~= 1 then
    if vim.fn.getftype(path) ~= "" then
      return nil, "file exists but is not readable", { reason = "stale_file" }
    end
    return nil, "file missing on disk for review", { reason = "stale_file" }
  end
  local disk_bytes, derr = diff.read_file_bytes(path)
  if disk_bytes == nil then
    return nil, derr or "could not read file bytes from disk"
  end
  local disk_is_turn_start = diff.text_equal_snapshot(disk_bytes, change.before)
  -- Ruling 97: `U` requeues a transfer-regime file with disk left exactly
  -- where the human's own `:w` put it (the accepted bytes), never rewound --
  -- that disk state is the ruling's whole point, not drift, so reopening this
  -- one review must not refuse it. `_accept_composed_hash` is set ONLY by a
  -- transfer-regime accept (:2969/:5639), so this branch stays inert for
  -- every change that never went through one -- every other caller of this
  -- function keeps today's exact staleness check.
  local disk_is_accepted_save = not disk_is_turn_start
    and change._accept_composed_hash ~= nil
    and base_fingerprint(disk_bytes) == change._accept_composed_hash
  if not (disk_is_turn_start or disk_is_accepted_save) then
    return stale_refusal("file on disk changed since turn start", change.before, disk_bytes)
  end
  change.disk_at_open = disk_bytes
  local bufnr = vim.fn.bufnr(path, true)
  if not existing_modified then
    -- Sync Vim's recorded mtime with disk so no later manual :write raises the
    -- W12 changed-on-disk prompt.
    diff.reload_file(path, { force = true })
  end
  return stage(bufnr, change.before)
end

-- `line_delta` is how many lines the resolution actually added to (or removed
-- from) the buffer at this hunk. Reject used to assume `#old_lines -
-- #new_lines`, which is right only when the live range still held exactly the
-- agent's proposal; once the human's in-hunk text is preserved across the
-- restoration the count differs, and every later block's claimed row would be
-- off by it (render_check reads that row as extmark DRIFT).
local function remove_block(blocks, idx, use_new_lines, line_delta)
  local out = {}
  local delta = 0
  for i, block in ipairs(blocks) do
    if i == idx then
      if line_delta ~= nil then
        delta = line_delta
      elseif not use_new_lines then
        delta = #block.old_lines - #block.new_lines
      end
    else
      if i > idx then
        block.new_start_line = block.new_start_line + delta
        block.new_end_line = block.new_end_line + delta
      end
      table.insert(out, block)
    end
  end
  return out
end

local live_block_range

local function current_block(blocks, bufnr)
  -- No window showing the review buffer means no meaningful cursor: falling
  -- back to window 0 would resolve hunks against an unrelated buffer's cursor
  -- line. The hunk keymaps are buffer-local, so in real use this is non-nil.
  local win = win_for_buf(bufnr)
  if not win then
    return nil, nil
  end
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  for idx, block in ipairs(blocks) do
    local start_line, end_line = live_block_range(bufnr, block)
    if start_line then
      local eff_end = math.max(end_line, start_line)
      if cursor_line >= start_line and cursor_line <= eff_end then
        return block, idx
      end
    else
      local id = block.incoming_extmark_id
      if id then
        local ext = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, id, { details = true })
        if ext and ext[1] ~= nil then
          local anchor = ext[1] + 1
          if math.abs(cursor_line - anchor) <= 1 then
            return block, idx
          end
        end
      end
      local eff_end = math.max(block.new_end_line, block.new_start_line)
      if cursor_line >= block.new_start_line and cursor_line <= eff_end then
        return block, idx
      end
    end
  end
  return nil, nil
end

local function nav_start_line(bufnr, block)
  -- Navigation reads the SAME authority accept/reject read (live_block_range).
  -- `block.new_start_line` is computed when the diff is built and never moves,
  -- so once the human types a line above a hunk the two disagree and `]x`
  -- lands that many lines short. The stored integer is a last resort for an
  -- invalidated mark, and taking it is STATED, not silent.
  local start_line, end_line = live_block_range(bufnr, block)
  if start_line then
    return start_line, math.max(end_line, start_line)
  end
  local fallback = block.new_start_line
  if not block.nav_fallback_stated then
    block.nav_fallback_stated = true
    local said = string.format(
      "yana: hunk extmark invalidated -- navigation fell back to the stored line %s",
      tostring(fallback)
    )
    -- On screen, like every other refusal in this file, AND in the log so the
    -- statement outlives the message area. Once per block: navigation runs on
    -- keypresses and cursor moves, and a per-event warning would be noise.
    notify_one_line(said, vim.log.levels.WARN)
    log.write("WARN", said)
  end
  return fallback, math.max(block.new_end_line or fallback, fallback)
end

local function nearest_block(blocks, bufnr, direction)
  local win = win_for_buf(bufnr) or 0
  local cursor_line = vim.api.nvim_win_get_cursor(win)[1]
  if #blocks == 0 then
    return nil
  end

  local starts = {}
  for i, block in ipairs(blocks) do
    local start_line, eff_end = nav_start_line(bufnr, block)
    starts[i] = start_line
    if cursor_line >= start_line and cursor_line <= eff_end then
      local j = direction == "next" and (i % #blocks) + 1 or ((i - 2) % #blocks) + 1
      return blocks[j]
    end
  end

  local best_idx, best_dist = nil, nil
  for i, _ in ipairs(blocks) do
    local dist = direction == "next" and (starts[i] - cursor_line)
      or (cursor_line - starts[i])
    if direction == "next" and starts[i] > cursor_line then
      if best_dist == nil or dist < best_dist then
        best_dist, best_idx = dist, i
      end
    elseif direction == "prev" and starts[i] < cursor_line then
      if best_dist == nil or dist < best_dist then
        best_dist, best_idx = dist, i
      end
    end
  end
  if best_idx then
    return blocks[best_idx]
  end
  return direction == "next" and blocks[1] or blocks[#blocks]
end

local function land_on(path, bufnr, block)
  if path and not focus_buf(path, bufnr) then
    return false
  end
  if not block then
    return true
  end
  local win = win_for_buf(bufnr)
  if not win then
    return false
  end
  -- Clamp, and never throw. A pure-deletion hunk at the end of the file
  -- shrinks the buffer below new_start_line, and an unprotected set_cursor
  -- there ("Cursor position outside buffer") used to abort M.open AFTER it had
  -- installed the BufWriteCmd guard and keymaps -- orphaning a review nobody
  -- owned. Cursor placement is cosmetic; it must never decide whether a review
  -- session survives.
  local total = vim.api.nvim_buf_line_count(bufnr)
  local line = math.max(1, math.min(nav_start_line(bufnr, block), total))
  pcall(vim.api.nvim_win_set_cursor, win, { line, 0 })
  pcall(vim.api.nvim_win_call, win, function()
    vim.cmd("normal! zz")
  end)
  return true
end

local function insert_new_lines(bufnr, blocks)
  local offset = 0
  for _, block in ipairs(blocks) do
    local start_line = block.start_line + offset
    local end_line = block.end_line + offset
    vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, block.new_lines)
    offset = offset + #block.new_lines - #block.old_lines
  end
end

local function lines_equal(a, b)
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

live_block_range = function(bufnr, block)
  -- The AUTHORITY mark decides this range, never the paint mark. See the
  -- AUTH_NS comment at the top of the file: the paint mark's end deliberately
  -- sits at column 0 of the row AFTER the hunk, which is precisely where a
  -- human types when appending below the hunk, so reading it here would let
  -- reject/compose swallow the human's line.
  local row, end_row
  local auth_id = block.authority_extmark_id
  if auth_id then
    local ext = vim.api.nvim_buf_get_extmark_by_id(bufnr, AUTH_NS, auth_id, { details = true })
    if not ext or ext[1] == nil then
      return nil, nil, "hunk extmark invalidated"
    end
    local meta = ext[3]
    row = ext[1]
    -- Authority geometry is INCLUSIVE-by-encoding: end at (last_new_row, 0),
    -- so the 1-based last line is end_row + 1.
    end_row = ((meta and meta.end_row) or row) + 1
  else
    -- No authority mark: fall back to the paint mark's anchor row only, and
    -- derive the end from the block's own new-line count rather than from the
    -- paint mark's end. This path is reached only if highlight_blocks did not
    -- run for this block; it must not resurrect the unsafe reading.
    local id = block.incoming_extmark_id
    if not id then
      return nil, nil, "hunk extmark missing"
    end
    local ext = vim.api.nvim_buf_get_extmark_by_id(bufnr, NS, id, { details = true })
    if not ext or ext[1] == nil then
      return nil, nil, "hunk extmark invalidated"
    end
    row = ext[1]
    end_row = row + math.max(#block.new_lines, 1)
  end
  local start_line = row + 1
  local end_line = end_row
  if #block.new_lines == 0 then
    end_line = start_line - 1
  end
  if end_line < start_line - 1 then
    return nil, nil, "hunk invalidated: extmark range collapsed"
  end
  if #block.new_lines > 0 then
    if end_line < start_line then
      return nil, nil, "hunk invalidated: lines deleted"
    end
    local live = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    if #live == 0 then
      return nil, nil, "hunk invalidated: lines deleted"
    end
  end
  return start_line, end_line, nil
end

--- ------------------------------------------------------------------
--- RULING 72 -- what a human save is allowed to put on disk
--- ------------------------------------------------------------------
--- While hunks are pending, one buffer has two owners: the hunks are Yana's,
--- everything else is the human's (hunk-ownership module, rulings 71,
--- 72, 78). A save therefore writes the buffer with every PENDING hunk put
--- back the way disk has it -- an added line does not reach disk, a line the
--- hunk proposes to delete stays there. A DECIDED hunk already crossed owners
--- and is gone from `state.diff_blocks`, so it is not touched here.

--- The bytes a list of buffer lines becomes on disk, by exactly the rules
--- `diff.buffer_bytes_snapshot` applies (`diff.lua:562-583`): 'fileformat'
--- picks the EOL byte, 'endofline' decides the final one, 'bomb' prefixes the
--- BOM. A naive `table.concat(lines, "\n") .. "\n"` corrupts dos and noeol
--- files; `finish_session`'s `match_eol` exists because that bug class already
--- shipped once.
---
--- A buffer holding no real line is written as an EMPTY file, not as one
--- newline. Neovim cannot hold a zero-line buffer, so a whole-file deletion
--- hunk leaves the forced blank line behind; Vim's own `:write` writes that
--- buffer as zero bytes (measured), and this must agree with it or every such
--- save would append a phantom newline.
--- Defined on `M` rather than as a file-local: `M.open` is one function
--- away from LuaJIT's 60-upvalue ceiling, and two more file-locals referenced
--- from the BufWriteCmd closure inside it push it over.
function M._encode_buffer_lines(bufnr, lines)
  if #lines == 0 then
    return ""
  end
  local eol_byte
  local ff = vim.bo[bufnr].fileformat
  if ff == "dos" then
    eol_byte = "\r\n"
  elseif ff == "mac" then
    eol_byte = "\r"
  else
    eol_byte = "\n"
  end
  local body = table.concat(lines, eol_byte)
  if vim.bo[bufnr].endofline then
    body = body .. eol_byte
  end
  if vim.bo[bufnr].bomb then
    body = "\239\187\191" .. body
  end
  return body
end

--- The buffer's lines with every pending hunk's live range replaced by the
--- lines disk holds there (`block.old_lines`).
---
--- Position comes from `live_block_range` -- the AUTH_NS mark -- and never
--- from the paint mark, whose end deliberately sits on the row AFTER the hunk
--- (that reading is what made rejecting a hunk delete the human's line, N8a).
---
--- Every range is read against the UNMUTATED buffer, then the result is built
--- as a NEW list in ascending order. `cursor` is the offset accumulator in its
--- exact-by-construction form: it names the next unconsumed line of the source
--- list, so a hunk whose `old_lines` count differs from its live length cannot
--- shift the index of any later range -- the source list is never rewritten,
--- so there is no index left to shift. (The reject sweep runs last-hunk-first
--- for the opposite reason: it mutates the buffer in place.)
---
--- A pure deletion's live range is empty -- `(start_line, start_line - 1)`,
--- see `live_block_range` above -- so `old_lines` is inserted BEFORE
--- `start_line` and nothing is consumed.
---
--- A hunk whose range is no longer knowable ("hunk extmark invalidated",
--- "hunk invalidated: lines deleted"), and a hunk overlapping one already
--- taken, are LEFT AS BUFFER TEXT and counted for the caller's WARN. Neither
--- is a refused save: CORE requires that a human save is never blocked.
---
--- `range`, when given, is `{q1, q2}` -- an inclusive LIVE-buffer line range
--- (1-indexed) -- and restricts the OUTPUT to whatever falls in that slice,
--- the same way ruling 72 restricts `:w` to buffer-owned text. This is what
--- lets `:{range}w file` / `:{range}w >>file` (Vim's FileWriteCmd /
--- FileAppendCmd -- ruling 72/87, "saving a copy to another path" keeps
--- hunk ownership scoped to the requested range) compose only the slice
--- the human asked for, through
--- this SAME function, rather than a second one. A verbatim buffer line is
--- kept iff its own line number falls in the range. A pending hunk's
--- withheld replacement is indivisible -- there is no such thing as half a
--- withheld hunk -- so it is kept whenever the range touches ANY of the
--- hunk's live span (a pure-deletion hunk's empty span collapses to its
--- insertion point for this test). `range == nil` means "the whole buffer",
--- byte-identical to this function's pre-ranged behaviour.
---
--- Returns: composed lines, hunks actually withheld, first skip reason or nil,
--- number skipped.
function M._compose_buffer_owned_lines(bufnr, blocks, range)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  if #lines == 1 and lines[1] == "" then
    -- Vim's forced blank line is not a line of the file.
    lines = {}
  end
  local q1, q2
  if range then
    q1, q2 = range[1], range[2]
  end
  local ranges, skipped, first_reason = {}, 0, nil
  for _, block in ipairs(blocks or {}) do
    local start_line, end_line, range_err = live_block_range(bufnr, block)
    if start_line then
      ranges[#ranges + 1] = {
        s = math.max(1, math.min(start_line, #lines + 1)),
        e = math.min(end_line, #lines),
        old = block.old_lines or {},
      }
    else
      skipped = skipped + 1
      first_reason = first_reason or (range_err or "hunk invalidated")
    end
  end
  table.sort(ranges, function(a, b)
    if a.s ~= b.s then
      return a.s < b.s
    end
    return a.e < b.e
  end)
  local kept, reach = {}, 0
  for _, r in ipairs(ranges) do
    if r.s <= reach then
      skipped = skipped + 1
      first_reason = first_reason or "two pending hunks claim the same lines"
    else
      kept[#kept + 1] = r
      reach = math.max(reach, r.e)
    end
  end
  local function want_line(i)
    return not q1 or (i >= q1 and i <= q2)
  end
  local function want_hunk(r)
    if not q1 then
      return true
    end
    local eff_e = math.max(r.s, r.e)
    return r.s <= q2 and eff_e >= q1
  end
  local out, cursor = {}, 1
  for _, r in ipairs(kept) do
    for i = cursor, r.s - 1 do
      if want_line(i) then
        out[#out + 1] = lines[i]
      end
    end
    if want_hunk(r) then
      for _, line in ipairs(r.old) do
        out[#out + 1] = line
      end
    end
    cursor = math.max(cursor, r.e + 1)
  end
  for i = cursor, #lines do
    if want_line(i) then
      out[#out + 1] = lines[i]
    end
  end
  return out, #kept, first_reason, skipped
end

--- RULING 79 -- the `modified` flag follows the buffer's OWN half only.
---
--- True iff buffer-owned text differs from the bytes on disk. "Buffer-owned
--- text" is computed the exact same way `:w` decides what it is allowed to
--- write (`M._compose_buffer_owned_lines`, ruling 72): the buffer's lines
--- with every PENDING hunk's live range substituted by `block.old_lines`,
--- the bytes disk already holds there. That substitution never reads
--- `block.new_lines`, so a human edit absorbed into a pending hunk (decision
--- 57, `absorb_human_edits` refreshes `new_lines`, never `old_lines`) cannot
--- move this flag, however many hunks are pending -- ruling 80's re-test on
--- every edit lands on the same answer each time because the substitution is
--- re-read from the live buffer, not cached. Human text outside every
--- pending hunk passes through the substitution unchanged and is exactly
--- what can make this true.
---
--- `blocks` is the caller's current PENDING set (nil/empty means "none
--- pending here", e.g. after the buffer has been fully reset to turn-start
--- bytes) -- a block already decided (no live extmark) is harmlessly skipped
--- by `_compose_buffer_owned_lines` rather than substituted.
---
--- `path` with no readable disk bytes (new/unwritten file) yields
--- `modified = true`, matching Vim's own reading of a buffer with nothing on
--- disk yet.
function M._recompute_modified(bufnr, blocks, path)
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local composed = M._compose_buffer_owned_lines(bufnr, blocks or {})
  local composed_bytes = M._encode_buffer_lines(bufnr, composed)
  local on_disk = path and diff.read_file_bytes(path) or nil
  vim.bo[bufnr].modified = not (on_disk ~= nil and composed_bytes == on_disk)
end

-- Rejecting a hunk restores THE AGENT'S lines, and only those.
--
-- OPERATOR RULING 2026-08-21 (decision 57, autopilot decisions 2026-08-22):
-- a human edit landing inside a pending hunk's live range BECOMES PART OF THE
-- HUNK, indistinguishable from what the agent wrote -- `absorb_human_edits`
-- (this file, `attach_buffer_watch`) keeps `block.new_lines` in step with the
-- live range for exactly this reason. The block was one thing and the
-- operator said no to all of it: "the human's word goes with the hunk."
-- There is therefore nothing left to separate here -- `start_line`/`end_line`
-- name the live range this hunk owns, and rejecting it always restores
-- `old_lines` over that range, unconditionally.
--
-- RETIRED by this ruling (derivation 86): the three-way read against the live
-- buffer that used to isolate a human ADD/DELETE from `new_lines` and replay
-- it around the restored `old_lines`, and the two refusals that left an
-- unattributable in-hunk collision as BOTH versions kept with the review
-- still open ("the human rewrote the agent's own lines in this hunk" / "the
-- human's lines sit between the agent's own lines in this hunk"). Both were
-- reachable only through this function; every caller of the second return
-- value (finish_session's reject-all and reject_block_at's per-hunk reject)
-- now always sees it nil.
--
-- `bufnr`/`start_line`/`end_line` stay in the signature only because callers
-- pass them -- the nil-range behaviour they rely on elsewhere (a pure-deletion
-- hunk, `end_line < start_line`) is untouched by this function no longer
-- reading them.
local function reject_restoration(bufnr, block, start_line, end_line)
  local old_lines = block.old_lines or {}
  if end_line < start_line then
    return old_lines, nil
  end
  local live = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  local new_lines = block.new_lines or {}
  if #live <= #new_lines then
    return old_lines, nil
  end
  local remaining = {}
  for _, line in ipairs(new_lines) do
    remaining[line] = (remaining[line] or 0) + 1
  end
  local function standalone_human_line(line)
    if vim.tbl_contains(new_lines, line) then
      return false
    end
    for _, nl in ipairs(new_lines) do
      if #nl > 0 and line:sub(1, #nl) == nl and #line > #nl then
        return false
      end
    end
    return true
  end
  local human_inserts = {}
  local agent_seen = 0
  for _, line in ipairs(live) do
    if remaining[line] and remaining[line] > 0 then
      remaining[line] = remaining[line] - 1
      agent_seen = agent_seen + 1
    elseif standalone_human_line(line) then
      human_inserts[#human_inserts + 1] = { after = agent_seen, text = line }
    else
      agent_seen = agent_seen + 1
    end
  end
  if #human_inserts == 0 then
    return old_lines, nil
  end
  local out = vim.deepcopy(old_lines)
  for _, h in ipairs(human_inserts) do
    local pos = math.min(h.after + 1, #out + 1)
    table.insert(out, pos, h.text)
  end
  return out, nil
end

local function resolve_disk_unchanged(change)
  -- The delete branch used to refuse whenever the file was still on disk,
  -- because the agent was assumed to have unlinked it already. Since E9 the
  -- file is still there for the whole review -- the deletion happens at accept
  -- -- so the honest question is the same one every other kind asks: are the
  -- bytes captured at open still the bytes on disk?
  if change.disk_absent_at_open then
    -- An agent-created file, reviewed against an empty base. Nothing may have
    -- appeared at that path while the review was open.
    if vim.fn.filereadable(change.path) == 1 or vim.fn.getftype(change.path) ~= "" then
      return false, "file appeared on disk since review opened"
    end
    return true
  end
  if change.disk_at_open == nil then
    if change.kind == "delete" and vim.fn.filereadable(change.path) == 1 then
      -- Absent when the review opened, present now: someone else created it.
      return false, "file on disk changed since review opened"
    end
    return true
  end
  local ok, err = diff.disk_bytes_unchanged(change.path, change.disk_at_open)
  if not ok then
    return false, err
  end
  return true
end

-- Sensor: has the review buffer diverged from what this engine last staged?
--
-- It is NOT a blanket accept guard, and wiring it as one is wrong. Accepting a
-- modify saves the LIVE BUFFER (finish_session -> diff.save_buffer), so a human
-- who refines the agent's suggested line and then accepts has their own text
-- written -- nothing is discarded, and that refine-then-accept flow is the
-- point of an inline review (the ir_02 Oracle fixture asserts exactly it).
-- Refusing there would destroy a legitimate workflow to prevent a loss that
-- does not happen.
--
-- It is used only where accept does NOT compose from the buffer and would
-- therefore discard buffer text the human typed:
--   * a delete accept, which unlinks the file and never reads the buffer;
--   * accept_everything's QUEUED files, which are written from the stored
--     change.after because they have no staged review yet (see buffer_clash).
local function staged_snapshot_unchanged(state)
  if not state.staged_text then
    return true
  end
  local now = diff.buffer_bytes_snapshot(state.bufnr)
  if now == nil then
    return false
  end
  return now == state.staged_text
end

local function ranges_overlap(a_start, a_count, b_start, b_count)
  local a_end = a_count > 0 and (a_start + a_count - 1) or a_start
  local b_end = b_count > 0 and (b_start + b_count - 1) or b_start
  return a_start <= b_end and b_start <= a_end
end

local function disk_change_touches_review_hunk(disk_hunks, blocks)
  for _, hunk in ipairs(disk_hunks) do
    local start_a, count_a = hunk[1], hunk[2]
    local disk_start = count_a > 0 and start_a or (start_a + 1)
    local disk_count = count_a > 0 and count_a or 1
    for _, block in ipairs(blocks) do
      local block_start = block.start_line
      local block_count = math.max(1, block.end_line - block.start_line + 1)
      if ranges_overlap(disk_start, disk_count, block_start, block_count) then
        return true
      end
    end
  end
  return false
end

local function line_delta_before(disk_hunks, base_line)
  local delta = 0
  for _, hunk in ipairs(disk_hunks) do
    local start_a, count_a, _, count_b = unpack(hunk)
    local old_end = count_a > 0 and (start_a + count_a - 1) or start_a
    if old_end < base_line then
      delta = delta + count_b - count_a
    end
  end
  return delta
end

local function apply_review_blocks_to_reloaded_disk(base, disk_now, blocks)
  local base_text = base or ""
  local disk_text = disk_now or ""
  local disk_hunks = vim.diff(base_text, disk_text, {
    algorithm = "histogram",
    result_type = "indices",
    ctxlen = 0,
  }) or {}

  if disk_change_touches_review_hunk(disk_hunks, blocks) then
    return nil, "conflict: file changed on disk inside a reviewed hunk"
  end

  local lines = buffer_lines(disk_text)
  local applied_delta = 0
  for _, block in ipairs(blocks) do
    local relocated = block.start_line + line_delta_before(disk_hunks, block.start_line) + applied_delta
    relocated = math.max(1, relocated)
    local old_count = #block.old_lines
    local replacement = vim.deepcopy(block.new_lines)
    if old_count > 0 and relocated + old_count - 1 > #lines then
      return nil, "conflict: reviewed hunk could not be relocated after reload"
    end
    for _ = 1, old_count do
      table.remove(lines, relocated)
    end
    for i = #replacement, 1, -1 do
      table.insert(lines, relocated, replacement[i])
    end
    applied_delta = applied_delta + #replacement - old_count
  end

  return table.concat(lines, "\n") .. (disk_text:sub(-1) == "\n" and "\n" or "")
end

local function capture_live_authority_ranges(bufnr, blocks)
  local out = {}
  for _, block in ipairs(blocks) do
    local start_line, end_line = block.new_start_line, block.new_end_line
    if #block.new_lines == 0 then
      end_line = start_line - 1
    end
    if block.authority_extmark_id then
      local sl, el, err = live_block_range(bufnr, block)
      if sl and el and not err then
        start_line, end_line = sl, el
      end
    end
    out[block] = { start_line = start_line, end_line = end_line }
  end
  return out
end

--- Within the live authority range, paint only rows whose text is still one of
--- the hunk's own `new_lines` (mark-derived position, multiset match — no
--- forward text search). Interior human inserts are gaps between spans.
local function paint_spans_for_block(bufnr, block, start_line, end_line)
  if #block.new_lines == 0 then
    return {}
  end
  if end_line < start_line then
    return {}
  end
  local remaining = {}
  for _, want in ipairs(block.new_lines) do
    remaining[want] = (remaining[want] or 0) + 1
  end
  local spans = {}
  for r = start_line, end_line do
    local line = (vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false) or {})[1]
    if remaining[line] and remaining[line] > 0 then
      remaining[line] = remaining[line] - 1
      local last = spans[#spans]
      if last and last.last + 1 == r then
        last.last = r
      else
        spans[#spans + 1] = { first = r, last = r }
      end
    end
  end
  return spans
end

-- F1 (operator report + screenshot, 2026-08-19): the paint may never claim a
-- row the product cannot PROVE is the agent's.
--
-- What this replaces. When `paint_spans_for_block` located none of the hunk's
-- `new_lines`, this function used to fall back to painting the ENTIRE authority
-- range, and it emitted one continuous incoming extmark from the first matched
-- row to the last with `Normal` masks over the gaps. Undo supplies exactly that
-- mismatch: it moves or removes the agent's text while the authority mark still
-- spans those rows, so the fallback painted whatever code now occupied them.
-- Measured in the wild as imports, blank lines and class/def lines shown green.
--
-- Why that is a correctness defect and not decoration. Green means "the agent
-- proposes this line", and the operator presses accept against what they can
-- see. Painting rows the product cannot attribute to the agent misrepresents
-- what is being consented to. The earlier reading of this class as "cosmetic"
-- was made when the only known trigger was typing inside a hunk, where the
-- operation still targeted the right lines; undo makes the same wrong paint
-- reach text the operator never looked at.
--
-- What it does now. Paint only the matched spans, with the rows between them
-- masked back to Normal, so a row the product cannot attribute to the agent is
-- never green. When nothing matches at all, paint NOTHING for that
-- block and report it: a hunk whose content cannot be found is a hunk whose
-- position is unknown, and showing an unknown position is worse than showing
-- none. `authority_lost` is set so callers can refuse to act on it, and the
-- notice fires once per block per review rather than on every repaint.
local function set_incoming_paint(bufnr, block, start_line, end_line, index)
  block.incoming_extmark_id = nil
  block.incoming_extmark_ids = nil
  -- REC-PLANT seam (`shift_incoming_rows = {block = k, delta = d}`, default
  -- off, see FAULT above): move ONLY hunk k's incoming extmark rows by `d`.
  -- The spans are still MATCHED at the hunk's true rows above/below, the
  -- deleted virt_lines stay put, `diff_blocks` stays put and no byte moves --
  -- so the green band paints where the hunk is not, which is the one thing a
  -- cold video read-back has to be able to catch and has never been given a
  -- deliberate instance of.
  local shift = (FAULT.shift_incoming_rows and FAULT.shift_incoming_rows.block == index and FAULT.shift_incoming_rows.delta)
    or 0
  if #block.new_lines == 0 then
    block.authority_lost = nil
    block.incoming_extmark_id = vim.api.nvim_buf_set_extmark(
      bufnr,
      NS,
      math.min(math.max(start_line - 1 + shift, 0), vim.api.nvim_buf_line_count(bufnr) - 1),
      0,
      {
        hl_group = EXT_HL.incoming,
        hl_eol = true,
        hl_mode = "combine",
        priority = INCOMING_PRIO,
        end_row = math.min(math.max(start_line - 1 + shift, 0), vim.api.nvim_buf_line_count(bufnr) - 1),
        right_gravity = false,
        end_right_gravity = true,
      }
    )
    return
  end
  local paint_spans = paint_spans_for_block(bufnr, block, start_line, end_line)
  if #paint_spans == 0 then
    -- No fallback. Say it once, paint nothing, and mark the block.
    if not block.authority_lost then
      block.authority_lost = true
      local said = "yana: hunk "
        .. tostring(block.model_index or "?")
        .. " no longer matches the buffer — its highlight is withdrawn until it is resolved"
      -- The paint is now recomputed from `on_lines`, which runs in fast
      -- context where `vim.notify` is forbidden. Extmark work is allowed there
      -- and is the whole point of repainting synchronously, so only the
      -- talking is deferred.
      if vim.in_fast_event() then
        vim.schedule(function()
          notify_one_line(said, vim.log.levels.WARN)
        end)
      else
        notify_one_line(said, vim.log.levels.WARN)
      end
    end
    return
  end
  block.authority_lost = nil
  -- ONE INCOMING EXTMARK PER MATCHED SPAN, which is what this module's prose
  -- has specified all along: "the paint becomes several extmarks over one hunk
  -- rather than one ... the gap is exactly the text Yana is not claiming."
  --
  -- What this replaces, and why the replacement was not optional. The shipped
  -- form emitted ONE incoming mark spanning first..last and masked the rows in
  -- between with `Normal` at a higher priority. That is a rendering trick, not
  -- ownership: the human's row was still INSIDE an extmark whose highlight
  -- group says "the agent proposes this", so anything reading ownership from
  -- the marks — a screen reader, an export, a test, a future feature — saw the
  -- human's line as the agent's. The property runner's shrunk trace is one
  -- operation long: a single `replace_inside` left the edited row semantically
  -- incoming (got [2,3,5,7,8], want [3,5,7,8]). Masking a lie is still a lie.
  --
  -- Contiguous spans are the ordinary case and produce exactly one mark, so
  -- nothing changes for a review nobody has typed into.
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  local ids = {}
  for _, span in ipairs(paint_spans) do
    ids[#ids + 1] = vim.api.nvim_buf_set_extmark(
      bufnr,
      NS,
      math.min(math.max(span.first - 1 + shift, 0), line_count - 1),
      0,
      {
        hl_group = EXT_HL.incoming,
        hl_eol = true,
        hl_mode = "combine",
        priority = INCOMING_PRIO,
        end_row = math.min(math.max(span.last + shift, 0), line_count),
        end_col = 0,
        -- Paint follows the agent-owned span when a human inserts exactly at
        -- either boundary. Composition authority is the separate AUTH_NS mark.
        right_gravity = true,
        end_right_gravity = false,
      }
    )
  end
  -- Every reader that wants the whole hunk reads the list; the single-id field
  -- stays the FIRST span, which is the hunk's head and what navigation and the
  -- existing extent checks ask for.
  block.incoming_extmark_ids = ids
  block.incoming_extmark_id = ids[1]
end

local function highlight_blocks(bufnr, blocks)
  local live = capture_live_authority_ranges(bufnr, blocks)
  -- Forget every id BEFORE the namespaces go, and after the live ranges have
  -- been captured from them. Clearing a namespace frees its ids for REISSUE,
  -- so a block still holding an old number does not read as invalidated if the
  -- rebuild below stops part-way -- it reads as whatever hunk later inherited
  -- the number. Nil ids degrade honestly instead: navigation states "hunk
  -- extmark missing" and falls back.
  for _, block in ipairs(blocks) do
    block.incoming_extmark_id = nil
    block.delete_extmark_id = nil
    block.authority_extmark_id = nil
  end
  -- REC-PLANT seam (`sticky_paint`, default off, see FAULT above): skipping
  -- this wholesale clear leaves the previous repaint's marks behind, so hunk
  -- colour survives a decision instead of being rebuilt from the live blocks.
  if not FAULT.sticky_paint then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  end
  vim.api.nvim_buf_clear_namespace(bufnr, AUTH_NS, 0, -1)
  local max_col = vim.o.columns
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  -- The index is the hunk's ordinal in this review, which is what the plant
  -- menu names when it asks for a shifted band on hunk k (see FAULT above).
  for block_index, block in ipairs(blocks) do
    local range = live[block]
    local start_line = range.start_line
    local end_line_1 = range.end_line
    local end_row_0 = end_line_1 - 1
    local deleted_virt = vim
      .iter(block.old_lines)
      :map(function(line)
        return { { line .. string.rep(" ", math.max(0, max_col - #line)), EXT_HL.deleted } }
      end)
      :totable()
    local deleted_above = #block.new_lines > 0 or start_line == 1
    local deleted_row = deleted_above and (start_line - 1) or (end_line_1 - 1)
    -- INVARIANT: every row this function hands to nvim_buf_set_extmark is
    -- clamped to the CURRENT buffer's bounds -- `start_line`/`end_line_1`
    -- come from `live[block]`, which falls back to `block.new_start_line`/
    -- `new_end_line` whenever a block has no authority_extmark_id (see
    -- capture_live_authority_ranges above). Those fallback fields are only
    -- ever advanced by absorb_human_edits' own bookkeeping and can go stale
    -- the instant the buffer is replaced wholesale out from under them (an
    -- external rewrite reloaded via `:checktime`/autoread fires this
    -- function's caller, `render_blocks`, from the buffer-watch's on_lines
    -- callback BEFORE the reload's own conflict handler has had a chance to
    -- tear the stale review down -- a scheduling race, not a positional
    -- one). The position argument below was already clamped; `end_row` was
    -- not, so a stale deleted_row past the new, smaller buffer threw
    -- "Invalid 'end_row': out of range" and the traceback aborted the
    -- repaint mid-block. Clamping both ends of the same call the same way
    -- makes the extmark call itself total over any row math this module can
    -- produce, however stale -- no code path needs to reason about the
    -- staleness case separately.
    local deleted_row_clamped = math.min(math.max(deleted_row, 0), line_count - 1)
    block.delete_extmark_id = vim.api.nvim_buf_set_extmark(
      bufnr,
      NS,
      deleted_row_clamped,
      0,
      {
        virt_lines = deleted_virt,
        virt_lines_above = deleted_above,
        hl_eol = true,
        hl_mode = "combine",
        end_row = deleted_row_clamped,
        right_gravity = false,
        end_right_gravity = true,
      }
    )
    set_incoming_paint(bufnr, block, start_line, end_line_1, block_index)

    -- The position/composition authority. Anchored on the live range, ending ONE
    -- ROW EARLIER than the paint span's exclusive-next-row encoding.
    local auth_end = math.max(end_row_0, start_line - 1)
    block.authority_extmark_id = vim.api.nvim_buf_set_extmark(
      bufnr,
      AUTH_NS,
      math.min(math.max(start_line - 1, 0), line_count - 1),
      0,
      {
        end_row = math.min(math.max(auth_end, 0), line_count - 1),
        end_col = 0,
        right_gravity = false,
        end_right_gravity = true,
      }
    )
  end
end

----------------------------------------------------------------------
-- rung-1 invariant capture (logging only — never changes control flow)
----------------------------------------------------------------------

-- The review engine sees changes, not panels, so every record it makes
-- correlates through the change's own stamps. `panel_id`/`turn_gen` are set by
-- ui.lua on both producers (report-derived and overlay-derived); a change that
-- carries neither lands in a synthetic ledger rather than being dropped.
local function change_ledger(change, opts)
  local panel_id = (change and change.panel_id)
    or (opts and opts.review_owner and opts.review_owner.panel_id)
    or 0
  return ledger.ensure(panel_id, (change and change.turn_gen) or 0)
end


-- The review target, in one place: an agent-created file has no trailing
-- newline of its own to reconcile, and the model must be derived from exactly
-- the same pair the blocks were built from.
local function model_target(change)
  local target = change.after or ""
  if change.before == nil then
    target = target:gsub("\n$", "")
  end
  return target
end

-- ------------------------------------------------------------------
-- THE CHANGE MODEL — and why it is not built by M.build_diff_blocks
-- ------------------------------------------------------------------
-- This model is the second opinion the rung-1 model-extent check measures
-- decoration against. Its whole value is INDEPENDENCE: it existed because
-- comparing painted rows against the blocks' own new-line count agrees with
-- itself when the intended range is short.
--
-- The first version of it called M.build_diff_blocks a second time. That is
-- not a second opinion, it is the same opinion asked twice: a regression in
-- build_diff_blocks that drops a trailing blank new line, merges two hunks or
-- undercounts one moves BOTH sides by the same amount and the check reports
-- healthy. The state invariant is enforced below.
--
-- The model is now derived from the change's own DIFF TEXT, parsed by
-- `parse_unified_runs` below. Sources, most independent first:
--
--   payload_diff     `change.diff` — for a single report-derived edit this is
--                    the AGENT's own `diffString`, produced by cursor-agent.
--                    Nothing in this repository generated it.
--   payload_create   `change.before == nil`. No diff needed and none consulted:
--                    every line of the new content is a new line, one hunk.
--   synthesized_diff `diff.synthesize_diff(before, target)` when the change
--                    carries no diff text. Weaker: it is still `vim.diff`. But
--                    it is a DIFFERENT call (result_type "unified", ctxlen 3,
--                    default algorithm) in a different module, and it is
--                    re-derived from the payload strings rather than from the
--                    block list, so a build_diff_blocks regression does not
--                    move it. The residual shared dependency is xdiff itself.
--   recomposed_diff  the same, for the reload/compose path, whose payload no
--                    longer describes what is on screen.
--
-- Join: the payload's runs and the builder's blocks are two independent
-- groupings of the same edit and need not be 1:1. `stamp_model_index` joins
-- them ONCE, by first-new-line, while both still speak the same coordinates,
-- and refuses to guess: a block with no run at its first new line, or a block
-- that swallows a second run, gets no model_index and render_check records
-- `model_unavailable` for it rather than a fabricated disagreement.

--- Parse unified diff text into maximal contiguous CHANGE RUNS (the ctxlen-0
--- grouping), with each run's first line in the NEW file. Returns nil on
--- anything it does not fully understand — a half-parsed model is worse than
--- none, because it would be reported as a real disagreement.
local function parse_unified_runs(diff_text)
  if type(diff_text) ~= "string" or diff_text == "" then
    return nil
  end
  local runs, open, new_ln = {}, nil, nil
  local function close()
    if open then
      open.new_end_line = open.new_start_line + open.new_count - 1
      runs[#runs + 1] = open
      open = nil
    end
  end
  for _, line in ipairs(vim.split(diff_text, "\n", { plain = true })) do
    local hdr = line:match("^@@%s+%-%d+[,%d]*%s+%+(%d+)")
    if hdr then
      close()
      new_ln = tonumber(hdr)
    elseif new_ln == nil then
      -- Preamble: "diff --git", "--- a/x", "+++ b/x", "index ...". Skipped
      -- wholesale, which is why the "+"/"-" branches below cannot mistake a
      -- file header for a content line.
      _ = line
    else
      local c = line:sub(1, 1)
      if c == "+" then
        open = open or { new_start_line = new_ln, new_count = 0, old_count = 0 }
        open.new_count = open.new_count + 1
        new_ln = new_ln + 1
      elseif c == "-" then
        -- xdiff emits the removed side of a run first, so the run's first NEW
        -- line is wherever the cursor stands when the run opens.
        open = open or { new_start_line = new_ln, new_count = 0, old_count = 0 }
        open.old_count = open.old_count + 1
      elseif c == " " or line == "" then
        close()
        new_ln = new_ln + 1
      elseif c == "\\" then
        -- "\ No newline at end of file" — a note about the previous line, not
        -- a line of its own.
        _ = line
      else
        return nil
      end
    end
  end
  close()
  if new_ln == nil then
    return nil
  end
  for i, r in ipairs(runs) do
    r.index = i
  end
  return runs
end

--- The change model and the name of where it came from.
local function payload_model(change, target)
  if change and change.before == nil then
    local n = #split_lines(target or "")
    local out = {}
    if n > 0 then
      out[1] = { index = 1, old_count = 0, new_count = n, new_start_line = 1, new_end_line = n }
    end
    return out, "payload_create"
  end
  local runs = change and parse_unified_runs(change.diff)
  if runs then
    return runs, "payload_diff"
  end
  local ok, synth = pcall(diff.synthesize_diff, (change and change.before) or "", target or "", change and change.path)
  if ok then
    runs = parse_unified_runs(synth)
    if runs then
      return runs, "synthesized_diff"
    end
  end
  return nil, "model_unavailable"
end

--- Same derivation for a pair that no payload describes (the reload/compose
--- rebuild). Named separately so the ledger never claims a payload it did not
--- read.
local function recomposed_model(base, composed, path)
  local ok, synth = pcall(diff.synthesize_diff, base or "", composed or "", path)
  if ok then
    local runs = parse_unified_runs(synth)
    if runs then
      return runs, "recomposed_diff"
    end
  end
  return nil, "model_unavailable"
end

-- Blocks are the mutable bookkeeping; the model is fixed. `model_index` is the
-- join between them and survives remove_block, which reindexes the list AND
-- shifts every later block's new_start_line — which is exactly why the join is
-- computed once here, on freshly built blocks, and never re-derived later.
local function stamp_model_index(blocks, model)
  local by_start = {}
  if model then
    for i, r in ipairs(model) do
      if r.new_start_line then
        by_start[r.new_start_line] = i
      end
    end
  end
  for _, b in ipairs(blocks) do
    local new_count = #(b.new_lines or {})
    if model == nil then
      b.model_index, b.model_join = nil, "model_unavailable"
    elseif new_count == 0 then
      -- A pure deletion paints no rows. There is nothing for the extent check
      -- to compare and no run to join to; this is not a failure to model.
      b.model_index, b.model_join = nil, "no_new_lines"
    else
      local mi = by_start[b.new_start_line]
      if not mi then
        b.model_index, b.model_join = nil, "no_payload_run_at_first_new_line"
      else
        -- A block wider than the payload's run is what 'scrolloff' context
        -- merging produces: build_diff_blocks passes scrolloff as ctxlen, so
        -- vim.diff fuses runs that sit within the context window and reports
        -- ONE hunk spanning from the first changed line to the last — the
        -- unchanged context lines BETWEEN the runs included, the leading and
        -- trailing context excluded (measured: at ctxlen 3 two single-line
        -- changes at new lines 2 and 9 come back as {2,8,2,8}).
        --
        -- N16: that is a wider model hunk, not an absent one. The block's new
        -- side runs from model run `mi`'s first new line to the LAST spanned
        -- run's last new line, so the expected new-line count is derivable from
        -- the model alone — it is the sum of the spanned runs' new lines plus
        -- the context lines the merge swallowed, which is exactly that span.
        -- Deriving it keeps the extent check live at scrolloff > 0 instead of
        -- surrendering the review to a false `model_unavailable`. It is still
        -- the MODEL speaking: nothing here is read off the block's own counts,
        -- so a builder regression that mis-sized the block still disagrees.
        local last = b.new_start_line + new_count - 1
        local mj = mi
        while
          model[mj + 1]
          and model[mj + 1].new_start_line
          and model[mj + 1].new_start_line > b.new_start_line
          and model[mj + 1].new_start_line <= last
        do
          mj = mj + 1
        end
        -- A run that starts inside the block but is not in the consecutive
        -- mi..mj walk means the runs are not ordered the way this join assumes,
        -- and a span derived from a set we did not fully account for would be a
        -- guess. Refuse — `model_unavailable` stays reachable for the cases
        -- where the model genuinely cannot speak for the block.
        local accounted = true
        for s, j in pairs(by_start) do
          if s > b.new_start_line and s <= last and (j < mi or j > mj) then
            accounted = false
            break
          end
        end
        local span_end = model[mj] and model[mj].new_end_line
        if not accounted then
          b.model_index, b.model_join = nil, "block_spans_multiple_payload_runs"
        elseif mj == mi then
          b.model_index, b.model_join = mi, "payload_run"
        elseif span_end == nil or span_end < b.new_start_line then
          b.model_index, b.model_join = nil, "payload_run_span_unbounded"
        else
          b.model_index, b.model_join = mi, "payload_run_span"
          b.model_span_last = mj
          b.model_span_new_count = span_end - model[mi].new_start_line + 1
        end
      end
    end
  end
  return blocks
end

--- Run rung 1 and RECORD. Every path into this is wrapped so a defect in the
--- check can never reach the render it observes: the invariant capture's whole
--- licence is that it cannot intervene.
local function render_invariant(desc)
  -- ONE pcall around the whole capture, recording included. A defect in the
  -- observer must not reach the render it observes, and that guarantee has to
  -- cover the record-keeping as much as the check itself.
  local ok, result = pcall(function()
    local res = render_check.run({
      site = desc.site,
      bufnr = desc.bufnr,
      blocks = desc.blocks,
      model = desc.model,
      model_source = desc.model_source,
      ns = NS,
      hint_ns = HINT_NS,
      ext_hl = EXT_HL,
      palette = PALETTE,
      change_id = desc.change and desc.change.id or nil,
      rel = desc.change and (desc.change.rel or desc.change.path) or nil,
    })
    ledger.record_render_check(change_ledger(desc.change, desc.opts), res)
    local carrier = desc.change
    if not res.ok and carrier then
      -- One record per distinct defect, capped per change. The signature names
      -- WHAT is wrong, not when, so forty re-renders of one unchanged defect
      -- write one record instead of forty.
      local warns = carrier._render_check_warns or 0
      if carrier._render_check_sig ~= res.signature and warns < MAX_RENDER_WARNS then
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

--- One operator review action. `actor = "user"` distinguishes these from the
--- system refusals recorded elsewhere with the same schema — the corpus showed
--- the two being read as one, which made review churn look like indecision.
local function record_decision(state, action, fields)
  local change = state and state.change
  local d = fields or {}
  d.action = action
  d.actor = "user"
  -- Where the buffer's undo tree stood when this decision was taken. The
  -- decision stack reads it back to answer one question: is the newest thing
  -- in the tree this decision, or something the human did after it? An
  -- integer, never bytes.
  d.undo_seq = buf_undo_seq(state and state.bufnr)
  d.change_id = change and change.id or nil
  d.rel = change and (change.rel or change.path) or nil
  ledger.record_decision(change_ledger(change, state and state.opts), d)
  -- AND DURABLY (issue log row 46). The ledger above is an in-memory table that
  -- dies with the process, so a LIVE review left no trace of any decision at
  -- all: the lifecycle log held review.open/park/settle, the turn ledger held
  -- agent-stream kinds, and nothing anywhere said whether `ct`, `co`, `ca`,
  -- `cb` or `cA` had been pressed or what it covered. The headless rows read
  -- the in-memory list and so never saw the gap. Emitted HERE, at the one
  -- funnel every operator decision already passes through, so the keymap and
  -- the `M._test`/seam callers cannot diverge: one row per decision, naming the
  -- action, the file and -- for a per-hunk decision -- the hunk.
  --
  -- `lifecycle_later` (vim.schedule), exactly like review.open/park/settle:
  -- the durable append fsyncs, and a decision key must not pay for it inline.
  log.lifecycle_later("review.decision", {
    turn_id = change and (change.turn_id or change.turn_gen),
    generation = change and change.turn_gen,
    action = action,
    actor = d.actor,
    path = d.rel,
    change_id = d.change_id,
    hunk = d.hunk,
    model_index = d.model_index,
    hunks_remaining = d.hunks_remaining,
    reason = d.reason,
  })
  return d
end

--- highlight_blocks + the invariant capture, in that order. The capture reads
--- the state the render just produced; it returns whatever it likes and the
--- caller ignores it.
local function render_blocks(bufnr, blocks, desc)
  highlight_blocks(bufnr, blocks)
  desc = desc or {}
  desc.bufnr = bufnr
  desc.blocks = blocks
  render_invariant(desc)
end

-- Panels register here to be told when review state changed — opened, aborted,
-- refused, resolved, queue advanced. Without this the panel can only repaint at
-- the edges it happens to drive itself, so a change that was "queued" when its
-- block was written still SAYS queued for the whole time its review is open
-- (and a review aborted after the claim was stamped still says "open"). Fired
-- AFTER `active` is updated, so an observer always reads settled state.
local observers = {}

function M.on_state_change(fn)
  observers[#observers + 1] = fn
  return function()
    for i, f in ipairs(observers) do
      if f == fn then
        table.remove(observers, i)
        return
      end
    end
  end
end

-- Observers must be READ-ONLY with respect to this engine: they run mid-fan-
-- out and, on the M.open path, before the session is fully built, so calling
-- back into resolve_change/focus_active would reenter a half-constructed
-- review. Iterate a snapshot so an observer that unsubscribes itself here
-- cannot make the walk skip the next one.
local function announce_state()
  local snapshot = { unpack(observers) }
  for _, fn in ipairs(snapshot) do
    -- An observer is panel code; a throw here must not break the engine, for
    -- the same reason notify_owner exists.
    pcall(fn)
  end
end

-- R8: `YanaReviewSettled`, a `User` autocmd fired exactly when a
-- review-state transition has FULLY applied -- paint, extmarks and the
-- decision register all consistent for the buffer named in `data.buf`.
-- Replaces 13 rows' fixed-delay "nothing happened" waits (issue 54 bucket
-- (b)) with a positive signal a test (or a real integration) can
-- `autocmd User YanaReviewSettled` on instead of guessing a timeout.
--
-- NOT a single pre-existing funnel: `announce_state()` above looks like the
-- one function every transition passes through, but it is not -- a per-hunk
-- accept/reject that leaves the review open (`accept_block_at`/
-- `reject_block_at`) never calls it; only a FULL close does (`finish_session`
-- and its three tails). Verified by reading every call site (2026-08-26).
-- So this is the documented fallback: one shared helper, called at each
-- transition's own tail, always strictly after that transition's own
-- `render_blocks`/`render_invariant` call -- never before.
--
-- `bufnr`/`turn` are read back off `data` by `wait_settled`
-- (tests/headless/lib/settled.lua) so a caller can filter to the exact
-- buffer/turn it just drove, and `reason` names WHICH transition settled
-- (`"open"`, `"accept_hunk"`, `"reject_hunk"`, `"accept_file"`,
-- `"reject_file"`, `"abort"`, `"undo_decision"`, `"native_undo"`,
-- `"redo_decision"`, `"native_redo"`, `"reload"`; that is the full list,
-- mirrored in `:help yana-events`). `pcall`-guarded like `announce_state`:
-- a throwing `autocmd User`
-- handler is the LISTENER's bug, and must not break the engine emitting it.
--
-- Defined as `M._emit_review_settled`, not a bare local: `M.open` (the
-- function every hunk/undo/redo/reload closure below is nested inside) is
-- already at Lua's 60-upvalue ceiling -- `M` itself is already one of its
-- upvalues (`M._test`, `M.cleanup`, `M.build_diff_blocks`, ... are called
-- from inside it throughout), so reaching this function as an `M` FIELD
-- adds zero new upvalues to every nested closure that calls it. A bare
-- local here reds `M.open` at load time: measured directly (the first
-- version of this change did exactly that --
-- "function at line 6339 has more than 60 upvalues").
function M._emit_review_settled(bufnr, turn, reason)
  pcall(vim.api.nvim_exec_autocmds, "User", {
    pattern = "YanaReviewSettled",
    data = { buf = bufnr, turn = turn, reason = reason },
  })
end

-- M.open installs real, buffer-visible side effects -- an augroup, the
-- BufWriteCmd write guard, buffer-local review keymaps, extmarks, winhl --
-- and then keeps going. A throw anywhere after `active = state` used to leave
-- every one of them armed on the buffer with no owner: `:w` intercepted
-- forever for hunks that no longer exist, and the orphaned closures still
-- holding a `state` whose finish_session would later clear `active` out from
-- under a NEWER review. That is the "it keeps falling off days later" shape.
-- Every entry into M.open goes through here so a failed open leaves no trace.
-- Normalises to exactly (ok, err): `ok` is true only when M.open itself
-- reported success (its own first return value, `true`) -- never merely
-- "pcall did not throw". Before this normalisation, M.open's own clean
-- refusal (`return false, reason`) read back through pcall as
-- `pcall_ok=true` (pcall did not throw), `a=false` (M.open's own boolean),
-- `b=reason` (M.open's real second value) -- and a caller doing the ordinary
-- `local ok, err = open_or_abandon(...)` two-value read bound `ok=true` and
-- `err=false`, discarding the real reason in the third slot nobody read.
-- That produced the "refused to navigate ... false" defect: `ok` looked
-- truthy so the caller fell through to its failure-message branch anyway
-- (gated on session identity, not on `ok`) and stringified the boolean.
-- `err` is a reason string either way now: the thrown error's own text when
-- pcall itself failed, or M.open's own second return value on a clean
-- refusal -- never a bare boolean.
local function open_or_abandon(change, opts)
  local pcall_ok, a, b = pcall(M.open, change, opts)
  if not pcall_ok then
    local st = pool_for(opts or {})
    if st.active and st.active.change == change then
      pcall(M.cleanup, st.active)
      st.active = nil
    end
    -- STAMP BEFORE ANNOUNCE. The claim renderer reads review_error first; if
    -- the announce runs while it is still nil the row falls through to the
    -- queued branch and paints "Queued — no hunks in this file yet" for a
    -- change that is not queued and will never open. Stamping at the call
    -- sites instead was too late: the direct M.review path re-raises straight
    -- after stamping and never announces again. This is the one place that
    -- sees both the failure and the change, so it owns both halves.
    local err_text = tostring(a)
    if change and change.review_error == nil then
      change.review_error = err_text
    end
    -- M.open announces "open" the instant it sets `active`, BEFORE it can
    -- still throw. Without an announce here the panel keeps a claim line
    -- asserting an open review that was just torn down -- "it says hunks
    -- opened but I see nothing in the file" -- until some unrelated engine
    -- transition happens to repaint it. Announcing here covers every entry.
    announce_state()
    return false, err_text
  end
  if a == true then
    return true, nil
  end
  -- M.open refused cleanly (no throw): `b` is its own reason string where it
  -- named one; `change.review_error` (stamped by the refusing branch itself)
  -- is the fallback for the rare site that has not been given one, so the
  -- caller never renders the bare boolean `a` again.
  -- REC-PLANT seam (`raw_refusal`, default off, see FAULT above): forward
  -- pcall's own boolean in the reason slot again, so the caller's message
  -- reads "... could not reopen <file>: false". That was a real reported
  -- defect and it is fixed; the recorder needs to be able to put the exact
  -- symptom back on camera to measure whether a blind video read-back finds
  -- a bare boolean in a message at all.
  return false,
    (FAULT.raw_refusal and tostring(a))
      or (b ~= nil and tostring(b))
      or (change and change.review_error)
      or "review did not open"
end

--- A refused open, said ONCE and in the right register.
---
--- RULING #100 (operator, 2026-08-23). Two of these fired for a single
--- refused reopen and both reached the operator: an ERROR "inline review
--- failed: <reason>" from whichever entry point was used, and a WARN "could
--- not open review buffer: <reason>" from `open_review_buffer` underneath it.
--- That is right for a review the OPERATOR asked for -- they pressed a key
--- and nothing opened, so they must be told why. It is wrong for a reopen the
--- WALK asked for: `u` is a key shared with Neovim, the operator asked for an
--- undo and got one, and the reintegration that would have made the reversed
--- hunk paintable again is yana's own follow-up work. Its refusal is a fact
--- about the walk, so it goes where facts about the walk go.
---
--- WHO ASKED is the discriminator, and `_retrace_reintegration` is the field
--- that records it (`retrace.reintegrate` sets it on every change it hands
--- back, minted or reused). Not "which refusal": the refusal itself is
--- unchanged, still stamped on `change.review_error`, still returned to the
--- caller, still able to keep the change pending.
function M._announce_open_failure(change, text, level)
  local line = "yana: " .. text
  log.write("WARN", line)
  if change and change._retrace_reintegration then
    return
  end
  notify_one_line(line, level)
end

-- The guarded entry for callers outside the queue (the diff-theme preview).
-- M.open must never be called raw: a throw after `active = state` leaves the
-- singleton set forever, which stalls process_next and makes every later
-- review refuse with "close active inline review first" -- a ghost review
-- nobody can close.
function M.open_guarded(change, opts)
  local ok, err = open_or_abandon(change, opts)
  if not ok then
    -- review_error is already stamped by open_or_abandon, before its announce.
    M._announce_open_failure(change, "inline review failed: " .. notify.error_headline(err), vim.log.levels.ERROR)
    return false, nil
  end
  -- M.open sets `active` on the pool synchronously, before it can still
  -- throw (see the comment above M.cleanup) -- open_or_abandon's own (ok,
  -- err) collapsed the state out of its return, but it is still right there.
  local st = pool_for(opts or {})
  local state = (st.active and st.active.change == change) and st.active or nil
  return true, state
end

local process_next_for

--- Forward declaration. Defined with the rest of the rewind machinery in
--- "WHOLE-REVIEW REWIND AT THE SINGLE INSERT BOUNDARY" far below, and used
--- up here by `schedule_queue_advance`: deferred work started while Yana
--- owns a transaction is still Yana's own transaction, and must run under
--- the same guard rather than after it.
local rewind_schedule

local function process_next_impl(st)
  if st.active or #st.queue == 0 then
    return nil
  end
  local item = table.remove(st.queue, 1)
  local change = item.change
  local ok, err = open_or_abandon(change, item.opts)
  if not ok then
    M._announce_open_failure(change, "inline review failed: " .. notify.error_headline(err), vim.log.levels.ERROR)
    vim.schedule(function()
      process_next_for(item.opts)
    end)
  end
  announce_state()
  return change
end

function process_next_for(opts)
  local attempted = nil
  log.guard("yana.inline_diff process_next", function()
    attempted = process_next_impl(pool_for(opts or {}))
  end)
  return attempted
end

local function process_next(opts)
  process_next_for(opts)
end

local function schedule_queue_advance(state)
  if not state then
    return
  end
  if state._skip_queue_advance then
    return
  end
  -- `rewind_schedule`, not `vim.schedule`. A queue advance is almost always
  -- queued by a close, and a close inside the cross-file retrace walk (a redo
  -- putting the last decision back, say) belongs to that walk: the advance
  -- opens the NEXT file's review and stages its proposal bytes, and those
  -- bytes are Yana's, not the operator time travelling. Outside a hold this
  -- is exactly `vim.schedule`.
  rewind_schedule(function()
    process_next_for(state.opts)
  end)
end

local function block_signature(blocks)
  local sig = {}
  for i, block in ipairs(blocks or {}) do
    sig[i] = table.concat({
      tostring(block.model_index or i),
      tostring(#(block.old_lines or {})),
      tostring(#(block.new_lines or {})),
      tostring(block.new_start_line or ""),
      tostring(block.new_end_line or ""),
    }, ":")
  end
  return table.concat(sig, "|")
end

local function parked_pending_blocks(state)
  local out = {}
  for i, block in ipairs((state and state.diff_blocks) or {}) do
    local copy = vim.deepcopy(block)
    copy.incoming_extmark_id = nil
    copy.incoming_extmark_ids = nil
    copy.delete_extmark_id = nil
    copy.authority_extmark_id = nil
    copy.nav_fallback_stated = nil
    out[i] = copy
  end
  return out
end

local function pending_hunk_count_for(change)
  if not change or change.status ~= "pending" then
    return 0
  end
  if change._parked_review then
    return #(change._parked_review.blocks or {})
  end
  return 1
end

local function remember_batch_item(st, item)
  local change = item and item.change
  if not (st and change) then
    return
  end
  if not change._review_order then
    st.order_seq = (st.order_seq or 0) + 1
    change._review_order = st.order_seq
    st.order[#st.order + 1] = change
  end
end

local function queue_remove_change(st, change)
  for i, item in ipairs((st and st.queue) or {}) do
    if item.change == change then
      return table.remove(st.queue, i)
    end
  end
  return nil
end

local function queue_insert_original(st, item)
  if not (st and item and item.change) then
    return
  end
  queue_remove_change(st, item.change)
  local order = item.change._review_order or math.huge
  local pos = #st.queue + 1
  for i, existing in ipairs(st.queue) do
    local eo = existing.change and existing.change._review_order or math.huge
    if order < eo then
      pos = i
      break
    end
  end
  table.insert(st.queue, pos, item)
end

local function ordered_target_for_state(state, direction)
  local change = state and state.change
  local st = pool_for((state and state.opts) or {})
  local end_text = direction == "next"
      and "last pending hunk in the last affected file"
    or "first pending hunk in the first affected file"
  local cur_order = change and change._review_order
  if not cur_order then
    return nil, end_text
  end
  local ordered = {}
  for _, c in ipairs(st.order or {}) do
    ordered[#ordered + 1] = c
  end
  table.sort(ordered, function(a, b)
    return (a._review_order or math.huge) < (b._review_order or math.huge)
  end)
  local start
  for i, c in ipairs(ordered) do
    if c == change then
      start = i
      break
    end
  end
  if not start then
    return nil, end_text
  end
  local step = direction == "next" and 1 or -1
  local i = start + step
  while ordered[i] do
    local candidate = ordered[i]
    if pending_hunk_count_for(candidate) > 0 then
      local item = queue_remove_change(st, candidate)
        or candidate._parked_item
        or { change = candidate, opts = state.opts, owner = freeze_review_owner(state.opts) }
      candidate._parked_item = nil
      return item, nil
    end
    notify_one_line(
      "yana: " .. (candidate.rel or candidate.path or "?") .. " settled -- skipping",
      vim.log.levels.INFO
    )
    i = i + step
  end
  return nil, end_text
end

--- `landing` (optional) says which hunk of the newly opened file to land on:
--- "first" or "last". Default follows the direction of travel -- forwards
--- lands on the first hunk, backwards on the last. The turn-wide reset
--- (ruling 48) walks backwards but must land on the FIRST hunk, and it cannot
--- do that by scheduling a second jump: this one is scheduled too, and the
--- last jump scheduled is the one the operator sees.
local function park_and_open_state(state, direction, target_item, landing)
  local change = state and state.change
  local bufnr = state and state.bufnr
  if not (state and change and bufnr) then
    return false
  end
  break_undo_block(bufnr)
  tl_capture_human_edit(state)
  local staged, snap_err = diff.buffer_bytes_snapshot(bufnr)
  if staged == nil then
    change.review_error = tostring(snap_err or "could not snapshot review buffer")
    notify_one_line("yana: refused to park " .. (change.rel or change.path) .. " -- " .. change.review_error, vim.log.levels.WARN)
    return false
  end
  local pending_blocks = parked_pending_blocks(state)
  if #pending_blocks == 0 then
    return false
  end
  local parked_item = state.queue_item or {
    change = change,
    opts = state.opts,
    owner = freeze_review_owner(state.opts),
  }
  local st = pool_for(state.opts or {})
  remember_batch_item(st, parked_item)
  local sealed = vim.deepcopy(state.sealed_decisions or {})
  for _, d in ipairs(state.decisions or {}) do
    sealed[#sealed + 1] = vim.deepcopy(d)
  end
  change._parked_review = {
    staged_text = staged,
    blocks = pending_blocks,
    pending_signature = block_signature(pending_blocks),
    model_hunks = vim.deepcopy(state.model_hunks or {}),
    model_source = state.model_source,
    sealed_decisions = sealed,
  }
  change._parked_item = parked_item
  change.status = "pending"

  record_decision(state, "review_parked", {
    direction = direction,
    hunks_remaining = #pending_blocks,
    target_rel = target_item and target_item.change and (target_item.change.rel or target_item.change.path) or nil,
  })
  require("yana.log").lifecycle_later("review.park", {
    turn_id = change.turn_id or change.turn_gen,
    generation = change.turn_gen,
    path = change.rel or change.path,
    direction = direction,
  })
  M.cleanup(state)
  -- ROW 112 / rulings 74+77: a review the RETRACE parks -- to show the hunk a
  -- `u` press just reversed in ANOTHER file -- keeps its own still-pending
  -- hunks PAINTED. `M.cleanup` above cleared them with the rest of the review,
  -- and an operator walking an undo chain across two files was left looking at
  -- a file with no bands at all while every one of its hunks was still pending
  -- (row 112's measured "b.py has 0 painted bands after the undo chain").
  -- Only the retrace asks for this: ordinary `]x`/`[x` parking is navigation
  -- and still leaves the file it steps away from clean.
  --
  -- Not when the file being opened IS this file: a reintegration that
  -- reopens the same buffer (a second `u` into a file the first `u` already
  -- reopened) rebuilds every hunk from the turn-start model and paints them
  -- itself. Painting the parked blocks here first describes lines the walk
  -- has just moved and withdraws a hunk that is not stale ("hunk ? no
  -- longer matches the buffer"; r75_redo_replays_mixed_decisions_in_order).
  local same_file = target_item
    and type(target_item.change) == "table"
    and (target_item.change.rel or target_item.change.path) == (change.rel or change.path)
  if target_item and target_item.retrace_repaint and not same_file and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    render_blocks(bufnr, pending_blocks, {
      site = "review_parked_retrace",
      model = state.model_hunks,
      model_source = state.model_source,
      change = change,
      opts = state.opts,
    })
  end
  st.active = nil
  queue_insert_original(st, parked_item)
  announce_state()

  local target_change = target_item and target_item.change
  if not target_change then
    return false
  end
  -- NEVER OPEN DIRECTLY OVER A STALE QUEUE DUPLICATE. `ordered_target_for_state`
  -- (ordinary `]x`/`[x` navigation) already dequeues its target with
  -- `queue_remove_change` before building `target_item` -- but retrace's own
  -- takeover (`bring_review_forward`/`reintegrate` in
  -- `lua/yana/timeline/retrace.lua`) hands this a bare `{change=...}` table
  -- without doing so, because that file's own `change` may still be sitting
  -- in `st.queue` from an earlier park. Opening it here (below) sets
  -- `st.active` directly, bypassing `process_next_impl`'s own queue pop, so
  -- the old queue entry survives pointing at the SAME change. When this
  -- review later closes, `finish_session`'s `schedule_queue_advance` runs
  -- `process_next_impl`, which pops that stale entry and reopens the
  -- already-resolved change from scratch -- resurrecting a cleanly closed
  -- review as `active_state()` again with a freshly rebuilt (non-empty)
  -- `diff_blocks`, even though `change.status` is no longer "pending".
  -- Measured: charlie's closed review reappearing during redo4 of a 4-file
  -- walk (`r75_four_file_walk_mirror`'s `[mirror]`/`[cA]` rows) -- charlie's
  -- own review had been directly opened this way at redo3, three presses
  -- after its queue entry was parked at u3, and never dequeued in between.
  -- Removing any stale entry HERE, once, covers every caller that reaches
  -- this primitive (idempotent when the caller already dequeued) rather than
  -- requiring each direct-open call site to remember to do it itself.
  queue_remove_change(st, target_change)
  local ok, err = open_or_abandon(target_change, target_item.opts)
  if ok and st.active and st.active.change == target_change then
    target_change._nav_refusal_announced = nil
    st.active.queue_item = target_item
    announce_state()
    vim.schedule(function()
      local active_state = st.active
      if active_state and active_state.change == target_change then
        local want_first = (landing == "first")
          or (landing == nil and direction == "next")
        local block = want_first
            and active_state.diff_blocks[1]
          or active_state.diff_blocks[#active_state.diff_blocks]
        land_on(target_change.path, active_state.bufnr, block)
      end
    end)
    return true
  end

  -- BURST GUARD (DEFECT C): the same refused target is retried on every
  -- `]x`/`[x` press (each press parks the current file and reopens the
  -- target from scratch), so a target that keeps refusing for the SAME
  -- reason used to re-print this exact line every press -- the "repeating
  -- in bursts" symptom. Announce once per distinct reason; a later attempt
  -- that fails for a genuinely different reason, or that succeeds (cleared
  -- above), is still reported.
  local nav_err_text = tostring(err)
  if target_change._nav_refusal_announced ~= nav_err_text then
    target_change._nav_refusal_announced = nav_err_text
    notify_one_line(
      "yana: refused to navigate from " .. (change.rel or change.path)
        .. " -- could not reopen " .. (target_change.rel or target_change.path or "?")
        .. ": " .. notify.error_headline(err),
      vim.log.levels.WARN
    )
  end
  queue_remove_change(st, change)
  local reopen_ok, _reopen_err = open_or_abandon(change, parked_item.opts)
  if reopen_ok and st.active and st.active.change == change then
    st.active.queue_item = parked_item
    announce_state()
    return false
  end
  queue_insert_original(st, parked_item)
  announce_state()
  return false
end

local function navigate_or_park_state(state, direction)
  local bufnr = state and state.bufnr
  local blocks = state and state.diff_blocks or {}
  local block, idx = current_block(blocks, bufnr)
  if not block then
    land_on(state.change and state.change.path, bufnr, nearest_block(blocks, bufnr, direction))
    return
  end
  local at_edge = (direction == "next" and idx == #blocks)
    or (direction == "prev" and idx == 1)
  if not at_edge then
    land_on(state.change and state.change.path, bufnr, nearest_block(blocks, bufnr, direction))
    return
  end
  local item, end_msg = ordered_target_for_state(state, direction)
  if not item then
    notify_one_line("yana: already at the " .. end_msg, vim.log.levels.INFO)
    return
  end
  park_and_open_state(state, direction, item)
end
M._navigate_or_park_state = navigate_or_park_state

local function active_state_for_global_navigation()
  local current = pool_for({}).active
  if current then
    return current
  end
  for _, st in pairs(pools) do
    if st.active then
      return st.active
    end
  end
  return nil
end

--- Global `]x`/`[x`. Returns `true` when Yana navigated, and otherwise
--- `false` plus a REASON the caller can act on:
---
---   "no-review"   Yana has nothing to navigate. Not a failure and not worth
---                 a message: the caller (init.lua) stands aside and lets
---                 whatever else owns the key run, and a notification on
---                 every press of the user's own key is pure noise.
---   "bad-direction" / "focus-failed"
---                 real navigation failures. `focus-failed` means a review IS
---                 open and Yana could not get to its buffer, which the user
---                 has to be told about -- it is not fallthrough.
function M.navigate_active_review(direction)
  if direction ~= "next" and direction ~= "prev" then
    return false, "bad-direction"
  end
  local state = active_state_for_global_navigation()
  if not state then
    return false, "no-review"
  end
  if not focus_buf(state.change.path, state.bufnr) then
    notify_one_line("yana: cannot open the reviewed file " .. tostring(state.change.path), vim.log.levels.WARN)
    return false, "focus-failed"
  end
  navigate_or_park_state(state, direction)
  return true
end

-- Exposed for `lua/yana/timeline/retrace.lua`'s reintegration seam (FIX-UNDO
-- lane, this session), same pattern as `M._navigate_or_park_state` above: a
-- reversed hunk must come back where the operator can decide it RIGHT NOW,
-- not merely append to the end of the queue behind whatever the queue
-- auto-advanced to next -- ruling 7 ("parking is navigation, never a
-- decision") names the PRIMITIVE, and this already-built one is exactly it.
-- `target_item` here is synthesised by the caller (`{change, opts, owner}`)
-- rather than read from this turn's own `ordered_target_for_state`, because
-- a reintegrated hunk belongs to no turn's queue -- everything else about
-- parking (snapshotting the current review's pending blocks, releasing its
-- keymaps, reinserting it so a later advance still reaches it) is unchanged.
M._park_and_open_state = park_and_open_state

--- Mint `_review_order` for `change` the SAME WAY `M.enqueue` and
--- `park_and_open_state` do -- both call `remember_batch_item` (above) on
--- the workspace pool's own `st.order`/`st.order_seq`, and nowhere else in
--- this module assigns the field. Exposed for
--- `lua/yana/timeline/retrace.lua`'s reintegration seam: `reintegrate`
--- there hands `_park_and_open_state` a `target_item` built from a change
--- that was never `M.enqueue`d (it belongs to no turn's queue -- see that
--- function's own comment), so the ordinary paths that mint the field
--- (enqueue inserting into the queue, park recording the item being left
--- behind) never run for it, and `]x`/`[x` read `_review_order == nil` as
--- "no siblings" and refuse in both directions even with a pending sibling.
--- No second ordering scheme: this calls the exact same `remember_batch_item`
--- the other two paths call, so a reintegrated change sorts into `st.order`
--- exactly where a fresh `M.enqueue` of it would have placed it. Idempotent
--- (`remember_batch_item` no-ops once `_review_order` is set), so calling
--- this ahead of `_park_and_open_state`/`M.review` is always safe -- neither
--- announces, opens, nor parks anything; it only reserves the change's place
--- in the order.
function M._ensure_review_order(change, opts)
  if not change then
    return
  end
  remember_batch_item(pool_for(opts or {}), { change = change })
end

--- RULING 74 + row 80: a reopened ORIGINAL review keeps `change.id`, but
--- navigation must still treat this reopening as the latest review made
--- visible by retrace. The old fresh-object reintegration got that behaviour
--- accidentally because it had no `_review_order`, so `_ensure_review_order`
--- appended it after every still-pending sibling. Reusing the original table
--- preserves identity; this helper deliberately refreshes only its position
--- in the turn navigation order so `[x`/`]x` see the same sibling relation
--- they saw before ruling 74.
function M._reopen_review_order(change, opts)
  if not change then
    return
  end
  local st = pool_for(opts or {})
  for i = #st.order, 1, -1 do
    if st.order[i] == change then
      table.remove(st.order, i)
    end
  end
  change._review_order = nil
  remember_batch_item(st, { change = change })
end

--- RULING 74 (AD:895): the original change this workspace's pool already
--- recorded for `rel`, if any -- so `lua/yana/timeline/retrace.lua`'s
--- `reintegrate` can REOPEN that SAME table (same `change.id`, same
--- `_review_order`, same ledger cell) instead of minting a fresh one every
--- time `u` walks a decision back. Searches `st.order`, the same accumulated
--- list `turn_changes` (above, the set `undo_rest_of_turn` iterates) draws
--- from -- `pool_for` already partitions it by workspace, so matching on
--- `rel` alone is matching on `(workspace, rel)`. Returns the LAST match
--- (`st.order` only ever grows, never prunes a settled entry), which is the
--- most recently recorded change for this rel -- the one a same-turn
--- accept/undo cycle keeps reusing. Returns nil when nothing has ever been
--- recorded for this rel in this pool (a genuinely cross-turn `u`), which is
--- retrace's own signal to mint instead.
function M._find_change_for_rel(rel, opts)
  if not rel then
    return nil
  end
  local st = pool_for(opts or {})
  local found = nil
  for _, c in ipairs(st.order or {}) do
    if c.rel == rel then
      found = c
    end
  end
  return found
end

----------------------------------------------------------------------
-- REOPEN-BY-UNDO (issue-log row 113; requirement R1/R2/R3/R4)
----------------------------------------------------------------------

--- Which decisions for `rel` STILL STAND, read from the file's own register.
--- Returns nil when the file has no buffer-regime hunk rows at all -- that is
--- a genuine FRESH open, and its caller must keep the fresh-open behaviour.
---
--- LAST DECISION PER HUNK WINS. The journal is append-only and the head is a
--- single pointer, so a hunk decided, walked back and decided AGAIN carries
--- two rows -- and once the newer one is itself walked back, the older one
--- reads `done` simply by sitting at the head. Only the NEWEST row for a hunk
--- describes its current state (same rule `retrace.settled_base` states, and
--- the same reason: `r74_reviews_opened_does_not_grow`, cycle 2's `u`).
---
--- NAMED LIMIT, inherited: a decision recorded FROM a reintegrated review
--- labels its hunk by that mini-review's own ordinal, not the turn model's.
--- Carrying `model_index` on the timeline row would make the mapping exact.
--- `reverted_ids` (optional) maps hunk ordinal -> the timeline row id a walk
--- has just reverted for that hunk. It exists because a row can be walked
--- back WITHOUT the buffer moving: accepting a hunk in an open review moves no
--- bytes (ruling 87), so `timeline.entries`' own head-derived `reverted`
--- marking cannot see the difference within the same press, and the newest row
--- for that hunk still reads `done` (measured: row d's `u1` reopened nothing,
--- "no pending hunk for a.py", while the register had already announced "undid
--- accept hunk 2 in a.py"). The WALK is the authority on what it just undid,
--- so it hands the ids down. Matching BY ID is what makes the override
--- self-expiring: decide that hunk again and a NEW row becomes the newest one,
--- the id no longer matches, and the fresh decision is honoured.
function M._register_decisions(ws, rel, reverted_ids)
  if type(rel) ~= "string" or rel == "" then
    return nil
  end
  local ok, timeline = pcall(require, "yana.timeline")
  if not ok or type(timeline.entries) ~= "function" then
    return nil
  end
  local ok2, entries = pcall(timeline.entries, ws, rel)
  if not ok2 or type(entries) ~= "table" then
    return nil
  end
  local newest, any = {}, false
  for _, e in ipairs(entries) do
    if e.regime == "buffer" and (e.kind == "hunk_accepted" or e.kind == "hunk_rejected") then
      local n = tonumber(tostring(e.label or ""):match("hunk (%d+)"))
      if n then
        newest[n] = e
        any = true
      end
    elseif e.regime == "buffer" and (e.kind == "file_accepted" or e.kind == "file_rejected") and type(e.members) == "table" then
      -- RULING 75: a file-level `ca`/`cb` is ONE row covering N hunks
      -- (`members`), never one `hunk_accepted`/`hunk_rejected` row per hunk.
      -- Append order still decides "last decision per hunk wins": a later
      -- row (of either shape) for the same hunk number simply overwrites
      -- this one, exactly as two `hunk_accepted` rows for the same hunk
      -- already do above.
      for _, m in ipairs(e.members) do
        local n = tonumber(m.hunk)
        if n then
          newest[n] = e
          any = true
        end
      end
    end
  end
  if not any then
    return nil
  end
  local out = {}
  for n, e in pairs(newest) do
    if e.state == "done" and not (reverted_ids and reverted_ids[n] == e.id) then
      out[n] = (e.kind == "hunk_accepted" or e.kind == "file_accepted") and "accepted" or "rejected"
    end
  end
  return out
end

local function lines_run_at(hay, needle, at)
  for j = 1, #needle do
    if hay[at + j - 1] ~= needle[j] then
      return false
    end
  end
  return true
end

--- The first place `needle` sits in `hay` at or after `from`, or nil. Searching
--- FORWARD from the previous block's end is what keeps two identical hunks
--- (the same one-line comment proposed twice) in their recorded order instead
--- of both anchoring on the first copy.
---
--- An EMPTY needle anchors at `from` -- exactly the position the old
--- model-composed text used for a block with no proposed lines, so such a
--- block behaves here as it always did.
local function find_run_from(hay, needle, from)
  if #needle == 0 then
    return math.max(from, 1)
  end
  for i = math.max(from, 1), #hay - #needle + 1 do
    if lines_run_at(hay, needle, i) then
      return i
    end
  end
  return nil
end

--- WHERE EACH BLOCK OF THE TURN-START MODEL SITS IN THE BUFFER, found BY
--- CONTENT, in recorded order.
---
--- This is requirement R1's "re-anchors by content" made literal, and it is
--- the whole reason a reopen no longer cares what happened to the file since
--- the turn started. What the buffer holds for a block is decided by the
--- REGISTER: a rejected hunk's original lines, anything else's proposed lines
--- (an accept moves no bytes -- ruling 87 -- so an accepted and a pending hunk
--- look the same in the buffer). Everything BETWEEN the blocks -- the human's
--- own typing, another lane's edit, whatever a `:w` re-based -- is simply
--- skipped over, because the scan never looks at it.
---
--- Returns nil + the offending block index when a block's lines are not in the
--- buffer at all; the caller withdraws it BY NAME (R1) and asks again.
local function anchor_blocks_in_buffer(buf_lines, blocks, decisions, withdrawn)
  local anchors, pos = {}, 1
  for i, b in ipairs(blocks) do
    local verdict = withdrawn[i] and "rejected" or decisions[i]
    local want = (verdict == "rejected") and (b.old_lines or {}) or (b.new_lines or {})
    local at = find_run_from(buf_lines, want, pos)
    if at == nil then
      return nil, i
    end
    anchors[i] = { at = at, count = #want }
    pos = at + #want
  end
  return anchors, nil
end

--- The review's BASE side: the BUFFER, with every PENDING hunk put back to its
--- original lines at the place the scan above anchored it. Only a pending hunk
--- is reviewable, so only a pending hunk differs between the two sides, and
--- `build_diff_blocks(before, buffer)` therefore yields EXACTLY the pending
--- hunks and nothing else -- the same contract the old model-composed pair
--- had, now expressed against the bytes the operator can actually see.
---
--- Spliced back to front so an earlier block's anchor stays valid while a
--- later one changes the line count.
local function base_side_from_buffer(buf_lines, blocks, decisions, withdrawn, anchors)
  local out = buf_lines
  for i = #blocks, 1, -1 do
    local verdict = withdrawn[i] and "rejected" or decisions[i]
    if verdict == nil then
      local a = anchors[i]
      local spliced = {}
      for k = 1, a.at - 1 do
        spliced[#spliced + 1] = out[k]
      end
      for _, l in ipairs(blocks[i].old_lines or {}) do
        spliced[#spliced + 1] = l
      end
      for k = a.at + a.count, #out do
        spliced[#spliced + 1] = out[k]
      end
      out = spliced
    end
  end
  return out
end

--- THE ONE REOPEN PATH for a review the operator is coming BACK to -- an `u`
--- that walked a decision back, or a queue navigation returning to a change
--- that already has decisions. It never consults the fresh-open dirty guard,
--- and it never asks disk anything.
---
--- WHY NOT DISK (R3). Accepting a hunk in an OPEN review moves no bytes
--- (ruling 87), so a file whose review closed with accepts still holds its
--- PRE-TURN bytes on disk -- disk-vs-buffer then paints the still-standing
--- accept as pending again (row 112). And the instant anything writes those
--- accepted bytes -- a `:w`, ruling 76's register entry, a turn-end write --
--- disk EQUALS the buffer and disk-vs-buffer describes nothing at all, which
--- is how `retrace.reintegrate` used to return silently while the register
--- walked on without the screen (row 113, measured by lane row113-s3). Both
--- shapes are one mistake: asking the bytes a question only the register can
--- answer. So the pending set comes from the REGISTER and the anchoring comes
--- from the BUFFER, and disk is not read.
---
--- WHY NOT THE GUARD (R2). `open_review_buffer`'s "unsaved edits unrelated"
--- refusal is for a FRESH open: the first review of a turn on a buffer the
--- human dirtied BEFORE the turn. A file that already carries decisions in
--- the register is by construction not that -- its `modified` bit is yana's
--- own staged text. This function is what makes that distinction STRUCTURAL
--- (does the register hold decisions for this file?) instead of a guard
--- exception keyed on one text comparison.
---
--- CONTRACT
---   * `decisions` (optional) maps hunk ordinal -> "accepted"/"rejected"; a
---     hunk with no entry is PENDING. Omitted: read from the register.
---   * Returns nil + reason for a genuine FRESH open (no register rows) or
---     when the composition cannot be anchored in the buffer. Callers keep
---     their own behaviour then -- the guard still refuses, and `u` still
---     refuses BY NAME rather than moving the register without the screen
---     (f135264).
---   * On success it mutates the change in place (`before`, `after`,
---     `status`, `_retrace_reintegration`, `_retrace_fresh`) and returns the
---     pair. The BUFFER IS NOT TOUCHED: `after` is exactly what the buffer
---     already holds, so `open_review_buffer`'s retrace fast path returns it
---     unstaged and `M.open` skips `insert_new_lines` -- no phantom
---     undo-tree entry in the operator's own history (R4, B8).
---   * A pending hunk whose proposed lines are ABSENT from the buffer is
---     WITHDRAWN BY NAME (announced, and returned in the second value)
---     rather than painted at a position that no longer holds it (R1).
--- @return table|nil pair {before=..., after=...}
--- @return table|nil withdrawn list of hunk names withdrawn from the reopen
--- @return string|nil reason why no pair could be built
--- The walk's per-hunk "reverted" memory (`change._retrace_reverted`, keyed
--- by hunk number -> row id) forgets one hunk when a redo puts that exact row
--- back; a later reopen then reads the row as the decision it is again.
function M._retrace_forget_reverted(change, hunk, id)
  local acc = type(change) == "table" and change._retrace_reverted
  if type(acc) ~= "table" or hunk == nil then
    return
  end
  if acc[hunk] == id then
    acc[hunk] = nil
  end
end

--- The turn-start hunk number of a live block (the number the register's
--- "accept hunk N" labels use). `model_index` when stamped; otherwise found by
--- content in the turn-start pair (`change._retrace_model`, else
--- before/after) -- a reintegrated review opened through `M.open` carries no
--- stamp (measured: redo refused "hunk 2 is not pending", calib/clip3.sim).
function M._hunk_number_for_block(change, block)
  if type(block) ~= "table" then
    return nil
  end
  if block.model_index ~= nil then
    return block.model_index
  end
  local model = type(change) == "table" and (change._retrace_model or { before = change.before, after = change.after }) or nil
  if not (model and type(model.before) == "string" and type(model.after) == "string") then
    return nil
  end
  local ok, blocks = pcall(M.build_diff_blocks, model.before, model.after)
  if not ok or type(blocks) ~= "table" then
    return nil
  end
  for n, b in ipairs(blocks) do
    if vim.deep_equal(b.new_lines or {}, block.new_lines or {}) and vim.deep_equal(b.old_lines or {}, block.old_lines or {}) then
      return n
    end
  end
  return nil
end

function M.reopen_from_register(ws, rel, bufnr, decisions, reverted_ids)
  if type(rel) ~= "string" or rel == "" then
    return nil, nil, "no rel"
  end
  if not (type(bufnr) == "number" and bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr)) then
    return nil, nil, "no loaded buffer for " .. rel
  end
  local change = M._find_change_for_rel(rel, { workspace = ws })
  if type(change) ~= "table" then
    return nil, nil, "no change recorded for " .. rel
  end
  -- The TURN-START pair, captured ONCE -- reopening overwrites
  -- `change.before`/`change.after`, so without this the model drifts after
  -- the first reopen. Shared field with `retrace.settled_base` on purpose:
  -- one model per change, whichever path captures it first.
  local model = change._retrace_model
  if model == nil then
    model = { before = change.before, after = change.after }
    change._retrace_model = model
  end
  if type(model.before) ~= "string" or type(model.after) ~= "string" then
    return nil, nil, "no turn-start pair for " .. rel
  end
  local blocks = M.build_diff_blocks(model.before, model.after)
  if type(blocks) ~= "table" or #blocks == 0 then
    return nil, nil, "no hunks in the turn-start pair for " .. rel
  end
  -- The turn-start hunk number IS the register's hunk number ("accept hunk
  -- N" labels, `_register_decisions`, redo by hunk): stamp it so a reopened
  -- block can be found by it. Unstamped, a redo of a walk-reverted decision
  -- refused "hunk N is not pending" and the withdraw message said "hunk ?"
  -- (measured, calib/clip3.sim replay 2026-08-23).
  for n, b in ipairs(blocks) do
    if b.model_index == nil then
      b.model_index = n
    end
  end
  -- Decision 57: a hunk the human typed INTO carries THEIR lines as its
  -- proposal from that moment on (`absorb_human_edits`). The turn-start text
  -- is what the model pins, so the absorbed proposal is overlaid here, per
  -- hunk, before anything is looked for in the buffer -- the agent's own text
  -- is not in the buffer any more and would read as withdrawn.
  local absorbed = change._retrace_absorbed
  if type(absorbed) == "table" then
    for n, lines in pairs(absorbed) do
      if blocks[n] then
        blocks[n].new_lines = vim.deepcopy(lines)
      end
    end
  end
  -- The walk's own account of what it just reverted, ACCUMULATED on the change
  -- so a second and third press keep the earlier presses' hunks pending too.
  -- Keyed by row id, so it expires by itself the moment that hunk is decided
  -- again (see `M._register_decisions`).
  if type(reverted_ids) == "table" then
    local acc = change._retrace_reverted
    if type(acc) ~= "table" then
      acc = {}
      change._retrace_reverted = acc
    end
    for n, id in pairs(reverted_ids) do
      acc[n] = id
    end
    local land_model = nil
    for n, _ in pairs(reverted_ids) do
      if type(n) == "number" and (land_model == nil or n < land_model) then
        land_model = n
      end
    end
    if land_model ~= nil then
      change._retrace_land_model_index = land_model
    end
  end
  decisions = decisions or M._register_decisions(ws, rel, change._retrace_reverted)
  if type(decisions) ~= "table" then
    -- FRESH OPEN: nothing has been decided for this file. R2 -- the caller's
    -- fresh-open behaviour stands, guard included.
    return nil, nil, "no register decisions for " .. rel
  end

  -- CONTENT RE-ANCHORING (R1). The buffer is the AFTER side, always and
  -- unchanged: a reopen shows the operator what is on their screen, it does
  -- not move bytes (ruling 97 -- the human's saved copy stays). The blocks of
  -- the turn-start model are then located IN that buffer by content, and only
  -- the pending ones are put back to their original lines to form the base.
  --
  -- WHAT THIS REPLACED, and why it is the same defect twice (issue-log row
  -- 113, the operator's det3d screencast 10:26). The old body composed an
  -- EXPECTED text from the turn-start model and demanded the buffer equal it.
  -- Anything the human had typed outside the hunks -- the `[+]` in the
  -- operator's own status line -- broke that equality, so this function
  -- returned nil and `retrace.reintegrate` fell through to its disk-vs-buffer
  -- fallback, which then behaved two different ways for one root cause:
  --   * the file had been WRITTEN after its review closed, so disk EQUALLED
  --     the buffer, the fallback's `before == after` returned silently, and
  --     the register walked "undid accept hunk 3/2/1 in a.py" with ZERO bands
  --     on screen and the active file never leaving b.py (the screencast);
  --   * the file had NOT been written, so the fallback composed a review off
  --     the bytes and reopened a.py with the WRONG hunk count (measured: two
  --     pending hunks for one press, then `undo sequence drift` on every press
  --     after it).
  -- Asking the bytes a question only the register can answer is the one
  -- mistake; a text comparison against a model that cannot represent the
  -- human's own edits is how it got asked. There is no comparison here any
  -- more, and so no shape of write, save or human edit for a guard to be
  -- keyed on.
  local buf_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local withdrawn_set, withdrawn = {}, {}
  local anchors, missing = anchor_blocks_in_buffer(buf_lines, blocks, decisions, withdrawn_set)
  while anchors == nil do
    -- R1: a hunk whose lines are not in the buffer cannot be painted anywhere
    -- honest. WITHDRAW IT BY NAME and anchor the rest. A block that is already
    -- withdrawn, or one the register says was DECIDED, has no second reading
    -- to fall back on -- refuse by name instead of guessing at a position.
    if decisions[missing] ~= nil or withdrawn_set[missing] then
      return nil, withdrawn, "hunk " .. tostring(missing) .. "'s recorded lines are not in " .. rel
    end
    withdrawn_set[missing] = true
    withdrawn[#withdrawn + 1] = "hunk " .. tostring(missing)
    anchors, missing = anchor_blocks_in_buffer(buf_lines, blocks, decisions, withdrawn_set)
  end
  -- The buffer's own line ending convention, so the pair this returns is
  -- byte-comparable with everything else that reads the file.
  local snapshot = diff.buffer_bytes_snapshot(bufnr)
  local trailing = type(snapshot) == "string" and snapshot:sub(-1) == "\n"
  local function join(lines)
    return table.concat(lines, "\n") .. (trailing and "\n" or "")
  end
  local after_text = join(buf_lines)
  local before_text = join(base_side_from_buffer(buf_lines, blocks, decisions, withdrawn_set, anchors))
  if diff.text_equal_snapshot(before_text, after_text) then
    -- Every decision still stands: there is nothing pending to reopen. Say so
    -- rather than opening an empty review.
    return nil, withdrawn, "no pending hunk for " .. rel
  end

  change.before = before_text
  change.after = after_text
  change.status = "pending"
  -- The markers `open_review_buffer` and `M.open` already read: return the
  -- buffer unstaged, skip `insert_new_lines`, and prefer this freshly derived
  -- pair over any parked snapshot the change is still carrying (row 112).
  change._retrace_reintegration = true
  change._retrace_fresh = true

  if #withdrawn > 0 then
    notify_one_line(
      "yana: " .. table.concat(withdrawn, ", ") .. " in " .. rel
        .. " is no longer in the buffer — withdrawn from this review",
      vim.log.levels.WARN
    )
  end
  return { before = before_text, after = after_text }, withdrawn, nil
end

-- Owner callbacks belong to the panel, not to this engine, and the engine's
-- own teardown must not depend on them succeeding. Before this guard, a throw
-- inside on_accept/on_reject skipped `M.cleanup` + `active = nil` +
-- `process_next` below: the queue stalled forever, review keymaps stayed
-- installed, and the BufWriteCmd guard kept intercepting every later `:w` on
-- that file. That is the "days later I can't save / reviews stop opening"
-- shape. The callback is reachable-and-throwing in normal use (ui.lua's
-- refresh_change_block writes at a stored absolute line that `new_chat` can
-- invalidate), so this is a live path, not a defensive nicety.
local function notify_owner(cb, change, label)
  if not cb then
    return true
  end
  local ok, err = pcall(cb, change)
  if not ok then
    notify_one_line(
      "yana: " .. label .. " handler failed for `" .. (change.rel or change.path or "?")
        .. "`: " .. tostring(err) .. " (review state was still torn down cleanly)",
      vim.log.levels.ERROR
    )
    return false
  end
  return true
end

----------------------------------------------------------------------
-- `U` REACHES THE WHOLE TURN -- ruling 48 (issue log row 48).
--
-- `u` is unchanged: the last step, per hunk, in the file under the cursor.
-- `U` is the RESET, and there is no separate command for it: every file the
-- turn touched goes back to the state the operator was FIRST SHOWN, and the
-- cursor lands on the turn's first pending hunk.
--
-- The two hard cases are the ones the ruling names:
--   (a) A file already settled and CLOSED has no buffer to pop and no review
--       to unwind. It is REOPENED -- put back in the queue at its original
--       position with its decision cleared -- so the operator gets the review
--       they were shown, not an empty one.
--   (b) A file already ACCEPTED is already on disk, so undoing it means
--       WRITING to the real tree with no accept behind it. The ruling permits
--       exactly that, and requires the panel to SAY SO as it happens. The
--       write itself still goes through the journaled applier (the seam
--       `on_shadow_revert`), so the sole-real-tree-writer contract holds and
--       the undo is itself revertible.
--
-- What this does NOT do, said rather than hidden: an accepted file the agent
-- CREATED has no turn-start bytes to restore, only turn-start absence, and
-- putting absence back is a journaled delete the applier does not offer yet.
-- Those are REFUSED BY NAME and reported in the summary as not undone, rather
-- than being quietly counted as restored.
----------------------------------------------------------------------

--- THIS turn, and only this turn. The pool's `order` is never cleared between
--- turns -- it is the panel's whole review history for that workspace -- so a
--- sweep over it reaches changes the operator settled in EARLIER turns, whose
--- bytes `U` has no business putting back. Measured that way round first: over
--- three turns, `U` announced "6 file(s)" and wrote two of them back twice
--- each, after which accept-all found three stale queued changes. The turn
--- identity on the change decides.
local function same_turn(a, b)
  if a == b then
    return true
  end
  if a.turn_id ~= nil or b.turn_id ~= nil then
    return a.turn_id == b.turn_id
  end
  return a.turn_gen == b.turn_gen
end

--- Every change of this turn, in the order the operator was shown them.
local function turn_changes(state)
  local st = pool_for(state and state.opts or {})
  local this = state and state.change
  local ordered = {}
  for _, c in ipairs(st.order or {}) do
    if this == nil or same_turn(c, this) then
      ordered[#ordered + 1] = c
    end
  end
  table.sort(ordered, function(a, b)
    return (a._review_order or math.huge) < (b._review_order or math.huge)
  end)
  return ordered, st
end

--- Put one settled/parked change back in the queue exactly where it was, with
--- its decision cleared, so the review the operator was first shown reopens.
local function revive_change(st, c, opts)
  local item = queue_remove_change(st, c)
    or c._parked_item
    or { change = c, opts = opts, owner = freeze_review_owner(opts) }
  c._parked_item = nil
  c._parked_review = nil
  c.review_error = nil
  c.status = "pending"
  queue_insert_original(st, item)
end

local function transfer_restore_refusal(c, reason)
  local rel = c and (c.rel or c.path) or "?"
  return rel .. ": transfer undo refused — " .. tostring(reason)
end

local function undo_transferred_accept(c)
  local bufnr = c and c._accept_bufnr
  if not (type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return false, transfer_restore_refusal(c, "review buffer is not loaded")
  end
  local snap, serr = diff.buffer_bytes_snapshot(bufnr)
  if snap == nil then
    return false, transfer_restore_refusal(c, serr or "could not read review buffer")
  end
  if base_fingerprint(snap) ~= c._accept_composed_hash then
    return false, transfer_restore_refusal(c, "review buffer changed after accept")
  end
  -- Ruling 97: "saved by the human or not" -- a real `:w` between the
  -- transfer and `U` is an expected path, not drift. Disk may still be at
  -- turn-start (never saved) OR hold exactly the accepted bytes this accept
  -- composed (the human's own save of what the buffer showed); either is the
  -- buffer's own history and `U` proceeds -- it is a buffer edit either way,
  -- never a disk write. Anything else on disk is a third party and still
  -- refuses.
  local disk = c.path and diff.read_file_bytes(c.path) or nil
  local disk_is_turn_start = disk == c.before
  local disk_is_accepted_save = disk ~= nil and c._accept_composed_hash ~= nil and base_fingerprint(disk) == c._accept_composed_hash
  if not (disk_is_turn_start or disk_is_accepted_save) then
    return false, transfer_restore_refusal(c, "disk no longer holds the turn-start bytes")
  end
  local wants_eol = (c.before or ""):match("\n$") ~= nil
  vim.bo[bufnr].fixendofline = wants_eol
  vim.bo[bufnr].endofline = wants_eol
  break_undo_block(bufnr)
  local ok, err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, buffer_lines(c.before or ""))
  break_undo_block(bufnr)
  if not ok then
    return false, transfer_restore_refusal(c, err)
  end
  -- Ruling 79: this restore puts the WHOLE buffer back to turn-start bytes,
  -- so there is no pending hunk of this review left to withhold -- `nil`
  -- blocks makes `M._recompute_modified` compare the full buffer to disk,
  -- identical to what this comparison did inline before.
  M._recompute_modified(bufnr, nil, c.path)
  return true
end

--- The sweep. Returns the rels put back, the rels whose BYTES had to be
--- written back to disk, and the ones that refused, each with its reason.
local function undo_rest_of_turn(state)
  local restored, reverted, refused, removed = {}, {}, {}, {}
  local ordered, st = turn_changes(state)
  local opts = state.opts or {}
  for _, c in ipairs(ordered) do
    if c ~= state.change then
      local rel = c.rel or c.path or "?"
      local was_accepted = c.status == "accepted"
      -- Ruling 52: `U` branches on WHAT THE FILE WAS AT TURN START. An
      -- existing file gets its turn-start bytes written back (ruling 48); an
      -- agent-CREATED file had no bytes at turn start, only absence, so it is
      -- staged and REMOVED instead. Both go through the same journaled
      -- applier; only the announcement and the accounting differ.
      local was_created = c.before == nil
      local ok = true
      if was_accepted then
        local regime = c._accept_regime or "durable"
        -- SAID BEFORE IT HAPPENS, and durably: this is the one write in the
        -- product that lands on the real tree without an accept behind it.
        if regime == "transfer" then
          local terr
          ok, terr = undo_transferred_accept(c)
          if ok ~= true then
            refused[#refused + 1] = terr
            ok = false
          else
            -- Ruling 97: a buffer-owned accept is un-transferred by an
            -- ordinary buffer edit (`undo_transferred_accept`, above) --
            -- no disk I/O on this branch. Disk keeps whatever the human
            -- last saved; only the buffer moves back to pending.
            local said = "yana: U reset " .. rel .. " in the buffer; disk keeps your saved copy"
            log.write("INFO", said)
            notify_one_line(said, vim.log.levels.INFO)
          end
        else
          local said = was_created
            and ("yana: U removes " .. rel .. ", which this turn created, and stages a recoverable copy")
          or ("yana: U writes " .. rel .. " back to disk without an accept")
          log.write(
            "WARN",
            said .. " -- it had already been accepted, and undoing the turn puts its "
              .. "turn-start "
              .. (was_created and "absence" or "bytes")
              .. " back through the journaled applier"
          )
          notify_one_line(said, vim.log.levels.WARN)
          if opts.on_shadow_revert then
            local err, info
            ok, err, info = opts.on_shadow_revert(c)
            if ok ~= true then
              refused[#refused + 1] = rel .. ": " .. notify.error_headline(err or "revert failed")
              ok = false
            elseif was_created then
              removed[#removed + 1] = { change = c, rel = rel, staged_path = type(info) == "table" and info.staged_path or nil }
            end
          else
            ok = false
            refused[#refused + 1] = rel .. ": no journaled revert available for this review"
          end
        end
      end
      if ok then
        revive_change(st, c, opts)
        notify_owner(opts.on_kept_unreviewed, c, "on_kept_unreviewed")
        restored[#restored + 1] = rel
        if was_accepted then
          reverted[#reverted + 1] = rel
        end
      end
    end
  end
  if #removed > 0 then
    -- REMEMBERED ON THE POOL, not in the timeline: the timeline holds no byte
    -- snapshot by design, and this list is what `<C-r>` reads to know which
    -- staged copies are waiting to be put back.
    st.staged_removals = st.staged_removals or {}
    for _, entry in ipairs(removed) do
      st.staged_removals[#st.staged_removals + 1] = entry
    end
  end
  announce_state()
  return restored, reverted, refused, removed
end

--- Redo's half of ruling 52. `U` removed the files this turn CREATED, staging
--- their bytes in the turn's private evidence dir; stepping forward again puts
--- them back, byte for byte, through the journaled applier, and says which.
---
--- Returns true when it consumed the press. A missing staged copy (the turn's
--- evidence was pruned) is REPORTED, never a silent no-op -- redo-scoped
--- recovery is not an archive, and the operator has to be told which of the
--- two happened.
local function redo_staged_restores(state)
  local st = pool_for(state and state.opts or {})
  local pending = st.staged_removals
  if type(pending) ~= "table" or #pending == 0 then
    return false
  end
  st.staged_removals = nil
  local opts = state.opts or {}
  local restore = opts.on_shadow_restore_staged
  local names, failed = {}, {}
  for _, entry in ipairs(pending) do
    local c = entry.change
    local rel = entry.rel or (c and (c.rel or c.path)) or "?"
    local ok, err = false, "no journaled restore available for this review"
    if restore then
      ok, err = restore(c)
    end
    if ok == true then
      -- The exact inverse of `revive_change`: the change leaves the queue
      -- again and stands accepted, which is what it was when `U` found it.
      queue_remove_change(st, c)
      c._parked_item = nil
      c._parked_review = nil
      c.status = "accepted"
      notify_owner(opts.on_kept_unreviewed, c, "on_kept_unreviewed")
      names[#names + 1] = rel
    else
      failed[#failed + 1] = rel .. ": " .. notify.error_headline(err or "restore failed")
    end
  end
  if #names > 0 then
    local msg = string.format("yana: restored %d file(s) removed by U: %s", #names, table.concat(names, ", "))
    log.write("WARN", msg)
    notify_one_line(msg, vim.log.levels.INFO)
  end
  if #failed > 0 then
    local msg = string.format(
      "yana: %d file(s) could NOT be restored -- the staged copy is redo-scoped, and this turn's evidence is gone: %s",
      #failed,
      table.concat(failed, "; ")
    )
    log.write("WARN", msg)
    notify_one_line(msg, vim.log.levels.WARN)
  end
  announce_state()
  return true
end

--- After a turn-wide undo the cursor belongs on the turn's FIRST pending
--- hunk, which is the first hunk of the first file the operator was shown.
--- If that is not the file under the cursor, the active review is PARKED --
--- navigation, never a decision -- and the first one is opened.
local function focus_turn_first_hunk(state)
  local ordered, st = turn_changes(state)
  local first = ordered[1]
  if not first then
    return false
  end
  if first == state.change then
    land_on(state.change and state.change.path, state.bufnr, state.diff_blocks and state.diff_blocks[1])
    return true
  end
  local item = queue_remove_change(st, first)
    or first._parked_item
    or { change = first, opts = state.opts, owner = freeze_review_owner(state.opts) }
  first._parked_item = nil
  -- "first": the reset walks BACKWARDS to the turn's first file but lands on
  -- its FIRST hunk, not its last.
  if not park_and_open_state(state, "prev", item, "first") then
    return false
  end
  return true
end
-- Reached through `M.` from inside `M.open`, exactly as
-- `M._navigate_or_park_state` is: that function is already at Lua's 60-upvalue
-- ceiling, and two more file-local names would not fit.
M._undo_rest_of_turn = undo_rest_of_turn
M._focus_turn_first_hunk = focus_turn_first_hunk
M._redo_staged_restores = redo_staged_restores

local function mode_perm(mode)
  return mode and (mode % 4096) or nil
end

local function compound_mode_text(change)
  if not change or not change.base_mode or not change.after_mode then
    return nil
  end
  if mode_perm(change.base_mode) == mode_perm(change.after_mode) then
    return nil
  end
  return string.format("mode %o → %o", mode_perm(change.base_mode), mode_perm(change.after_mode))
end

--- Every durable accept waits for the turn's classified bundle to publish.
local function review_action_allowed(state, change)
  local pass = state.opts and state.opts.turn_pass
  if not pass then
    return true
  end
  local lifecycle = require("yana.turn_lifecycle")
  if not lifecycle.is_actionable(pass) then
    return false, "refused: the classified bundle for this turn has not published yet"
  end
  return lifecycle.action_allowed(pass, change and (change.rel or change.path))
end

--- Per-hunk accept drains `diff_blocks` before the shadow applier runs. When
--- the applier refuses (human drift, mode mismatch, …), `change.after` still
--- holds the agent proposal in the private layer — only the review's hunk list
--- was cleared. Rebuild and repaint the hunk list over the live buffer so both
--- versions stay enumerable without letting the staged snapshot overwrite any
--- human text typed before the refusal (CORE: "both versions are retained";
--- integration lab L26).
local function restore_agent_proposal_after_refusal(state)
  local change = state.change
  if not change then
    return
  end
  local target = model_target(change)
  state.diff_blocks = stamp_model_index(
    M.build_diff_blocks(change.before or "", target),
    state.model_hunks or {}
  )
  local bufnr = state.bufnr
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    return
  end
  render_blocks(bufnr, state.diff_blocks, {
    site = "accept_refused_restore",
    model = state.model_hunks,
    model_source = state.model_source,
    change = change,
    opts = state.opts,
  })
end

function M._record_shadow_accept_refusal(state, err)
  local change = state.change
  local turn_log = change_ledger(change, state.opts)
  change.review_error = tostring(err or "accept failed")
  local raw_detail = change.shadow_refusal
  ledger.record_decision(turn_log, {
    action = "review_refused",
    actor = "system",
    -- The diary's own machine-readable slug when it produced one -- every one
    -- of its five refusal categories does, as of the refusal-evidence delta --
    -- falling back to the legacy bare label only for a refusal that never
    -- reached the diary at all (e.g. a claim conflict raised in this engine).
    reason = (type(raw_detail) == "table" and raw_detail.reason_code) or "shadow_accept_failed",
    detail = tostring(err),
    change_id = change.id,
    rel = change.rel or change.path,
  })
  local detail = change.shadow_refusal
  if type(detail) == "table" and type(detail.actual_fp) == "string" then
    local origin, drift_reason = attribute_drift(change, detail.reason or "stale_file", detail.actual_fp)
    detail = vim.tbl_extend("force", {}, detail)
    if origin then
      detail.origin = origin
    end
    if drift_reason then
      detail.reason = drift_reason
    end
  end
  ledger.attach_refusal(turn_log, detail)
  -- DURABLY, not only in the in-memory ledger (issue: a refusal's evidence
  -- lived only in the turn journal and the in-memory ledger; the operator
  -- reads the session log (yana.log), and evidence that never reaches it does
  -- not exist in practice). Gated by YANA_LIFECYCLE_LOG exactly like every
  -- other `review.decision` row, so a clean/quiet turn still writes nothing.
  -- Hashes only cross this boundary, already truncated to 16 hex characters
  -- by the diary (`diary.lua`'s stale-file record): no content, ever.
  log.lifecycle_later("review.decision", {
    turn_id = change and (change.turn_id or change.turn_gen),
    generation = change and change.turn_gen,
    action = "review_refused",
    actor = "system",
    path = change.rel or change.path,
    change_id = change.id,
    -- Mutation seam (gate): `omit_session_log_reason_code` reproduces the
    -- pre-this-delta session log line, which never carried the diary's
    -- machine-readable slug at all (issue: "the session log line showed none
    -- of them").
    reason_code = (not M._test.fault.omit_session_log_reason_code)
      and (type(detail) == "table" and detail.reason_code or nil)
      or nil,
    reason = (type(detail) == "table" and detail.reason) or "shadow_accept_failed",
    expected_fp = type(detail) == "table" and detail.expected_fp or nil,
    actual_fp = type(detail) == "table" and detail.actual_fp or nil,
    expected_state = type(detail) == "table" and detail.expected_state or nil,
    found_state = type(detail) == "table" and detail.found_state or nil,
    base_hash_captured_ts = type(detail) == "table" and detail.base_hash_captured_ts or nil,
  })
  change.status = "pending"
  notify_one_line(
    "yana: shadow accept failed for " .. (change.rel or change.path) .. ": " .. tostring(err),
    vim.log.levels.ERROR
  )
  restore_agent_proposal_after_refusal(state)
  if #state.diff_blocks > 0 then
    announce_state()
    schedule_queue_advance(state)
    return true
  end
  return false
end

local function finish_session(state, accepted)
  local change = state.change
  local bufnr = state.bufnr
  local turn_log = change_ledger(change, state.opts)
  ledger.mark(turn_log, "review_resolved")
  require("yana.log").lifecycle_later("review.settle", {
    turn_id = change.turn_id or change.turn_gen,
    generation = change.turn_gen,
    path = change.rel or change.path,
    accepted = accepted and true or false,
  })

  -- Vim appends a trailing newline after the final line, so a buffer read back
  -- verbatim gains an EOL the agent never wrote. Mirror the agent's own
  -- trailing-newline shape before the buffer is snapshotted or saved.
  --
  -- Declared here, not further down: the shadow_apply branch below returns
  -- before the legacy path and so never ran this, which made every shadow
  -- accept of a file without a trailing newline write one anyway — and turned
  -- an agent-created EMPTY file into a one-byte "\n" file.
  local function match_eol(snapshot)
    local wants_eol = (snapshot or ""):match("\n$") ~= nil
    vim.bo[bufnr].fixendofline = wants_eol
    vim.bo[bufnr].endofline = wants_eol
  end

  if state.opts.shadow_apply then
    -- Success is explicit only: unset or false means the requested action did
    -- not complete. No default true — a skipped branch or missing callback
    -- must not inherit success from an earlier operation.
    local ok = false
    local err = nil
    local applied = nil
    if accepted then
      if change.kind == "delete" then
        -- Same guard the legacy accept path below carries, and it was missing
        -- here: a deletion accept never reads the review buffer, so human text
        -- typed into it during the review would vanish with no trace. This
        -- branch returns before that guard is reached, and it snapshotted the
        -- buffer regardless of kind, which made shadow-apply a third unguarded
        -- discard site once E9 routed every turn through it. Refuse by name and
        -- keep both versions: their text in the buffer, the deletion in the
        -- change set.
        if not staged_snapshot_unchanged(state) then
          ok, err = false, "buffer holds edits that accepting this deletion would discard"
        else
          local allowed, why = review_action_allowed(state, change)
          if not allowed then
            ok, err = false, why
          elseif not state.opts.on_shadow_accept then
            ok, err = false, "shadow accept handler missing"
          else
            -- No composed content for a deletion: the applier unlinks, and
            -- passing buffer bytes here is what let an empty file be written in
            -- place of the delete.
            local aok, aerr, aapplied = state.opts.on_shadow_accept(change, nil, { staged_bufnr = bufnr })
            ok = aok == true
            err = aerr
            applied = aapplied
          end
        end
      else
        match_eol(change.after)
        local composed, cerr = diff.buffer_bytes_snapshot(bufnr)
        if composed == nil then
          ok, err = false, cerr
        else
          local allowed, why = review_action_allowed(state, change)
          if not allowed then
            ok, err = false, why
          elseif not state.opts.on_shadow_accept then
            ok, err = false, "shadow accept handler missing"
          else
            local aok, aerr, aapplied = state.opts.on_shadow_accept(change, composed, { staged_bufnr = bufnr })
            ok = aok == true
            err = aerr
            applied = aapplied
          end
        end
      end
      if ok then
        change.status = "accepted"
        if type(applied) == "table" and applied.kind == "transfer" then
          vim.bo[bufnr].modified = true
          change._accept_regime = "transfer"
          change._accept_bufnr = applied.bufnr
          change._accept_composed_hash = applied.composed_hash
          ledger.mark(turn_log, "accept_transferred")
        else
          change._accept_regime = "durable"
          ledger.mark(turn_log, "accept_applied")
        end
        -- The durable row: this write went through the journaled applier, so
        -- taking it back later is the journal's revert, not a buffer undo. The
        -- applier hands out the diary directory and the op id it consumed
        -- (shadow/apply.lua), which is what makes the row revertible by identity
        -- rather than by guesswork.
        if type(applied) == "table" and applied.diary_dir and applied.op_id then
          tl_record(state, "applied",
            "applied " .. (change.rel or change.path or "?"),
            { regime = "durable", diary_dir = applied.diary_dir, op_id = applied.op_id })
        end
        -- Durable outcome is decided by the applier alone. A throwing on_accept
        -- is a presentation problem only: report it, never flip status back to
        -- pending or treat the accept as refused after bytes are on disk.
        notify_owner(state.opts.on_accept, change, "on_accept")
      end
    else
      ok = true
      -- Reject restores THE AGENT'S LINES ONLY, hunk by hunk, through the same
      -- authority extmarks per-hunk reject reads (live_block_range). It used to
      -- overwrite the whole buffer from the stored turn-start snapshot
      -- (`change.before`) and then mark it clean, which discarded whatever the
      -- human wrote while the review was open -- including text in a region no
      -- hunk covers and text the human had already SAVED -- and left no modified
      -- flag, so one ordinary save afterwards wrote the stale snapshot over the
      -- human's durable work (aider #513 / Cursor FileChangeTracker.reject
      -- shape, one layer in). Text the human typed INSIDE a hunk's live range
      -- became part of that hunk the instant it landed there (decision 57,
      -- `absorb_human_edits`) -- the block was one thing and the operator said
      -- no to all of it, so it leaves with the rest via reject_restoration,
      -- the same function reject_block_at calls, so the two paths cannot
      -- disagree about the same keystroke.
      --
      -- ONE FILE-LEVEL DECISION, ONE REGISTER ROW / ONE UNDO ENTRY (ruling
      -- 75). `state.timeline_bulk_reject` (set only by `reject_all`'s fresh
      -- whole-file branch) turns off the PER-HUNK `break_undo_block` calls
      -- below, so Neovim's own tree collapses every hunk's restoration into
      -- ONE step -- exactly the "before this, the whole file collapsed into
      -- one undo state" shape `break_undo_block`'s own comment describes,
      -- deliberately restored here because ruling 75 amends `u` to be per
      -- FILE-LEVEL-DECISION, not per hunk, for `ca`/`cb`. Every other caller
      -- of this reject path (`close_active`, panel-level reject, `U`'s
      -- abort) leaves the flag unset and keeps the old per-hunk-undo-block,
      -- no-timeline-row behaviour unchanged.
      local bulk = state.timeline_bulk_reject
      local bulk_redo_of = state.timeline_bulk_redo_of
      local blocks = state.diff_blocks or {}
      if bulk and bulk_redo_of then
        -- REDO OF A BULK FILE-LEVEL REJECT (ruling 75, one register). The
        -- cross-file `u` restored these bytes with Neovim's own `:undo`
        -- (walk_impl.lua's generic buffer step -- this row is ordinary in
        -- every way except that it covers several hunks), so the tree's
        -- next state forward IS this rejection's bytes, all in ONE seq.
        -- Take it back with a single `:redo` -- the same trust
        -- `reject_block_at`'s own `redo_of` branch places in the tree,
        -- generalised to the whole file rather than one hunk.
        local pre_seq = buf_undo_seq(bufnr)
        local ok_redo = pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("silent redo")
        end)
        if not ok_redo then
          pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd("silent undo " .. tonumber(pre_seq))
          end)
          ok, err = false, "redo could not restore the rejected file"
        else
          break_undo_block(bufnr)
          M._tl_head_row(state, bulk_redo_of, false)
          state.timeline_obs = tl_observe(bufnr)
          for _, block in ipairs(blocks) do
            block.authority_extmark_id = nil
            block.incoming_extmark_id = nil
            block.incoming_extmark_ids = nil
            block.delete_extmark_id = nil
          end
        end
      else
        if bulk then
          break_undo_block(bufnr)
        end
        local bulk_pre_seq = bulk and buf_undo_seq(bufnr) or nil
        local bulk_members = bulk and {} or nil
        -- Last hunk first: each range is resolved immediately before its own
        -- replacement, so a line-count change in one hunk cannot shift a
        -- range already read for another. When NOT bulk, `u` is still per
        -- HUNK here (the shared callers above), so a boundary is asked for
        -- around each one; when bulk, no boundary is asked for until the
        -- whole loop is done, so every hunk lands in the SAME undo entry.
        for i = #blocks, 1, -1 do
          local block = blocks[i]
          local start_line, end_line, range_err = live_block_range(bufnr, block)
          if start_line then
            local restored = reject_restoration(bufnr, block, start_line, end_line)
            local pre_seq
            if not bulk then
              break_undo_block(bufnr)
              pre_seq = buf_undo_seq(bufnr)
            end
            local replaced = (end_line >= start_line) and (end_line - start_line + 1) or 0
            local restore_ok, restore_err = pcall(
              vim.api.nvim_buf_set_lines,
              bufnr,
              start_line - 1,
              end_line,
              false,
              restored
            )
            if not bulk then
              break_undo_block(bufnr)
            end
            if not restore_ok then
              ok = false
              err = tostring(restore_err)
            else
              local delta = #restored - replaced
              local anchor = park_decision_anchor(
                bufnr,
                start_line,
                start_line + math.max(#restored, 1) - 1
              )
              state.decisions[#state.decisions + 1] = {
                action = "reject",
                idx = i,
                block = block,
                delta = delta,
                pre_seq = bulk and bulk_pre_seq or pre_seq,
                post_seq = bulk and nil or buf_undo_seq(bufnr),
                anchor = anchor,
              }
              block.authority_extmark_id = nil
              block.incoming_extmark_id = nil
              block.incoming_extmark_ids = nil
              block.delete_extmark_id = nil
              record_decision(state, "reject_hunk", {
                hunk = i,
                model_index = block.model_index,
                row = start_line,
                old_count = #(block.old_lines or {}),
                new_count = #(block.new_lines or {}),
                source = "bulk_reject",
              })
              if bulk then
                bulk_members[#bulk_members + 1] = {
                  hunk = block.model_index or i,
                  old_count = #(block.old_lines or {}),
                  new_count = #(block.new_lines or {}),
                }
              end
            end
          else
            -- The hunk's position is no longer knowable, so there is nothing to
            -- restore it over. Say so rather than falling back to the whole-buffer
            -- snapshot: that fallback is the defect above.
            notify_one_line(
              "yana: reject left one hunk in place -- " .. tostring(range_err or "hunk invalidated"),
              vim.log.levels.WARN
            )
          end
        end
        if bulk and ok then
          break_undo_block(bufnr)
          local obs = tl_observe(bufnr)
          obs.regime = "buffer"
          obs.members = bulk_members
          tl_record(state, "file_rejected",
            "reject all " .. #bulk_members .. " hunk(s)", obs)
          state.timeline_obs = obs
        end
      end
      if ok then
        -- Truthful modified flag: after a reject the buffer holds the human's
        -- text, and the file may already hold something else (a bare `:w`
        -- during the review persists the live composition). Clean only when
        -- buffer and file actually agree. Ruling 79: a whole-buffer compare
        -- here was wrong on a PARTIAL reject-all -- a hunk this loop could
        -- not resolve (extmark invalidated) is still pending, and its green
        -- text alone must not force modified true. `state.diff_blocks` still
        -- lists every hunk of this review (this loop never prunes it; a
        -- successfully-rejected block has no live extmark left and is
        -- harmlessly skipped by the composer), so passing it lets the
        -- composer withhold exactly the ones still actually pending.
        M._recompute_modified(bufnr, state.diff_blocks, change.path)
        change.status = "rejected"
        -- Reject completed once the buffer is restored. on_reject failure is
        -- presentation only — same rule as accept: do not undo a durable action.
        notify_owner(state.opts.on_reject, change, "on_reject")
      end
    end
    if not ok then
      change.review_error = tostring(err or (accepted and "accept failed" or "reject failed"))
      if accepted then
        -- The default confined drift refusal used to say strictly
        -- less than the legacy in-place one. Everything above `err` is a prose
        -- string by the time it reaches here, so the reason CLASS and the
        -- fingerprint pair the binding schema delta requires were both lost on
        -- the path that actually ships.
        --
        -- The evidence exists: safety/diary.apply_operation returns it as a third
        -- value, apply_pending tail-returns all three, and shadow/apply's
        -- accept_composed parks it on `change.shadow_refusal` -- the change being
        -- the one object the applier and this recording site both already hold.
        -- accept_composed clears it at entry, so what lands here was gathered by
        -- THIS attempt.
        --
        -- Merged into the record just written, not recorded separately: a drift
        -- refusal is one decision with more said about it, and two rows would
        -- double-count refusals in every report. ledger.attach_refusal copies
        -- only the allowlisted schema fields onto the last `review_refused`
        -- decision, so the applier cannot rewrite actor, identity or timestamps,
        -- and it is total: a nil detail (any non-drift failure) leaves the record
        -- exactly as it was built.
        if M._record_shadow_accept_refusal(state, err) then
          return false
        end
      else
        notify_one_line(
          "yana: reject failed for " .. (change.rel or change.path) .. ": " .. tostring(err),
          vim.log.levels.ERROR
        )
      end
    end
    if state.opts.on_close then
      notify_owner(function()
        state.opts.on_close(state, accepted)
      end, change, "on_close")
    end
    M.cleanup(state)
    local st = pool_for_state(state)
    st.active = nil
    if ok and bufnr and vim.api.nvim_buf_is_valid(bufnr) then
      local ws = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
      local rel = change.rel or change.path
      local cap_ok, capture = pcall(require, "yana.timeline.edit_capture")
      if cap_ok and type(capture) == "table" and type(capture.attach) == "function" and rel then
        pcall(capture.attach, bufnr, ws, rel)
      end
    end
    if accepted and ok and applied and applied.reconcile_error then
      -- shadow/apply.lua has already brought this buffer back in step with the
      -- file it wrote, or named why it would not. Surface the refusal; do NOT
      -- downgrade the status, because the write HAPPENED and is journaled and
      -- only the buffer is out of step.
      notify_one_line(
        "yana: applied " .. (change.rel or change.path) .. " but could not reconcile its buffer: "
          .. tostring(applied.reconcile_error),
        vim.log.levels.WARN
      )
    end
    announce_state()
    if ok then
      -- R8: the file-level close settled -- accept or reject, decided by
      -- `change.status` (accept can still fail post-hoc reconcile above and
      -- still be an applied settle; reject's `ok` is unconditional true in
      -- this branch). `perform_whole_review_abort` sets `_abort_no_retrace`
      -- just before its own `finish_session(state, false)` call -- the ONLY
      -- caller that does -- so an abort is named `"abort"`, not
      -- `"reject_file"`, even though it reaches this exact same tail.
      M._emit_review_settled(
        bufnr,
        change.turn_id or change.turn_gen,
        state._abort_no_retrace and "abort" or (change.status == "accepted" and "accept_file" or "reject_file")
      )
    end
    schedule_queue_advance(state)
    return ok == true
  end
  if state.opts.preview then
    change.status = "rejected"
    -- Same contract as the accept/reject handlers below: a throwing owner
    -- callback must not skip teardown. A preview reached through enqueue also
    -- has to hand the queue back on, or closing it strands every change behind
    -- it -- the preview branch used to return without scheduling process_next.
    -- Guard the nil case OUTSIDE the wrapper: a closure is always truthy, so
    -- notify_owner's own nil check can never fire for it and a panel that
    -- passes no on_close would get a caught "call a nil value" plus a
    -- spurious ERROR notification instead of a silent skip.
    if state.opts.on_close then
      notify_owner(function()
        state.opts.on_close(state, accepted)
      end, change, "on_close")
    end
    M.cleanup(state)
    local st = pool_for_state(state)
    st.active = nil
    announce_state()
    -- R8: preview always closes as a reject (see `change.status` just above
    -- this branch) -- named `"reject_file"`, same as the ordinary case, so a
    -- waiter does not need to know preview is a distinct mode.
    M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "reject_file")
    schedule_queue_advance(state)
    -- Return contract: true only when the requested action completed. Preview
    -- never applies bytes, so an accept request closes without applying.
    return not accepted
  end
  -- Shortlist 3a: the legacy in-place accept path is removed. Real-tree writes
  -- route only through shadow_apply + on_shadow_accept (the journaled applier).
  change.review_error = "review reached the removed legacy accept path — shadow_apply was not configured"
  change.status = "pending"
  notify_one_line(
    "yana: refused to accept " .. (change.rel or change.path) .. " — legacy direct-write path is removed",
    vim.log.levels.ERROR
  )
  M.cleanup(state)
  local st = pool_for_state(state)
  st.active = nil
  announce_state()
  schedule_queue_advance(state)
  return false
end

-- WATCH THE BUFFER, because the paint is only correct at the moment it is
-- computed. F3 (property runner, 2026-08-19): a human edit inside a hunk moved
-- the incoming extmark along with the text and nothing recomputed it, so the
-- mark kept covering a row that was no longer the agent's. The shrunk trace is
-- one operation long. Every repaint already re-derives which rows are the
-- agent's by matching the hunk's own `new_lines`, so the only thing missing was
-- a reason to repaint.
--
-- Why this did not exist before, and what it costs. The engine deliberately had
-- no `nvim_buf_attach`, no `on_lines` and no `TextChanged`; positions came from
-- extmarks, which track edits for free, so nothing needed to watch. That is
-- true of POSITION and false of OWNERSHIP: an extmark follows the text it was
-- put on, it does not notice that the text changed underneath it. gitsigns
-- re-diffs on every `on_lines` for the same reason.
--
-- The callback runs in fast context, where buffer and UI calls are forbidden,
-- so it captures nothing and only schedules. One pending render at a time:
-- typing a line fires `on_lines` per keystroke and each would otherwise queue
-- its own full repaint.
local function attach_buffer_watch(state)
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  local function live_tree_root()
    local filetype = vim.bo[bufnr].filetype
    if filetype == "" then
      local matched_ok, matched = pcall(vim.filetype.match, { filename = vim.api.nvim_buf_get_name(bufnr) })
      if matched_ok and matched then
        filetype = matched
      end
    end
    local lang = filetype ~= "" and (vim.treesitter.language.get_lang(filetype) or filetype) or nil
    local ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
    if not ok or not parser then
      local uname = vim.loop.os_uname()
      local parser_suffix = "/treesitter/" .. uname.sysname .. "-" .. uname.machine .. "/parser/" .. tostring(lang) .. ".so"
      local parser_paths = {}
      if lang then
        parser_paths[#parser_paths + 1] = vim.fn.stdpath("state") .. parser_suffix
        if vim.env.USER and vim.env.USER ~= "" then
          parser_paths[#parser_paths + 1] = "/home/" .. vim.env.USER .. "/.local/state/nvim" .. parser_suffix
        end
      end
      for _, parser_path in ipairs(parser_paths) do
        if vim.fn.filereadable(parser_path) == 1 then
          pcall(vim.treesitter.language.add, lang, { path = parser_path })
          ok, parser = pcall(vim.treesitter.get_parser, bufnr, lang)
          if ok and parser then
            break
          end
        end
      end
      if not ok or not parser then
        return nil
      end
    end
    local parsed_ok, trees = pcall(parser.parse, parser)
    if not parsed_ok or not trees or not trees[1] then
      return nil
    end
    local root = trees[1]:root()
    if not root or (root.has_error and root:has_error()) then
      return nil
    end
    return root
  end

  local function direct_parent_for_line(root, line_1)
    local line = (vim.api.nvim_buf_get_lines(bufnr, line_1 - 1, line_1, false) or {})[1]
    if line == nil then
      return nil
    end
    local row = line_1 - 1
    local first_col = (line:find("%S") or 1) - 1
    local node = root:descendant_for_range(row, first_col, row, math.max(first_col, #line))
    if not node then
      return nil
    end
    while node:parent() do
      local parent = node:parent()
      local start_row = parent:start()
      if start_row ~= row then
        break
      end
      node = parent
    end
    return node:parent()
  end

  -- Ruling 73/89, generalised (paint-leak-o round 3): ownership-by-parent-
  -- identity answers "is this text part of the hunk's own scope", which is
  -- only a question TEXT can answer. A blank line (o/O immediately <Esc>'d,
  -- no matter which edge) has no node of its own -- tree-sitter resolves an
  -- empty row to whichever enclosing node's byte range happens to swallow
  -- it, which coincides with the hunk's own parent whenever the hunk sits
  -- at its block's own first/last statement. That coincidence is a parser
  -- artifact, not a sibling relationship, so a blank edge line is refused
  -- (never a CHILD) before parent identity is even consulted -- uniformly,
  -- for both the trailing edge (below a hunk's last row) and the leading
  -- edge (above a hunk's first row).
  local function edge_line_is_yana_owned(bufnr, edge_line, adjacent_hunk_line)
    local edge_text = (vim.api.nvim_buf_get_lines(bufnr, edge_line - 1, edge_line, false) or {})[1] or ""
    if edge_text:match("^%s*$") then
      return false
    end
    local root = live_tree_root()
    if not root then
      return false
    end
    local edge_parent = direct_parent_for_line(root, edge_line)
    local adjacent_parent = direct_parent_for_line(root, adjacent_hunk_line)
    -- REMOVED 2026-08-24: an override that called a module-level line owned by a
    -- block-level hunk (or the reverse) whenever the two rows were ADJACENT.
    -- The hunk-ownership rules already say the opposite -- a
    -- human's `def review(abc):` beside a `load()` body hunk is `[no band]
    -- buffer`, written to disk -- and the spec's own example draws it with a
    -- BLANK LINE between the two rows, which is the one spelling this override
    -- did not fire on. So the shipped behaviour matched the spec in the case the
    -- spec wrote down and inverted it in the adjacent case nobody wrote down:
    -- the human's `def` was withheld while the `pass` under it was written, and
    -- their two-line function landed on disk cut in half.
    -- Parent identity alone decides, as ruling 73/89 says. Rows:
    -- `r128_adjacent_module_sibling_is_buffer` (adjacent / blank_line / child).
    return edge_parent ~= nil and adjacent_parent ~= nil and edge_parent == adjacent_parent
  end

  --- Returns `all_absorbed`: true when every change in this batch landed
  --- inside (or trailing) some pending hunk, per the loop below -- i.e.
  --- nothing here is a FREE-STANDING edit. `tl_capture_human_edit` reads this
  --- (via `state.free_standing_edit`) to decide whether the drift since its
  --- last observation is a register step of its own or purely a hunk's own
  --- bytes (ruling 75/73/57 -- see that function's comment).
  local function absorb_human_edits(changes)
    local claimed = {}
    for i, block in ipairs(state.diff_blocks or {}) do
      -- Whether `end_line` below already reflects this edit's growth. The
      -- authority extmark auto-adjusts as edits land INSIDE it -- that is
      -- the whole point of tracking a hunk's position via an extmark -- so
      -- by the time this runs (always after the edit; deferred via
      -- `vim.schedule`), its span already covers an interior insertion with
      -- no help from us. The fallback path (no authority mark yet) reads a
      -- STATIC end row from `#block.new_lines` instead, which still needs
      -- the manual correction below. MEASURED: adding `extra_lines`
      -- unconditionally double-counted the authority path's own auto-growth
      -- -- typing one interior line into a pending 3-line hunk grew its
      -- live range by 2, not 1, and absorbed the next ordinary buffer line
      -- (the fixture's "gamma") along with it.
      local tracked_live = block.authority_extmark_id ~= nil
      local start_line, end_line = live_block_range(bufnr, block)
      local extends_block = false
      local extra_lines = 0
      -- paint-leak-o round 3: rows the CHILD/SIBLING test below refuses at
      -- either edge, in this batch, that leave the raw authority mark
      -- (read above, already gravity-grown over them -- MEASURED) tainted.
      -- `refused_edge` drives the unconditional correction after the loop:
      -- by construction, the band may only ever be rebuilt from rows this
      -- function actually decided it owns.
      local refused_edge = false
      -- Rows absorbed at the LEADING edge (owned) or excluded there
      -- (refused) both raise the window's own floor for the REST of this
      -- batch -- see the MEASURED note below `leading_pure_insert`.
      local leading_shift = 0
      -- `ci` indexes `claimed` (ap/filelevel-2): a change absorbed by one
      -- block must not be re-absorbed by the next.
      for ci, change in ipairs(changes) do
        if start_line then
          local effective_start_line = start_line + leading_shift
          local effective_end_line = end_line + extra_lines
          local pure_insert = change.last_orig == change.first
          -- paint-leak-o / R1+R2: a pure insertion positioned exactly at
          -- the hunk's OUTER LEADING edge (`O` on the hunk's own first
          -- row, or immediately above it -- both land here because the
          -- authority mark's own gravity already pulled the new row
          -- inside its live range by the time this runs). Ruling 73/89
          -- decides ownership here exactly as it already does for the
          -- trailing edge below -- a CHILD (same scope as the hunk's own
          -- first row) is absorbed; a SIBLING (or blank, or unparsable)
          -- is refused. This is NOT a positional replacement of the
          -- ownership rule -- it is the same rule, applied symmetrically.
          local leading_pure_insert = pure_insert and change.first == effective_start_line - 1
          -- A pure insert whose live text is already byte-identical to the
          -- hunk's OWN known first row can never be a foreign sibling: the
          -- hunk has already claimed exactly that text as its proposal
          -- (decision 57's converse -- content beats position). This is
          -- what keeps the product's OWN re-adoption of a decision it just
          -- undid or redone (`pop_decision`/`redo_local`, both of which
          -- issue a native `:undo`/`:redo` and THEN synchronously fix up
          -- `block.new_start_line`/`new_end_line` and the authority mark
          -- themselves, before this deferred `on_lines` batch ever runs)
          -- from being relitigated here as if it were an unexplained human
          -- edit. Position alone cannot tell "the hunk's own first row,
          -- restored" from "a human O opened right there" -- both land at
          -- the identical `effective_start_line - 1` -- but content can:
          -- only a row the hunk has never claimed needs the treesitter
          -- CHILD/SIBLING call at all.
          local leading_row_now = (vim.api.nvim_buf_get_lines(bufnr, effective_start_line - 1, effective_start_line, false) or {})[1]
          local leading_matches_known = leading_pure_insert
            and leading_row_now ~= nil
            and leading_row_now == (block.new_lines or {})[1]
          local leading_owned = leading_pure_insert
            and (leading_matches_known or edge_line_is_yana_owned(bufnr, effective_start_line, effective_start_line + 1))
          -- MEASURED: typing real text into a refused leading row replays,
          -- keystroke by keystroke, as SAME-ROW edits (`last_orig ==
          -- first + 1`, not a pure insert) at the SAME `first`. That
          -- position sits exactly AT `interior`'s lower bound, not past
          -- it -- unlike a refused TRAILING row, which sits one past its
          -- own bound and is excluded by the plain numeric checks below
          -- for the rest of the batch with no help needed. Only the
          -- leading side needs its floor raised so those replays fail
          -- `interior` too, not just the row-opening event itself.
          if leading_pure_insert then
            refused_edge = refused_edge or not leading_owned
            -- The floor must rise by however many rows this insert actually
            -- added (`last_new - first`, since a pure insert's old side is
            -- empty by definition), not a flat one row. A single `O<Esc>`
            -- and a multi-line restore (e.g. undoing a reject that puts an
            -- N-line hunk back -- `pop_decision`'s own native `:undo`, which
            -- this batch sees exactly like any other buffer edit) both reach
            -- this branch; a flat `+1` left every LATER block's floor N-1
            -- rows short of where its content actually moved to, the same
            -- class of drift the `new_start_line`/`new_end_line` correction
            -- below exists to prevent.
            leading_shift = leading_shift + math.max(0, change.last_new - change.first)
            effective_start_line = start_line + leading_shift
          end
          -- `first` names the first old buffer row that changed.
          local interior = change.first >= effective_start_line - 1
            and change.first <= effective_end_line - 1
            and not leading_pure_insert
          -- A newline entered exactly on the hunk's LAST row (`o`, or
          -- `<CR>` at end of line) creates a brand-new row ONE PAST the
          -- hunk's own last row -- `first == end_line` in these units --
          -- which the authority extmark's own end position never sees: a
          -- mark anchored at row R is untouched by a row born at R+1,
          -- because that insertion never touches row R itself (gravity
          -- only disambiguates an edit landing AT R, not after it).
          -- MEASURED 2026-08-23: `first <= end_line - 1` alone excluded
          -- this case outright, so typing `o` on a single-line hunk's own
          -- (only) row was never absorbed at all. It still belongs to the
          -- hunk (the comment above always said so) -- it just needs
          -- manual growth the interior case does not. Require a PURE
          -- insertion there (`last_orig == first`, zero old rows
          -- consumed) so editing the FOLLOWING row's own content --
          -- which also has `first == end_line` but consumes that row --
          -- is correctly excluded ("typing on the following row does
          -- not [belong to the hunk]").
          local trailing_pure_insert = change.first == effective_end_line and pure_insert
          local trailing_owned = trailing_pure_insert
            and edge_line_is_yana_owned(bufnr, effective_end_line + 1, effective_end_line)
          if trailing_pure_insert then
            refused_edge = refused_edge or not trailing_owned
          end
          local leading_insert = leading_pure_insert and leading_owned
          local trailing_insert = trailing_pure_insert and trailing_owned
          -- Ruling 2026-08-25: interior typing is NOT absorbed into
          -- `block.new_lines`; the authority mark grows and the paint shows a
          -- gap. Only the treesitter-gated edges may extend the proposal.
          if trailing_insert or leading_insert then
            extends_block = true
            claimed[ci] = true
            -- Interior growth is already reflected in `end_line` above
            -- (the extmark auto-adjusted for us); adding it again here
            -- double-counts (MEASURED: absorbed the fixture's next
            -- ordinary line, "gamma", along with the human's own).
            -- Trailing growth is never auto-adjusted (previous
            -- paragraph), so it is always added, authority-tracked or
            -- not; the fallback path (no authority mark) tracks nothing
            -- automatically either way and needs both added, as before.
            -- A leading CHILD's growth, like interior's, IS auto-reflected
            -- when tracked live (the mark's own gravity already counted
            -- it in `start_line`/`end_line` above), so it follows
            -- interior's rule, not trailing's.
            if trailing_insert or not tracked_live then
              extra_lines = extra_lines + math.max(0, change.last_new - change.last_orig)
            end
          end
        end
      end
      if start_line and extends_block then
        -- Mirrors the `extra_lines` guard just above: when this block is
        -- LIVE-TRACKED, its authority mark was placed fresh (or its own
        -- gravity already pulled a newly-OWNED leading row inside the live
        -- range this function just read as `start_line`) -- either way,
        -- `start_line` already names the hunk's true current position with
        -- no help from this function. Adding `leading_shift` here too
        -- double-counts it: for a leading insert this block DECIDED it
        -- owns (`leading_insert=true`, this branch's only way in besides
        -- `interior`), the row `leading_shift` counts is the very row
        -- `start_line` already points at, so shifting PAST it walks the
        -- window off the front of the hunk's own now-legitimate first row
        -- -- MEASURED: undoing a rejected pure-insertion hunk (the
        -- product's own `pop_decision`, not a human edit) reconstructed the
        -- mark at the correct position, then this double-shift walked
        -- `start_line` past it, computed an inverted (empty) window, and
        -- `block.new_lines` got overwritten with {} -- the hunk vanished
        -- from its own review. The fallback path (no authority mark) still
        -- needs the shift: nothing else ever tracks that hunk's position
        -- for it.
        if not tracked_live then
          start_line = start_line + leading_shift
        end
        end_line = end_line + extra_lines
        local live = {}
        if end_line >= start_line then
          live = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
        end
        if not lines_equal(live, block.new_lines or {}) then
          -- Decision 57: once the human changes text inside a pending hunk,
          -- that text is the proposal. The same source then drives paint,
          -- accept, reject, and decision undo; no path may retain the old
          -- agent-only model and disagree with the buffer.
          block.new_lines = live
          block.new_start_line = start_line
          block.new_end_line = math.max(end_line, start_line - 1)
          -- Drop the pre-absorb authority mark. highlight_blocks would otherwise
          -- re-capture a one-line live range from it and leave absorbed rows
          -- outside the band (row 82 split; reject then fails to withdraw them).
          if block.authority_extmark_id then
            pcall(vim.api.nvim_buf_del_extmark, bufnr, AUTH_NS, block.authority_extmark_id)
            block.authority_extmark_id = nil
          end
          if state.model_hunks and block.model_index and state.model_hunks[block.model_index] then
            local mh = state.model_hunks[block.model_index]
            mh.new_count = #live
            mh.new_end_line = block.new_end_line
          end
          -- The PROPOSAL changed, so the turn's register model changes with
          -- it. `M.reopen_from_register` anchors each hunk in the buffer by
          -- the lines the register says it holds; for an absorbed hunk those
          -- are the lines the human made (decision 57), not the agent's
          -- turn-start text -- which is no longer in the buffer as a run and
          -- would be withdrawn as "not in the buffer" (P120
          -- absorb_accept_undo: undo-of-accept lost the absorbed line).
          -- Keyed by the same ordinal the register labels its rows with.
          local change = state.change
          if type(change) == "table" then
            local absorbed = change._retrace_absorbed
            if type(absorbed) ~= "table" then
              absorbed = {}
              change._retrace_absorbed = absorbed
            end
            absorbed[block.model_index or i] = vim.deepcopy(live)
          end
        end
      end
      if not extends_block and leading_shift > 0 then
        -- A REFUSED leading insertion still physically displaces the
        -- hunk's own content by `leading_shift` rows, even though none of
        -- it was absorbed (nothing was added to `block.new_lines`).
        -- `block.new_start_line`/`new_end_line` must track that
        -- displacement, or the fallback triggered below (dropping the
        -- tainted mark) would have `capture_live_authority_ranges` search
        -- for the hunk's content at its OLD, pre-insertion position and
        -- find the human's refused row sitting there instead (MEASURED:
        -- painted only the hunk's first line, dropping the rest -- the
        -- fallback window was one row short of where the content actually
        -- moved to).
        block.new_start_line = (block.new_start_line or start_line) + leading_shift
        block.new_end_line = (block.new_end_line or end_line) + leading_shift
        if state.model_hunks and block.model_index and state.model_hunks[block.model_index] then
          state.model_hunks[block.model_index].new_end_line = block.new_end_line
        end
      end
      -- paint-leak-o / R2: whether or not anything was legitimately
      -- absorbed above, a refused edge this batch may still have left the
      -- RAW authority mark's gravity-grown span uncorrected (the branch
      -- above only drops the mark when a genuine absorb changed
      -- `block.new_lines`). Drop it here too so the next `highlight_blocks`
      -- pass (`capture_live_authority_ranges`) falls back to
      -- `block.new_start_line`/`block.new_end_line` -- which this function
      -- only ever advances past rows it actually decided to own -- and
      -- rebuilds the band anchored there instead of on the tainted span.
      -- By construction, the band can never cover a row absorb refused.
      if refused_edge and block.authority_extmark_id then
        pcall(vim.api.nvim_buf_del_extmark, bufnr, AUTH_NS, block.authority_extmark_id)
        block.authority_extmark_id = nil
      end
    end
    local all_absorbed = true
    for ci = 1, #changes do
      if not claimed[ci] then
        all_absorbed = false
        break
      end
    end
    return all_absorbed
  end
  state.watch_pending = false
  state.watch_detached = false
  -- RACE (issue 15): the classification below runs deferred
  -- (`vim.schedule`, see the DEFERRED comment further down for why it must
  -- stay deferred) so it lands strictly after the edit that triggered it.
  -- But a decision key (`ct`/`co`/`cA`/etc.) reads `state.free_standing_edit`
  -- through `tl_capture_human_edit` SYNCHRONOUSLY, and nothing previously
  -- forced this callback to run first -- a human who types then immediately
  -- decides (exactly what a real operator does, and exactly what
  -- `nvim_feedkeys(..., "x", ...)` does back-to-back in this suite) could
  -- have the decision fire while `state.watch_pending` was still true and
  -- `state.watch_changes` still unprocessed. `tl_capture_human_edit` then
  -- read the STALE `free_standing_edit` left over from the PREVIOUS
  -- decision boundary (false, since it resets it every time) and silently
  -- downgraded a genuine free-standing edit to an `absorbed_edit` marker --
  -- MEASURED in the issue-15 suite: `watch_pending=true watch_changes_n=2` at
  -- the second
  -- `tl_capture_human_edit` call, with a free-standing edit (line 6, nowhere
  -- near any of the three hunks) sitting unclassified in `watch_changes`.
  -- `process_pending_watch` is now a named, idempotent step (guarded by
  -- `state.watch_pending` itself, so calling it twice is a no-op the second
  -- time) reachable two ways: the scheduled path below, unchanged, for the
  -- ordinary case where nothing else needs the answer before the next
  -- event-loop tick; and `state.flush_pending_watch`, called from
  -- `tl_capture_human_edit` (the single reader of `free_standing_edit`)
  -- before it reads the flag, forcing this same classification to run NOW
  -- when a decision cannot wait for the scheduler. Same code, same result,
  -- either way -- only the race is removed.
  local function process_pending_watch()
    if not state.watch_pending then
      return
    end
    state.watch_pending = false
    local changes = state.watch_changes or {}
    state.watch_changes = {}
    if state.watch_detached or state.closed then
      return
    end
    if state.reload_restaging then
      return
    end
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    if not state.diff_blocks or #state.diff_blocks == 0 then
      -- Nothing pending to absorb into: this edit is free-standing by
      -- construction.
      state.free_standing_edit = true
      return
    end
    if not absorb_human_edits(changes) then
      state.free_standing_edit = true
    end
    -- Ruling 79: every keystroke reaches here via `on_lines`, including
    -- one Neovim's own machinery just marked the buffer modified for
    -- (that is real-edit behaviour Yana does not own or suppress). A
    -- keystroke absorbed into a pending hunk above never crossed into
    -- the buffer's own half, so that default has to be corrected back;
    -- one outside every hunk is genuinely buffer-owned and this leaves
    -- it true. Single choke point for both, decided fresh each time
    -- (ruling 80), never cached across edits.
    M._recompute_modified(state.bufnr, state.diff_blocks, state.change and state.change.path)
    -- Do NOT timeline-capture here. In-hunk typing is absorbed into
    -- block.new_lines (decision 57); the human_edit row is sealed at the
    -- next decision boundary (accept/reject) as before. Emitting a row
    -- per absorb would leave an orphan after reject ("word goes with it")
    -- whose undo_seq hash no longer matches the buffer.
    render_blocks(state.bufnr, state.diff_blocks, {
      site = "buffer_watch",
      model = state.model_hunks,
      model_source = state.model_source,
      change = state.change,
      opts = state.opts,
    })
    local snap = diff.buffer_bytes_snapshot(state.bufnr)
    if snap then
      state.staged_text = snap
      state.latest_undo_seq = buf_undo_seq(state.bufnr)
    end
  end
  state.flush_pending_watch = process_pending_watch
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, _, first, last_orig, last_new)
      if state.watch_suspended then
        return
      end
      state.watch_changes = state.watch_changes or {}
      state.watch_changes[#state.watch_changes + 1] = {
        first = first,
        last_orig = last_orig,
        last_new = last_new,
      }
      if not state.restoring_reload then
        state.reload_redo_guard = nil
        state.reload_restore_seq = nil
      end
      -- Returning true detaches. Do it once the review is gone so a closed
      -- review cannot keep repainting a buffer it no longer owns.
      if state.watch_detached or state.closed then
        return true
      end
      -- No pending hunk anywhere in this file (issue 15 class):
      -- there is nothing left to absorb into, so this edit is free-standing
      -- BY CONSTRUCTION -- the same fact `process_pending_watch` records for
      -- the identical condition when it gets to run deferred. This early
      -- exit used to detach WITHOUT ever setting `state.free_standing_edit`,
      -- leaving whatever stale value the last decision boundary reset it to
      -- (always false) -- so an edit typed after a file's last hunk was
      -- decided, but before the review finished closing, silently read as
      -- `absorbed_edit` even though there was no hunk left for it to be
      -- absorbed into. Set the flag inline here, since there is no batch to
      -- defer for this case -- the detach still happens on the same return.
      if not state.diff_blocks or #state.diff_blocks == 0 then
        state.free_standing_edit = true
        return true
      end
      -- CORRECTED 2026-08-19, after an adversary review found the comment here
      -- describing a guard that did not exist. A `state.suppress_watch` flag
      -- was read at this point and assigned nowhere, so the claim that the
      -- product's own edits were excluded from this callback was simply false.
      -- They are NOT excluded: staging, a reject restoration and a re-stage
      -- after a reload all reach here, and each schedules one extra repaint.
      --
      -- That is harmless, and saying why is better than reinstating a flag to
      -- look tidy. The repaint is idempotent — it re-derives every span from
      -- the live authority ranges and the hunks' own content — and it is
      -- deferred, so it lands after the product's edit has finished rather
      -- than inside it. The real protection against recursion is
      -- `watch_pending` plus `vim.schedule` below, and that one exists. A dead
      -- flag claiming to be a safety mechanism is worse than no flag, because
      -- the next person to add a non-idempotent edit path would trust it.
      -- DEFERRED, and the reason is worth recording because the synchronous
      -- version was written first and reverted. Extmark writes ARE permitted in
      -- fast context, so repainting straight from `on_lines` works — but
      -- `on_lines` also fires for the product's OWN buffer writes (staging, a
      -- reject restoration, a re-stage after a reload), and repainting inside
      -- one of those rebuilds AUTH_NS while the caller is still holding the ids
      -- it is mid-decision on. The ordinary-undo regression case started
      -- hitting the review's floor refusal. Scheduling puts the repaint after
      -- the product's edit has finished, which costs one loop turn and removes
      -- the reentrancy entirely. (The `flush_pending_watch` synchronous path
      -- added for the race above reuses the same idempotent function rather
      -- than adding a second, non-deferred writer of this state.)
      if state.watch_pending then
        return
      end
      state.watch_pending = true
      vim.schedule(process_pending_watch)
    end,
  })
end

function M.cleanup(state)
  if not state then
    return
  end
  -- Stop the watcher before anything else is torn down: its scheduled render
  -- would otherwise land on a half-dismantled review.
  state.watch_detached = true
  -- A preview owns a tab and a scratch buffer that nothing else will ever
  -- close. Leaking them per open is not just untidy: the scratch keeps the
  -- "yana://diff-theme-preview" buffer NAME, so the next preview's
  -- nvim_buf_set_name fails (E95) and every name-keyed check then matches the
  -- stale corpse instead of the live review.
  if state.preview_tab and vim.api.nvim_tabpage_is_valid(state.preview_tab) then
    -- Resolve the index from the handle at close time so a user who reordered
    -- tabs does not get an unrelated one closed. Skip when it is the only tab
    -- (E784), where there is nothing to close back to.
    if #vim.api.nvim_list_tabpages() > 1 then
      pcall(vim.cmd, "tabclose! " .. vim.api.nvim_tabpage_get_number(state.preview_tab))
    end
    state.preview_tab = nil
  end
  if state.opts and state.opts.preview and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr) then
    pcall(vim.api.nvim_buf_delete, state.bufnr, { force = true })
  end
  local bufnr = state.bufnr
  if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, AUTH_NS, 0, -1)
    -- The decision anchors go with the review that parked them. They are the
    -- only marks a repaint does not clear, so this is the one place they die.
    vim.api.nvim_buf_clear_namespace(bufnr, ANCHOR_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, HINT_NS, 0, -1)
    local keys = state.keys or {}
    for _, key in ipairs(keys) do
      pcall(vim.keymap.del, "n", key, { buffer = bufnr })
      pcall(vim.keymap.del, "v", key, { buffer = bufnr })
    end
    -- POST-REVIEW RETRACE (FIX-UNDO lane, operator ruling row 72,
    -- 2026-08-21). This review's own `u`/`U`/`<C-r>` just died above with
    -- the rest of `keys`; the buffer is otherwise Neovim's own again.
    -- Reinstall `u`/`<C-r>` ONLY, buffer-local to exactly this buffer,
    -- dispatching to cross-file retrace when (and only when) this
    -- buffer's undo tree is still precisely where Yana's own last action
    -- left it -- `lua/yana/timeline/retrace.lua`'s seam comment states
    -- the exact condition. Any buffer whose tree has since moved (the
    -- operator typed, or already ran plain undo/redo) gets Neovim's own
    -- undo/redo, unchanged. Never `U`: ruling 48's turn-wide reset has no
    -- cross-review meaning once a review has closed, and reusing the
    -- letter for something else here would be its own defect.
    --
    -- WHY `u` AND `<C-r>` ARE NOT SYMMETRIC IN WHAT THEY GO ON TO DO, though
    -- they are reinstalled together here and this will look like a bug if you
    -- read only this function. Both are reinstalled as the cross-file retrace
    -- keys. `u` goes on retracing decisions across files, which is all it ever
    -- does. `<C-r>` has a SECOND job that nothing in this function performs and
    -- that is easy to miss: when the buffer it moves forward lands exactly on a
    -- withdrawn review's own proposal, the per-buffer rewind reconciler reopens
    -- that review (operator ruling 2026-08-25; see the whole-review rewind's
    -- forward clause). That does NOT happen here and is NOT a property of this
    -- keymap -- the retrace handler just runs Neovim's own redo, and the reopen
    -- is driven entirely by the surviving rewind record plus a content-hash
    -- match. So this reinstall is symmetric on purpose: the asymmetry lives in
    -- whether a withdrawn record exists for the path, not in the key.
    -- ABORT IS THE ONE EXCEPTION -- the class of close that undoes every
    -- decision it made, and so must release these maps with them (operator
    -- ruling 2026-08-25; see `M.abort_active`). Every other close leaves a
    -- real decision behind
    -- (something accepted, something rejected, something the human typed)
    -- for `u`/`<C-r>` to retrace across files. An abort undoes ALL of that
    -- first -- there is nothing left anywhere for a retrace to walk back
    -- into -- so reinstalling these maps would hand the operator a `u` that
    -- LOOKS like Neovim's own key but silently dispatches to a cross-file
    -- walk with nothing on it. `M.abort_active` sets this flag on every
    -- state (the active review and each rewound sibling) it tears down
    -- through this function, exactly once, for exactly that reason.
    if not state._abort_no_retrace then
      local retrace_ok, retrace = pcall(require, "yana.timeline.retrace")
      if retrace_ok and retrace.install_post_review_keys then
        retrace.install_post_review_keys(bufnr)
      end
    end
  end
  if state.augroup then
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
  end
  restore_review_winhl(state)
end

-- The review buffer exists but focus_buf could not display it in any window,
-- so its buffer-local keymaps are unreachable and the queue would stall
-- forever waiting on a review the user can never resolve. Unlike
-- finish_session, this must NOT write disk: `after` is already there and has
-- to stay there. Status is left "pending" (not "rejected"/"accepted") so the
-- panel keeps flagging it as unresolved, and the queue is allowed to drain
-- past it.
local function abort_undisplayable_review(state)
  -- Record why so a later accept/reject on this still-pending row can retry
  -- the review instead of printing hunk advice for hunks that were never
  -- painted (there is no active session to resolve against).
  state.change.review_error = "review could not be displayed in any window"
  M.cleanup(state)
  local st = pool_for_state(state)
  st.active = nil
  announce_state()
  schedule_queue_advance(state)
end

--- RULING #100 (operator, 2026-08-23): the press this review has nothing
--- left to answer. The review closes, saying NOTHING, and the press becomes
--- plain Neovim undo -- `u` is a key shared with the editor, and a press
--- yana does nothing for must look exactly as it would if yana's keymap were
--- not installed.
---
--- ORDER MATTERS AND IS THE FIX. The review is torn down BEFORE the buffer
--- moves. Everything the operator filmed on 2026-08-23 -- "hunk N no longer
--- matches the buffer -- its highlight is withdrawn" x3, render_check's
--- `model_extent` violation, one green band running line 1 to the last line
--- -- was a single repaint of a review whose hunks no longer had anywhere to
--- sit. Nothing repaints here because by the time the bytes move there is no
--- review left to repaint.
---
--- THE HUNKS GO WITH IT (ruling 71: pending is not precious; they were never
--- on disk). `status` becomes "rejected" because that is what the outcome
--- IS, byte for byte: the buffer is back to the state before the agent's
--- proposal and nothing was written -- the same outcome `cb` produces on a
--- review with no decisions, reached by a different gesture. Leaving it
--- "pending" would leave the panel offering hunks that are no longer
--- anywhere.
function M._withdraw_for_plain_undo(state, retrace)
  local change = state.change
  local bufnr = state.bufnr
  state.diff_blocks = {}
  state.watch_detached = true
  change.status = "rejected"
  change.review_error = nil
  M.cleanup(state)
  local st = pool_for_state(state)
  if st.active == state then
    st.active = nil
  end
  -- NO `edit_capture.attach` HERE, unlike `finish_session`. That handover
  -- exists so the operator's TYPING after a decision is recorded as human
  -- history; this close is followed immediately by yana's own `:undo` and then
  -- by however many plain presses the operator makes, and capturing those as
  -- `human_edit` rows re-populates the very register this press just proved
  -- empty. MEASURED (green-attempt2.log): with the attach in place, the three
  -- presses after the close minted three rows and the next `u` refused with
  -- "could not undo a.py -- buffer epoch mismatch for row tl-b3ace-...", which
  -- is the loud dead-`u` #100 exists to remove, re-created by the fix for it.
  -- ANNOUNCED, BUT NOT ADVANCED. `announce_state` refreshes the panel so the
  -- turn's remaining files are still visible and still openable. What is
  -- deliberately NOT done here is `schedule_queue_advance`: every other close
  -- is a DECISION, and auto-advancing to the next file is that decision's
  -- natural continuation. This one is not a decision -- it is the operator
  -- walking out below a review with an undo key -- and popping some other
  -- file's review open as a side effect of `u` is exactly the "yana took a
  -- step I did not ask for on a key that is Neovim's" that RULING #100 is
  -- about. Nothing is stranded: the parked/queued reviews stay in the pool and
  -- in the panel, and the next deliberate gesture opens them.
  announce_state()
  -- R8: ruling #100 says this press is SILENT (no `vim.notify` line) --
  -- exactly the "asserts absence" shape issue 54 bucket (b) named
  -- (`r113_r100_register_exhausted_is_silent`, `r113_undo_past_register_floor`).
  -- Silent to the OPERATOR does not mean unobservable to a test: this is
  -- still a review-state transition that fully applied (the review closed,
  -- `M.cleanup` released its keymaps/marks), so it gets the same positive
  -- signal every other transition does -- a row can wait_settled() for this
  -- instead of asserting silence after a fixed delay.
  M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "undo_withdraw")
  -- YANA'S OWN TRANSACTION (KI-1 ruling 2026-08-24 meeting ruling #100). This
  -- function has ALREADY withdrawn the review, by hand, for this very press --
  -- and the undo below is Yana issuing the operator's press on its behalf,
  -- which crosses the proposal insertion. Left observable, the rewind
  -- reconciler sees that crossing, withdraws a review that is already gone and
  -- SAYS SO: "yana: undo crossed the proposal insertion in a.py -- the whole
  -- review was withdrawn". #100 requires this press to be silent, so the guard
  -- belongs here exactly as it does around `U` and abort.
  --
  -- THE WATCH SURVIVES THIS WITHDRAWAL, MARKED (operator ruling 2026-08-25:
  -- "yes redo should reopen the hunk -- make it be yana owned at that
  -- boundary"). It used to be DROPPED here, on the reasoning that this review
  -- was over and travelling forward must not resurrect it. That reasoning is
  -- overruled for `u` and only for `u`: the rewind ruling's forward clause
  -- promises that crossing the insertion forward "restores the exact proposal
  -- bytes and reopens the SAME review identity with every hunk pending again",
  -- and dropping the record made that promise unkeepable through this door
  -- while it was kept through `:earlier`/`:later` -- which withdraw via
  -- `rewind_withdraw`, keep the record, and restore correctly. The same review
  -- therefore came back or did not purely by which key withdrew it. Found by
  -- the review-state property fuzzer at seed 87007 (`u, redo`); pinned by
  -- `r129_rewind_redo_key_reopens_at_boundary`.
  --
  -- AN ABORT IS STILL DIFFERENT and still drops the record outright: see
  -- `M.abort_active`, which calls `M._rewind_forget_path` for exactly the
  -- reason this call site no longer does. An abort is the operator discarding
  -- the review deliberately; this is the operator stepping backward through
  -- history with a key that is Neovim's too, and the ruling says that step is
  -- reversible.
  --
  -- THE CARVE-OUT IS NOT "`<C-r>` IS NOW YANA'S". Nothing about the keymap
  -- changes here. What comes back is gated in `rewind_reconcile` on the
  -- CONTENT HASH (`at_proposal` against `rec.open_hash`), so a forward move
  -- that lands anywhere other than exactly the proposal reopens nothing and
  -- stays an ordinary editor redo, which is what keeps ruling #100's silence
  -- rows true. `r129`'s `control` phase measures precisely that edge.
  --
  -- THE RECORD IS KEPT FOR EVERY REVIEW, INCLUDING A REINTEGRATED ONE.
  -- Ownership at this boundary is ASYMMETRIC (operator ruling 2026-08-25, as
  -- adjudicated by the cursor pane; see the whole-review rewind ruling), and
  -- the asymmetry is the whole of it:
  --
  --   BACKWARD, Yana DECLINES. A reintegration writes no bytes and so mints no
  --   insertion at its own sequence; ordinary operator history below it must
  --   never be treated as crossing a proposal insertion, and no new floor is
  --   invented. This function is that decline: it closes the review under
  --   ruling #100, silently, and hands the press to plain undo.
  --
  --   FORWARD, Yana CLAIMS. The review still INHERITS the original insertion
  --   for restorability, so a forward move landing on exactly the proposal
  --   CONTENT reopens the same review identity with every hunk pending --
  --   the operator's words, "just as if it was being done for the first
  --   time". Landing anywhere else reopens nothing.
  --
  -- An earlier revision of this lane forgot the record whenever
  -- `undo_pre_stage_seq == undo_open_seq`, reading the spec's backward
  -- justification as settling forward too. It does not -- the spec was SILENT
  -- there. Forgetting protected the backward case by destroying the forward
  -- one, and `r113_undo_past_register_floor`'s retargeted redo half is what
  -- now holds this honest: with the record forgotten it reds with "the buffer
  -- is byte-identical to the proposal but no review reopened".
  --
  -- Ruling #100 is not in tension with this. Its silence governs a press Yana
  -- has nothing to restore FOR; it does not forbid a reopen when a withdrawn
  -- proposal is under the cursor again by content.
  M._rewind_mark_withdrawn(change and change.path)
  local ok, err = pcall(M._rewind_suppress, function()
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent undo")
    end)
  end)
  if not ok then
    log.write("WARN", "yana.inline_diff floor undo: " .. tostring(err))
  end
  -- The move above was YANA's, so the register head follows the buffer --
  -- otherwise the NEXT press reads this one as the operator moving the tree
  -- out of band and refuses with "undo sequence drift", forever.
  pcall(function()
    require("yana.timeline.record").absorb_own_history_move(bufnr)
  end)
  -- ...and `<C-r>` is Neovim's again too: see `retrace.forget_walk_redo`.
  if retrace and type(retrace.forget_walk_redo) == "function" then
    pcall(retrace.forget_walk_redo)
  end
  log.write(
    "INFO",
    "yana.inline_diff undo floor: " .. tostring(change.rel or change.path)
      .. " -- cross-file register empty and this review was retrace-reopened; review closed silently, "
      .. "press handed to plain Neovim undo (ruling 100)"
  )
end

local function all_resolved(state)
  return #state.diff_blocks == 0
end

--- Close the review once every hunk has been decided -- as an ACCEPT only if
--- something was actually accepted.
---
--- This passed `true` unconditionally until 2026-08-19, so rejecting every hunk
--- one at a time with `co` ran the ACCEPT path. The composition of an
--- all-rejected turn equals the original, so the bytes were right and nothing
--- was lost -- which is exactly why it survived: a same-content rewrite is
--- invisible to a content check, which the identity regression case catches. What it
--- did do was write: a new inode, a new mtime, a diary row and an fsync, on a
--- path `the fixed safety contract` states performs no real-disk write at all. `cb` honoured
--- that absolute; `co` until the list emptied did not, and no
--- row covered it. Found by the timeline break-test lane while arranging its
--- fixtures, and confirmed by an independent probe asserting identity rather
--- than bytes.
---
--- A MIXED turn still accepts. The question is not "was anything rejected" but
--- "is there anything to write": one accepted hunk means the composition
--- differs from the original and must go through the applier.
local function try_finalize(state)
  if not all_resolved(state) then
    return
  end
  local accepted_any = false
  for _, d in ipairs(state.decisions or {}) do
    if d.action == "accept" then
      accepted_any = true
      break
    end
  end
  if not accepted_any then
    for _, d in ipairs(state.sealed_decisions or {}) do
      if d.action == "accept" then
        accepted_any = true
        break
      end
    end
  end
  finish_session(state, accepted_any)
end

local function contains_nul(bytes)
  return type(bytes) == "string" and bytes:find("\0", 1, true) ~= nil
end

local function binary_reason(change)
  if type(change) ~= "table" then
    return nil
  end
  if change.reason_class == "binary_content" then
    return "binary_content"
  end
  if contains_nul(change.before) or contains_nul(change.after) then
    return "binary_content"
  end
  return nil
end

-- ===========================================================================
-- WHOLE-REVIEW REWIND AT THE SINGLE INSERT BOUNDARY
-- KI-1, operator ruling 2026-08-24.
--
-- THE CONTRACT, and it is deliberately not per-hunk. Accepting a hunk in an
-- open buffer moves no bytes, so four accepts share ONE undo sequence and
-- there is no crossed range that can tell one accept from four. The only
-- state Neovim can represent honestly is the atomic proposal insertion, so
-- that single boundary is the whole of it:
--
--   * crossing it BACKWARD (`u` past it, `:earlier`, `:later` onto another
--     branch, `g-`, `:undo {seq}` -- any Neovim time travel) withdraws the
--     WHOLE review and every Yana decision in it, together;
--   * crossing it FORWARD restores the exact proposal bytes (Neovim's own
--     time travel does that part) and reopens the SAME review identity with
--     every hunk pending again.
--
-- Per-hunk time travel is NOT built. It would need a real undo boundary for
-- every accept, which is the larger alternative the ruling explicitly did not
-- adopt.
--
-- HOW IT OBSERVES, and why not `TextChanged`. `TextChanged` is checked only
-- for `curbuf` from the Normal-mode main loop, so `nvim_buf_call` or `:bufdo`
-- on another buffer bypasses it entirely (NV-6). This uses a per-buffer
-- `nvim_buf_attach(..., {on_lines=...})`, which fires for a buffer that is
-- not current. Many crossed states collapse into one callback and the
-- callback cannot count the steps it crossed (NV-7), so nothing here tries
-- to: the work is deferred with `vim.schedule`, coalesced by `rec.pending`,
-- and reconciles the FINAL `undotree()` branch plus a content hash exactly
-- once.
--
-- WHY A BRANCH WALK AND NOT "IS THE SEQ STILL THERE". `undotree()` exposes
-- alternate branches, and the existence of a sequence is not evidence that
-- it is on the path the buffer is currently on (NV-2); `undo_time()` rotates
-- branches so path membership changes during the command itself (NV-3). So
-- membership is an explicit ancestor walk over `entries` AND every `alt`
-- branch hanging off them, and it is confirmed by a content hash before
-- anything is restored -- never by the sequence number alone.
--
-- WHY "GONE" IS ITS OWN ANSWER. A sequence can be absent from the tree
-- altogether after undo history is cleared or the buffer is wiped and
-- re-read: neither current nor abandoned (NV-8). Treating that silently as
-- a rewind would throw away a review the operator never withdrew, so it is
-- classified GONE and NAMED as drift instead -- the fallback the ruling
-- keeps for exactly the case where resync is impossible.
--
-- WHAT IT DOES NOT DO: it never writes the real tree. Reverting a file on
-- disk from inside a buffer-change callback is the silent out-of-tree write
-- KI-1 itself documents as corrupting, and ruling 87 forbids disk IO on an
-- undo after an accept. An accept moves no bytes and reaches no disk until
-- the turn applies, so a buffer-local withdrawal is the whole of it here.
-- ===========================================================================

--- The register kind a decision withdrawn by a rewind is recorded under. Not
--- `hunk_rejected`: the operator did not reject anything, Neovim's time
--- travel took the bytes the decision described, and a reader that cannot
--- tell those apart would replay a rejection the operator never made.
M.REWIND_KIND = "rejected-by-rewind"

local rewind_watch = {}
local rewind_suppress = 0
-- Outstanding HOLDS (see below): suppression that outlives one frame.
local rewind_held = 0

--- Run `fn` with reconciliation suppressed. Yana drives Neovim's own
--- `:undo {seq}` for its `U` (`undo_turn`) and its abort (`M.abort_active`),
--- and an abort lands BELOW the insert boundary on purpose. Without this the
--- reconciler would see Yana's own transaction as the operator time
--- travelling and withdraw a review that is already being torn down by hand.
--- The release is itself scheduled, so a callback queued by the suppressed
--- edit is drained while the guard is still up.
function M._rewind_suppress(fn)
  rewind_suppress = rewind_suppress + 1
  local ok, err = pcall(fn)
  vim.schedule(function()
    rewind_suppress = math.max(0, rewind_suppress - 1)
  end)
  if not ok then
    error(err, 0)
  end
  return true
end

-- ---------------------------------------------------------------------------
-- HOLDS: Yana's own transaction when it is not synchronous.
--
-- `_rewind_suppress` covers a transaction that begins AND ends inside one
-- frame, and releases on the next scheduler tick. The cross-file retrace walk
-- is not that shape: `retrace.M.undo`/`M.redo` move the buffer synchronously
-- and then do their reintegration and review reopen from `vim.schedule`
-- callbacks, and a close inside the walk queues a queue advance that opens
-- and STAGES the next file a tick later again. Every one of those edits is
-- Yana's, and every one of them used to land after the guard was already
-- down, so the reconciler read the walk's own bytes as the operator time
-- travelling and withdrew a review the walk still owned, mid-step. (Measured
-- under the parallel gate as the r75 redo-paint and r113 reopen families:
-- "[redo3-extra] alpha.py: painted rows (0) == proposal lines (1)".)
--
-- A HOLD IS A TOKEN, NOT A DURATION. Nothing here waits for a length of time;
-- the guard comes down when the walk's own work is finished and not before.
-- The walk opens a hold, and:
--   * `hold.schedule(fn)` queues one piece of the walk's deferred work and
--     COUNTS it, so the hold cannot settle while that piece is outstanding;
--   * the hold is the CURRENT hold while that piece runs, so anything the
--     piece schedules in turn (a queue advance, a further reintegration)
--     joins the same hold before its parent is discounted -- the chain is
--     covered by construction, however deep it goes, and the count cannot
--     bottom out in the middle of it;
--   * `hold.release()` drops the walk's own reference when its synchronous
--     part returns.
-- Only when both are gone does the guard drop, and that drop is itself
-- scheduled, so a callback queued by the very last piece drains while the
-- guard is still up -- the same rule `_rewind_suppress` already follows.
--
-- The suppression a hold provides is ABSOLUTE, exactly like `_rewind_suppress`
-- (see `rewind_reconcile`): a reconcile that lands inside one is dropped, not
-- re-armed onto the next tick. That was tried and reverted (4d18790).
local rewind_hold_current = nil

--- Open a hold. The caller MUST call `hold.release()` on the way out of its
--- synchronous part, on every path including an error one.
function M._rewind_hold()
  local hold = { refs = 1, released = false, settled = false }
  rewind_held = rewind_held + 1
  local function settle()
    if hold.settled or hold.refs > 0 then
      return
    end
    hold.settled = true
    vim.schedule(function()
      rewind_held = math.max(0, rewind_held - 1)
    end)
  end
  function hold.schedule(fn)
    if hold.settled then
      -- The walk already finished and let go; this is no longer its work.
      vim.schedule(fn)
      return
    end
    hold.refs = hold.refs + 1
    vim.schedule(function()
      local prev = rewind_hold_current
      rewind_hold_current = hold
      local ok, err = pcall(fn)
      rewind_hold_current = prev
      hold.refs = hold.refs - 1
      settle()
      if not ok then
        pcall(function()
          log.write("WARN", "yana.inline_diff rewind hold: " .. tostring(err))
        end)
      end
    end)
  end
  function hold.release()
    if hold.released then
      return
    end
    hold.released = true
    hold.refs = hold.refs - 1
    settle()
  end
  return hold
end

--- The current hold, or nil. Callers that need to know whether the work they
--- are about to defer belongs to a walk.
function M._rewind_hold_current()
  return rewind_hold_current
end

--- `vim.schedule`, except that inside a hold the deferred work joins the
--- hold instead of escaping it. Outside a hold this IS `vim.schedule`.
rewind_schedule = function(fn)
  local hold = rewind_hold_current
  if hold then
    hold.schedule(fn)
  else
    vim.schedule(fn)
  end
end

--- The public face of `rewind_schedule`, for the walk's own deferred work in
--- other modules (`timeline/retrace.lua`'s reintegration reopen).
function M._rewind_schedule(fn)
  rewind_schedule(fn)
end

--- The seam a walk uses: run `fn` as Yana's own transaction, holding the
--- guard until the walk's scheduled work has actually finished rather than
--- until the next tick. Re-raises whatever `fn` raised, after releasing.
function M._rewind_own_transaction(fn)
  local hold = M._rewind_hold()
  local prev = rewind_hold_current
  rewind_hold_current = hold
  local ok, res = pcall(fn)
  rewind_hold_current = prev
  hold.release()
  if not ok then
    error(res, 0)
  end
  return res
end

local function rewind_hash(text)
  if type(text) ~= "string" then
    return nil
  end
  local ok, h = pcall(function()
    return require("yana.safety.hash").hash_bytes(text)
  end)
  if ok and type(h) == "string" then
    return h
  end
  return nil
end

--- Every sequence on the path from the undo tree's ROOT to `target`, or nil
--- when `target` names no reachable state at all. An `alt` list hangs off the
--- entry it diverges from, so the entries BEFORE that entry are the prefix of
--- any path found inside it -- which is why `acc` is rolled back to the mark
--- when an alternate branch does not contain the target.
local function undo_path_to(entries, target)
  local acc = {}
  if target == nil then
    return nil
  end
  if target == 0 then
    return acc
  end
  local function rec(list)
    for _, e in ipairs(list or {}) do
      if type(e.alt) == "table" and #e.alt > 0 then
        local mark = #acc
        if rec(e.alt) then
          return true
        end
        for i = #acc, mark + 1, -1 do
          acc[i] = nil
        end
      end
      acc[#acc + 1] = e.seq
      if e.seq == target then
        return true
      end
    end
    return false
  end
  if rec(entries) then
    return acc
  end
  return nil
end

--- Is `target` anywhere in this tree at all -- current branch or abandoned
--- one? A `false` here is the GONE case (NV-8), and it is the ONLY thing
--- that may be called drift.
local function undo_seq_present(entries, target)
  if target == nil then
    return false
  end
  if target == 0 then
    return true
  end
  for _, e in ipairs(entries or {}) do
    if e.seq == target then
      return true
    end
    if type(e.alt) == "table" and undo_seq_present(e.alt, target) then
      return true
    end
  end
  return false
end

local function rewind_forget(path)
  local rec = rewind_watch[path]
  if rec then
    rec.detached = true
    rewind_watch[path] = nil
  end
end

--- Exposed so `M.abort_active` can drop the watch: an abort is the operator
--- withdrawing the review by hand, and a later `:later` must not resurrect it.
function M._rewind_forget_path(path)
  if type(path) == "string" then
    rewind_forget(path)
  end
end

--- Mark a watched path's review as withdrawn WITHOUT dropping the record, so
--- crossing the insertion forward can still restore it (operator ruling
--- 2026-08-25). Used by `M._withdraw_for_plain_undo`, which withdraws by hand
--- rather than through `rewind_withdraw` and so has to set the same flag that
--- function sets. Distinct from `M._rewind_forget_path` on purpose: forgetting
--- is for an ABORT, where the operator has discarded the review and no forward
--- move may bring it back; marking is for a `u` across the boundary, which the
--- ruling makes reversible. A path with no watch is a no-op -- there is no
--- proposal insertion to be on the far side of.
function M._rewind_mark_withdrawn(path)
  if type(path) ~= "string" then
    return
  end
  local rec = rewind_watch[path]
  if rec and not rec.detached then
    rec.withdrawn = true
  end
end

--- Drop every watch belonging to a discarded owner (or all of them). A review
--- the operator has DISCARDED must not come back: without this, a rewind watch
--- outlives `discard_pool`/`discard_for_owner` and a later `:later` re-queues
--- a change whose conversation is gone and whose claim has been released.
function M._rewind_forget_owner(owner)
  for path, rec in pairs(rewind_watch) do
    if owner == nil or owners_match(rec.owner, owner) then
      rec.detached = true
      rewind_watch[path] = nil
    end
  end
end

function M._rewind_reset()
  rewind_watch = {}
  rewind_suppress = 0
  rewind_held = 0
  rewind_hold_current = nil
end

--- Test/diagnostic: snapshot one watched path's rewind record (or nil).
function M._rewind_peek(path)
  if type(path) ~= "string" then
    return nil
  end
  local rec = rewind_watch[path]
  if not rec or rec.detached then
    return nil
  end
  return {
    boundary_seq = rec.boundary_seq,
    withdrawn = rec.withdrawn,
    drift_named = rec.drift_named,
    open_hash = rec.open_hash,
  }
end

local rewind_reconcile

local function rewind_attach(rec, bufnr)
  if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  if rec.attached_to == bufnr then
    return
  end
  rec.attached_to = bufnr
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      if rewind_watch[rec.path] ~= rec or rec.detached then
        return true
      end
      if rec.attached_to ~= bufnr then
        return true
      end
      -- NV-7: one callback may cover many crossed states and cannot count
      -- them. Coalesce and reconcile the FINAL state, once.
      if rec.pending then
        return
      end
      rec.pending = true
      vim.schedule(function()
        rec.pending = false
        rewind_reconcile(rec.path, true)
      end)
    end,
    on_detach = function()
      if rec.attached_to == bufnr then
        rec.attached_to = nil
      end
    end,
  })
end

local function rewind_lifecycle(kind, rec, extra)
  local fields = {
    path = rec.rel,
    boundary_seq = rec.boundary_seq,
    change_id = rec.change and rec.change.id,
  }
  for k, v in pairs(extra or {}) do
    fields[k] = v
  end
  pcall(function()
    require("yana.log").lifecycle_later(kind, fields)
  end)
end

--- The undo tree no longer holds the proposal insertion at all. Nothing can
--- be rewound to and nothing can be restored, so the fact is NAMED rather
--- than swallowed, and the watch retires.
local function rewind_drift(rec)
  if rec.drift_named then
    return
  end
  rec.drift_named = true
  local said = "yana: undo drift in "
    .. tostring(rec.rel)
    .. " -- this review's proposal insertion (undo_seq "
    .. tostring(rec.boundary_seq)
    .. ") is no longer in the buffer's undo history, so it cannot be rewound or restored"
  rewind_lifecycle("undo.rewind_drift", rec, { reason = "undo_tree_destroyed", detail = said })
  pcall(function()
    require("yana.log").write("WARN", said)
  end)
  notify_one_line(said, vim.log.levels.WARN)
  rewind_forget(rec.path)
end

--- Mark this review's decision rows reverted in the journal. Every row at or
--- above the insert boundary described bytes that the rewind has just taken,
--- so a later cross-file `u` must not spend a press on one.
local function rewind_mark_rows(rec, reverted)
  pcall(function()
    local tl = require("yana.timeline")
    local record = require("yana.timeline.record")
    if type(tl.entries) ~= "function" or type(record.mark_reverted) ~= "function" then
      return
    end
    local ok, entries = pcall(tl.entries, rec.workspace, rec.rel)
    if not ok or type(entries) ~= "table" then
      return
    end
    for _, e in ipairs(entries) do
      if e.regime == "buffer"
        and record.UNDOABLE_KIND[e.kind]
        and type(e.undo_seq) == "number"
        and e.undo_seq >= (rec.boundary_seq or 0)
      then
        record.mark_reverted(e.id, reverted and true or false)
      end
    end
  end)
end

--- Crossing the insertion BACKWARD. The whole review goes, and every decision
--- in it goes with it, together.
local function rewind_withdraw(rec)
  rec.withdrawn = true
  local st = pool_for(rec.opts or {})
  local state = st.active
  local dropped = 0
  if state and state.change == rec.change then
    dropped = #(state.decisions or {})
    record_decision(state, "review_rejected_by_rewind", {
      kind = M.REWIND_KIND,
      boundary_seq = rec.boundary_seq,
      decisions_withdrawn = dropped,
      hunks = #(state.diff_blocks or {}),
    })
    -- The blocks and decisions are dropped BEFORE the session is finished,
    -- and that ordering is the whole of it -- the same ordering
    -- `M.abort_active` needs and for the same measured reason. The buffer is
    -- ALREADY at a state that predates the proposal: Neovim's own time travel
    -- put it there. `finish_session`'s reject path would otherwise walk hunks
    -- that no longer exist and restore pre-turn content over live rows.
    state.diff_blocks = {}
    state.decisions = {}
    finish_session(state, false)
  end
  rewind_mark_rows(rec, true)
  rewind_lifecycle("undo.rewind_withdrawn", rec, {
    decisions_withdrawn = dropped,
    hunks = #(rec.blocks or {}),
    kind = M.REWIND_KIND,
  })
  notify_one_line(
    "yana: undo crossed the proposal insertion in "
      .. tostring(rec.rel)
      .. " -- the whole review was withdrawn; redo brings it back",
    vim.log.levels.INFO
  )
  announce_state()
end

--- Crossing the insertion FORWARD. Neovim has already put the exact proposal
--- bytes back -- confirmed by content hash above, never by the sequence
--- number alone -- so this reopens the SAME review over them.
local function rewind_restore(rec)
  local change = rec.change
  if not change then
    rewind_forget(rec.path)
    return
  end
  local st = pool_for(rec.opts or {})
  if st.active and st.active.change == change then
    rec.withdrawn = false
    return
  end
  -- `M._withdraw_for_plain_undo` deliberately does NOT call
  -- `schedule_queue_advance`, so the change can still sit in `st.queue`
  -- with `st.active == nil` after a floor `u`. An earlier guard returned
  -- whenever the change was merely queued, which blocked `rewind_restore`
  -- after post-close `<C-r>` even when the buffer had already landed on the
  -- proposal (content hash matched, boundary seq present). property seed 87008
  -- step 35; pinned by `r130_rewind_redo_after_reload_withdraw`.
  for i, item in ipairs(st.queue) do
    if item.change == change then
      table.remove(st.queue, i)
      break
    end
  end
  rec.withdrawn = false
  -- SAME REVIEW IDENTITY. The `change` table itself is reused, so `change.id`,
  -- its turn and its ledger are the ones the operator was already shown: this
  -- is the review coming back, not a new one opened over the same file.
  -- `_retrace_reintegration` is the existing marker for precisely that, and it
  -- carries the second thing this needs -- `open_review_buffer` returns the
  -- buffer AS-IS instead of re-staging bytes Neovim has already put back,
  -- which would otherwise insert a phantom undo step into the operator's own
  -- history purely as a side effect of travelling forward.
  change._retrace_reintegration = true
  change._retrace_fresh = nil
  change._rewind_restored = true
  change.review_error = nil
  change.status = "pending"
  local blocks = vim.deepcopy(rec.blocks or {})
  change._parked_review = {
    staged_text = rec.open_text,
    blocks = blocks,
    pending_signature = block_signature(blocks),
    model_hunks = vim.deepcopy(rec.model_hunks or {}),
    model_source = rec.model_source,
    -- EVERY hunk pending. The decisions went with the rewind; none of them
    -- is sealed, because none of them stands any more.
    sealed_decisions = {},
  }
  local item = { change = change, opts = rec.opts, owner = rec.owner }
  change._parked_item = item
  remember_batch_item(st, item)
  table.insert(st.queue, 1, item)
  rewind_lifecycle("undo.rewind_restored", rec, { hunks = #blocks })
  notify_one_line(
    "yana: redo crossed back over the proposal insertion in "
      .. tostring(rec.rel)
      .. " -- the review is open again with every hunk pending",
    vim.log.levels.INFO
  )
  vim.schedule(function()
    process_next_for(rec.opts)
  end)
end

--- Reconcile the FINAL state of one watched path against its insert boundary.
--- `observed` is true only when this reconcile was triggered by an actual
--- LINE CHANGE in the buffer (`on_lines`). A reconcile triggered merely by
--- ENTERING a buffer may classify GONE and may restore, but must never
--- WITHDRAW.
---
--- WHY. The buffer-enter trigger exists for one case: a `:bwipeout` destroys
--- the undo tree AND the `on_lines` callback with it, so nothing else can ever
--- notice that the boundary has gone. It is not evidence that the operator
--- travelled. Windows change buffers constantly during a cross-file redo walk
--- -- the walk reopens reviews and jumps between files -- and each of those
--- enters used to run a full reconcile which could withdraw a review the walk
--- itself owns, mid-step. Measured under load as the r75 redo-paint family and
--- the r113 reopen family going red while the same tree passed when quiet.
--- A withdrawal is a destructive act and now requires a change actually
--- observed in the bytes.
rewind_reconcile = function(path, observed)
  local rec = rewind_watch[path]
  if not rec or rec.detached then
    return
  end
  if rewind_suppress > 0 or rewind_held > 0 then
    -- DROPPED, DELIBERATELY, AND MEASURED. `rewind_held` is the same fact for
    -- a transaction that is not synchronous -- see HOLDS above. This looks like a hole -- an
    -- operator crossing that lands inside one of Yana's own suppression
    -- windows is never reconciled -- and re-arming it on the next tick was
    -- tried. It is worse, and it is worse in the way that matters: the guard
    -- exists precisely because Yana's `U`, its reject walk, its abort and the
    -- cross-file register walk MOVE THE BUFFER THEMSELVES, often below the
    -- insert boundary. Re-arming does not skip those edits, it merely
    -- reconciles them one tick later, once the guard has dropped -- so the
    -- reconciler withdraws or restores a review in the middle of a walk that
    -- owns it. Measured: ten rows red across the r75 redo-paint family, the
    -- r113 reopen family and ruling #100's silence rows.
    --
    -- The reconcile is not lost in practice: the guard is held only for the
    -- duration of Yana's own transaction, and any later change to the buffer
    -- -- including the operator's next keystroke -- schedules a fresh one that
    -- reconciles the same final state.
    return
  end
  local bufnr = rec.attached_to
  if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)) then
    bufnr = vim.fn.bufnr(path)
    if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr)) then
      return
    end
    rewind_attach(rec, bufnr)
  end
  local tree
  pcall(vim.api.nvim_buf_call, bufnr, function()
    tree = vim.fn.undotree()
  end)
  if type(tree) ~= "table" then
    return
  end
  local cur = tree.seq_cur or 0

  -- NV-8: absent from the tree altogether -- neither current nor abandoned.
  -- The undo history was destroyed (cleared, or the buffer wiped and re-read).
  -- Resync is impossible, so this is the one case that is named as drift.
  if not undo_seq_present(tree.entries, rec.boundary_seq) then
    rewind_drift(rec)
    return
  end

  local live_hash = rewind_hash(diff.buffer_bytes_snapshot(bufnr))
  local at_proposal = (live_hash ~= nil and live_hash == rec.open_hash)

  local path_seqs = undo_path_to(tree.entries, cur)
  if path_seqs == nil then
    -- NV-4: `seq_cur` can be `target - 1` and need not name an undo header at
    -- all, so the branch walk cannot answer. Fall back to the content hash
    -- alone, which can only ever restore -- never withdraw on a guess.
    if rec.withdrawn and at_proposal then
      rewind_restore(rec)
    end
    return
  end

  local on_path = (cur == rec.boundary_seq)
  if not on_path then
    for _, s in ipairs(path_seqs) do
      if s == rec.boundary_seq then
        on_path = true
        break
      end
    end
  end

  if on_path then
    -- The insertion is applied. A REACHABLE destination whose sequence and
    -- content hash both match is a resync, never a drift.
    if rec.withdrawn and at_proposal then
      rewind_restore(rec)
    end
    return
  end

  -- The boundary exists but the buffer is no longer downstream of it: the
  -- insertion has been crossed backward, or a branch switch has moved off it.
  if rec.withdrawn then
    if at_proposal then
      rewind_restore(rec)
    end
    return
  end
  if at_proposal then
    -- Content-hash confirmation refuses: whatever the sequence numbers say,
    -- the buffer still holds exactly the proposal, so nothing was withdrawn.
    return
  end
  if not observed then
    -- Entering a buffer is not evidence that the operator travelled -- see the
    -- note on this function. Withdrawal waits for an observed line change.
    return
  end
  rewind_withdraw(rec)
end

--- Post-review native redo: if the buffer landed on the withdrawn proposal,
--- reopen directly. The deferred `on_lines` reconcile is often dropped while
--- suppress/hold counters from the same press are still elevated (seed 87008).
function M._rewind_try_restore_after_redo(path)
  if type(path) ~= "string" then
    return
  end
  local rec = rewind_watch[path]
  if not rec or rec.detached or not rec.withdrawn then
    return
  end
  local bufnr = rec.attached_to
  if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr)) then
    bufnr = vim.fn.bufnr(path)
  end
  if not (bufnr and bufnr > 0 and vim.api.nvim_buf_is_loaded(bufnr)) then
    return
  end
  local live_hash = rewind_hash(diff.buffer_bytes_snapshot(bufnr))
  if live_hash ~= nil and live_hash == rec.open_hash then
    rewind_restore(rec)
  end
end

local rewind_augroup

--- A `:bwipeout` (or any wipe-and-re-read) destroys the undo tree AND the
--- `nvim_buf_attach` callback with it, so `on_lines` can never fire again for
--- that path -- which is exactly the case where the boundary has gone and the
--- operator most needs to be told. Re-attach to whatever buffer now holds a
--- watched path and reconcile once, so the GONE classification is reached by
--- the same code as every other one.
---
--- Scoped to watched paths only: a buffer Yana has never staged a proposal
--- into never reaches past the first lookup.
local function rewind_ensure_autocmd()
  if rewind_augroup then
    return
  end
  rewind_augroup = vim.api.nvim_create_augroup("YanaRewindWatch", { clear = true })
  vim.api.nvim_create_autocmd({ "BufReadPost", "BufWinEnter", "BufEnter" }, {
    group = rewind_augroup,
    callback = function(args)
      local buf = args.buf
      if not (buf and vim.api.nvim_buf_is_valid(buf)) then
        return
      end
      local name = vim.api.nvim_buf_get_name(buf)
      if name == "" then
        return
      end
      local abs = vim.fn.fnamemodify(name, ":p")
      local rec = rewind_watch[abs]
      if not rec or rec.detached then
        return
      end
      if rec.attached_to ~= buf then
        rewind_attach(rec, buf)
      end
      vim.schedule(function()
        rewind_reconcile(abs)
      end)
    end,
  })
end

--- Start (or refresh) the watch for a review that has just opened. Called
--- once the state is live and `undo_open_seq` -- the sequence the proposal
--- insertion landed on, and the ONLY boundary this mechanism has -- is known.
function M._rewind_note_open(state)
  local change = state and state.change
  local bufnr = state and state.bufnr
  if not (change and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local path = change.path
  if type(path) ~= "string" or path == "" then
    return
  end
  if type(state.undo_open_seq) ~= "number" then
    return
  end
  local open_text = state.staged_text or diff.buffer_bytes_snapshot(bufnr)
  local open_hash = rewind_hash(open_text)
  if open_hash == nil then
    return
  end
  local blocks = {}
  for i, block in ipairs(state.diff_blocks or {}) do
    local copy = vim.deepcopy(block)
    copy.incoming_extmark_id = nil
    copy.incoming_extmark_ids = nil
    copy.delete_extmark_id = nil
    copy.authority_extmark_id = nil
    copy.nav_fallback_stated = nil
    blocks[i] = copy
  end
  local prev = rewind_watch[path]
  local rec = {
    path = path,
    rel = change.rel or change.path,
    workspace = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd(),
    change = change,
    opts = state.opts,
    owner = (state.queue_item and state.queue_item.owner) or freeze_review_owner(state.opts),
    boundary_seq = state.undo_open_seq,
    open_hash = open_hash,
    open_text = open_text,
    -- The block list AS OPENED: every hunk, all pending. A restore reopens
    -- from this, never from whatever survived the decisions the rewind took.
    blocks = (prev and prev.change == change and prev.blocks) or blocks,
    model_hunks = vim.deepcopy(state.model_hunks or {}),
    model_source = state.model_source,
    withdrawn = false,
  }
  if prev then
    prev.detached = true
  end
  rewind_watch[path] = rec
  rewind_attach(rec, bufnr)
  rewind_ensure_autocmd()
end
function M.open(change, opts)
  if not change or not change.path then
    -- Not one of the named refusal paths, but still a `return false` with a
    -- change object available (when change itself is non-nil): record it too
    -- so nothing downstream mistakes this for a healthy pending review.
    if change then
      change.review_error = "invalid change: missing path"
    end
    -- Same contract as the genuine-refusal branch below, and it was missing:
    -- this branch returned false without announcing or pumping, so a
    -- path-less change (change_from_payload yields path = nil when the agent
    -- payload carries afterFullFileContent but no success.path and no
    -- args.path) silently parked the whole queue behind it -- every later
    -- review in the session never opened. A malformed payload must cost one
    -- change, not the session.
    announce_state()
    schedule_queue_advance(state)
    return false, "invalid change: missing path"
  end
  opts = opts or {}

  local bin_class = binary_reason(change)
  if bin_class then
    if change.status ~= "pending" then
      announce_state()
      schedule_queue_advance({ opts = opts })
      return false, "change is no longer pending"
    end
    change.reason_class = bin_class
    local detail = (change.rel or change.path)
      .. ": "
      .. bin_class
      .. " — real file unchanged; proposal is not reviewable"
    change.review_error = detail
    ledger.record_decision(change_ledger(change, opts), {
      action = "review_refused",
      actor = "system",
      reason = bin_class,
      detail = detail,
      change_id = change.id,
      rel = change.rel or change.path,
    })
    change.status = "system_refused"
    notify_owner(opts.on_system_refused, change, "on_system_refused")
    if opts.on_close then
      vim.schedule(function()
        notify_owner(function()
          opts.on_close(nil, false)
        end, change, "on_close")
      end)
    end
    notify_one_line("yana: refused " .. detail, vim.log.levels.WARN)
    announce_state()
    schedule_queue_advance({ opts = opts })
    return false, detail
  end

  local bufnr, open_err, refusal = open_review_buffer(change, opts.preview)
  if not bufnr then
    -- A refusal is not a user decision, and the corpus showed the two being
    -- read as one. It is recorded as its own class, with the fingerprint pair
    -- that disagreed when the refusing site had both in hand — never the
    -- contents, per the module's redaction invariant.
    local L = change_ledger(change, opts)
    local actual_fp = refusal and refusal.actual_fp or nil
    -- The attribution the fingerprint pair was retained for: agent self-write,
    -- external save, or honestly unknown.
    local origin, reason = attribute_drift(change, (refusal and refusal.reason) or "other", actual_fp)
    ledger.record_decision(L, {
      action = "review_refused",
      actor = "system",
      reason = reason,
      origin = origin,
      detail = open_err,
      change_id = change.id,
      rel = change.rel or change.path,
      expected_fp = refusal and refusal.expected_fp or nil,
      actual_fp = actual_fp,
    })
    -- The "kept unreviewed, no pre-edit snapshot" branch is gone with E9. It
    -- existed because a missing `before` meant the agent's edit was already on
    -- disk with nothing to revert to; now a missing `before` is simply a
    -- create, reviewed against an empty base, and nothing is on disk to keep.
    --
    -- Genuine refusal: the change stays "pending" but nothing was opened.
    -- Record why so a later accept/reject on this row can retry instead of
    -- giving hunk advice for a review that never existed.
    if change.review_error == nil then
      change.review_error = open_err
    end
    -- BURST GUARD (DEFECT C): a refused target keeps getting retried --
    -- `]x`/`[x` parks the current file and reopens the target on EVERY
    -- press, and a target whose refusal reason has not changed since the
    -- last attempt would otherwise re-announce the identical line every
    -- single press. Announce once per distinct reason; a later attempt that
    -- fails for a DIFFERENT reason (or succeeds, which clears this field
    -- below) is still reported.
    local open_err_text = tostring(open_err)
    if change._open_refusal_announced ~= open_err_text then
      change._open_refusal_announced = open_err_text
      M._announce_open_failure(change, "could not open review buffer: " .. open_err_text, vim.log.levels.WARN)
    end
    -- A refused review must not strand every change still queued behind it.
    announce_state()
    schedule_queue_advance({ opts = opts or {} })
    return false, open_err
  end

  -- A review buffer for this change did open successfully — clear any stale
  -- reason from an earlier refused attempt so a later look at the change
  -- does not report a problem that no longer applies.
  change.review_error = nil
  change._open_refusal_announced = nil

  -- An empty base is ZERO lines, but Vim cannot hold a zero-line buffer: the
  -- blank line it forces is not part of the base. For a modify the phantom
  -- trailing "" that split_lines produces sits on both sides and cancels, but
  -- for a create it would land inside the one hunk and add a blank line to the
  -- composed file. Drop it from the target here and drop the buffer's forced
  -- blank line after staging; match_eol restores the real final newline at
  -- accept.
  -- THE TURN-START PAIR, pinned at the FIRST open of this change and never
  -- again. `M.reopen_from_register` numbers hunks against it, and the register
  -- numbers its rows ("accept hunk 2") against it too, so the two must be the
  -- same list. Capturing it lazily at the first REOPEN is too late: a `:w`
  -- between decisions re-bases `change.before` onto the freshly written bytes
  -- (ruling 72 writes the buffer-owned lines), which drops every already
  -- accepted hunk out of the pair -- `build_diff_blocks` then yields ONE block
  -- for what the register still calls hunk 2, the verdicts land on the wrong
  -- ordinals, and the reopen composes a review with nothing pending in it
  -- (measured: row d's `u1`, "no pending hunk for a.py", while the register
  -- had already announced "undid accept hunk 2 in a.py").
  if change._retrace_model == nil and type(change.before) == "string" and type(change.after) == "string" then
    change._retrace_model = { before = change.before, after = change.after }
  end
  local target = model_target(change)
  -- Model FIRST, blocks second, join last: the model must not be able to
  -- inherit anything from the block list.
  local model, model_source = payload_model(change, target)
  local parked = change._parked_review
  if parked and change._retrace_fresh then
    -- ROW 112: the retrace has just re-derived BOTH sides of this change from
    -- disk and the buffer (`timeline/retrace.lua`'s `reintegrate`), so a parked
    -- snapshot's block list predates this very press -- reopening from it shows
    -- the hunks this file had BEFORE the decision the press reversed (measured:
    -- a.py came back with one band where two were pending). The fresh pair wins,
    -- for exactly this open. NAMED LIMIT: that snapshot's sealed decision stack
    -- goes with it, so `<C-r>` in the reopened review reaches the cross-file
    -- register rather than those decisions -- which is where the walk that
    -- caused this reopen put them anyway.
    change._parked_review = nil
    parked = nil
  end
  change._retrace_fresh = nil
  -- One-shot, same pattern as `_retrace_fresh` just above: read now (before
  -- the staging pcall below), then clear, so a LATER, genuinely different
  -- reopen of this same change object never inherits a stale "already
  -- staged" verdict from a press that has nothing to do with it.
  local parked_already_staged = change._parked_already_staged
  change._parked_already_staged = nil
  local blocks = stamp_model_index(M.build_diff_blocks(change.before or "", target), model)
  if parked then
    local parked_blocks = {}
    for i, block in ipairs(parked.blocks or {}) do
      local copy = vim.deepcopy(block)
      copy.incoming_extmark_id = nil
      copy.incoming_extmark_ids = nil
      copy.delete_extmark_id = nil
      copy.authority_extmark_id = nil
      copy.nav_fallback_stated = nil
      parked_blocks[i] = copy
    end
    blocks = parked_blocks
    model = vim.deepcopy(parked.model_hunks or model)
    model_source = parked.model_source or model_source
  end
  -- Zero hunks means `before` equals `after`: disk already holds the accepted
  -- content, so there is nothing to write and nothing to review, and settling
  -- the change here is correct.
  --
  -- An agent-created EMPTY file is NOT that case, even though it also diffs to
  -- zero hunks. Its base is "no file at all" and the file still does not exist,
  -- so creating it is a real change that the user must be able to reject. This
  -- branch used to write it to disk immediately, mark it accepted, and return
  -- without ever setting `active` — the user never saw a review and had no way
  -- to refuse, which contradicts CORE ("Real files remain unchanged until
  -- explicit acceptance"). Under shadow_apply it was worse: the write was
  -- skipped but the change was still marked accepted without calling
  -- on_shadow_accept, so the creation was silently dropped.
  --
  -- So a create falls through to the normal review below. It stages an empty
  -- buffer with no hunks; the file-level keys (accept-all / reject-file) still
  -- work, and the file is created only by finish_session at accept.
  if #blocks == 0 and change.before ~= nil then
    vim.bo[bufnr].modified = false
    change.status = "accepted"
    notify_owner(opts.on_accept, change, "on_accept")
    focus_buf(change.path, bufnr)
    notify_one_line("yana: applied " .. change.rel, vim.log.levels.INFO)
    -- This M.open call may have come from process_next (queue-driven). With
    -- no diff blocks, `active` is never set here, so nothing would ever
    -- advance the queue. Safe for direct (non-queued) calls too: process_next
    -- no-ops when the queue is empty.
    schedule_queue_advance({ opts = opts or {} })
    return true
  end

  local pre_stage_lines = vim.deepcopy(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false))
  local stage_ok, stage_err = pcall(function()
    -- See `open_review_buffer`'s own "RETRACE REINTEGRATION FAST PATH" and
    -- "PARKED-ALREADY-STAGED FAST PATH" comments: when either fast path
    -- fired, the buffer was returned WITHOUT being staged, and it already
    -- holds exactly `target` (retrace) or `parked.staged_text` (an
    -- ordinary parked reopen the buffer never moved since) -- writing
    -- `blocks` into it here would be the SAME phantom undo-tree entry
    -- either fast path exists to avoid, on top of overwriting content that
    -- is already correct. `highlight_blocks` alone still paints correctly:
    -- `blocks`' positions were computed against `target`, which IS the
    -- buffer's current content in this path.
    if not (change._retrace_reintegration or parked_already_staged) then
      insert_new_lines(bufnr, blocks)
      if parked and type(parked.staged_text) == "string" then
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(parked.staged_text))
      end
      if change.before == nil then
        local n = vim.api.nvim_buf_line_count(bufnr)
        if n > 1 and (vim.api.nvim_buf_get_lines(bufnr, n - 1, n, false)[1] or "") == "" then
          vim.api.nvim_buf_set_lines(bufnr, n - 1, n, false, {})
        end
      end
      vim.bo[bufnr].modified = false
    end
    highlight_blocks(bufnr, blocks)
  end)
  if not stage_ok then
    break_undo_block(bufnr)
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, pre_stage_lines)
    vim.bo[bufnr].modified = false
    change.review_error = tostring(stage_err)
    do
      local L = change_ledger(change, opts)
      ledger.record_decision(L, {
        action = "review_refused",
        actor = "system",
        reason = "stage_failed",
        detail = tostring(stage_err),
        change_id = change.id,
        rel = change.rel or change.path,
      })
    end
    notify_one_line("yana: could not stage review: " .. tostring(stage_err), vim.log.levels.WARN)
    announce_state()
    schedule_queue_advance({ opts = opts or {} })
    return false, tostring(stage_err)
  end

  if parked then
    local restored = diff.buffer_bytes_snapshot(bufnr)
    local sig = {}
    for i, block in ipairs(blocks or {}) do
      sig[i] = table.concat({
        tostring(block.model_index or i),
        tostring(#(block.old_lines or {})),
        tostring(#(block.new_lines or {})),
        tostring(block.new_start_line or ""),
        tostring(block.new_end_line or ""),
      }, ":")
    end
    local got_sig = table.concat(sig, "|")
    if restored ~= parked.staged_text or got_sig ~= parked.pending_signature then
      break_undo_block(bufnr)
      pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, pre_stage_lines)
      vim.bo[bufnr].modified = false
      change.review_error = "parked review restore mismatch"
      ledger.record_decision(change_ledger(change, opts), {
        action = "review_refused",
        actor = "system",
        reason = "park_restore_mismatch",
        detail = change.review_error,
        change_id = change.id,
        rel = change.rel or change.path,
      })
      notify_one_line("yana: refused to reopen parked review for " .. (change.rel or change.path) .. " -- restore mismatch", vim.log.levels.WARN)
      announce_state()
      schedule_queue_advance({ opts = opts or {} })
      return false, "parked review restore mismatch"
    end
    change._parked_review = nil
  end

  -- Seal the staging into its own undo block and bookmark where it landed.
  -- THE REVIEW'S OPEN STATE: the buffer exactly as the operator was first shown
  -- it, every hunk still the agent's and nothing decided. `U` walks back to this
  -- integer once it has taken every decision off the stack, so what the operator
  -- gets is the review they opened. Taking the TURN back after the review has
  -- CLOSED is a different operation on a tree that has already moved -- the real
  -- file has been written by then -- and it is named in
  -- the review and apply contract rather than built here.
  break_undo_block(bufnr)
  local undo_open_seq = buf_undo_seq(bufnr)

  -- The change model, and the rung-1 capture over the render that just ran.
  -- Recorded before the state exists, because the FIRST render is the one the
  -- reference defect appears in.
  do
    local L = change_ledger(change, opts)
    ledger.mark(L, "first_review_opened")
    -- RULING 74 (AD:895): a retrace reintegration REOPENS the original
    -- review under its own original identity -- it is not a new review
    -- being shown to the operator for the first time, so it must not
    -- inflate reviews_opened on every accept/undo cycle of the same hunk.
    -- `_retrace_reintegration` (set by `retrace.reintegrate` on both the
    -- reused and the cross-turn-minted change) is the mark for that; an
    -- ordinary turn's own first open never carries it.
    if not change._retrace_reintegration then
      ledger.bump(L, "reviews_opened")
    end
    local hunks = {}
    for i, b in ipairs(blocks) do
      hunks[i] = {
        index = i,
        old_count = #(b.old_lines or {}),
        new_count = #(b.new_lines or {}),
        new_start_line = b.new_start_line,
        new_end_line = b.new_end_line,
      }
    end
    -- Built AFTER the hunks table exists (unlike before), so the durable
    -- log carries the same geometry the in-memory ledger gets below --
    -- index/old_count/new_count/new_start_line/new_end_line, never line
    -- contents.
    require("yana.log").lifecycle_later("review.open", {
      turn_id = change.turn_id or change.turn_gen,
      generation = change.turn_gen,
      path = change.rel or change.path,
      hunks = hunks,
    })
    ledger.record_hunks(L, {
      change_id = change.id,
      rel = change.rel or change.path,
      path = change.path,
      kind = change.kind,
      added = change.added,
      removed = change.removed,
      bufnr = bufnr,
      hunks = hunks,
      model_source = model_source,
    })
  end
  ledger.mark(change_ledger(change, opts), "review_profile_hunks_ready")

  local maps = config.options.mappings.diff or {}
  local keys = {
    maps.ours or "cr",
    maps.theirs or "ca",
    maps.all_theirs or "cf",
    maps.all_changes or "cA",
    maps.reject_file or "cx",
    maps.next or "]x",
    maps.prev or "[x",
    -- Buffer-local for the review's lifetime only, and released with it by
    -- M.cleanup. Hardcoded rather than configurable: the ruling names both
    -- keys and this lane adds no dial. `<C-r>` joins them because a redo that
    -- the review does not see leaves the paint describing a buffer that has
    -- moved; it must be released with them too, or the operator keeps a
    -- review-flavoured redo after the review is gone.
    "u",
    "U",
    "<C-r>",
    -- Whole-review abort (cR): same code path as `:YanaAbortReview`. Also
    -- hardcoded, same reasoning as u/U/<C-r> just above -- the operator's
    -- vocabulary ruling (2026-08-25) names the letter. Buffer-local for the
    -- review's lifetime, released by M.cleanup with the rest of `keys` on
    -- any ordinary close; `M.abort_active` itself tears every affected
    -- buffer's keys down by hand for its OWN close (its own path never
    -- reaches M.cleanup's `keys` loop).
    "cR",
  }

  local state = {
    change = change,
    bufnr = bufnr,
    diff_blocks = blocks,
    -- The immutable side of the render check. `diff_blocks` is edited as hunks
    -- resolve; this is what the payload said, and blocks join to it by
    -- `model_index`.
    model_hunks = model,
    model_source = model_source,
    opts = opts,
    keys = keys,
    -- Bookmarks into Neovim's undo tree, and the LIFO stack of decisions this
    -- review has taken. Integers and decision records only -- no bytes are held
    -- here, so nothing here can be used as authority to restore text.
    undo_open_seq = undo_open_seq,
    latest_undo_seq = undo_open_seq,
    undo_pre_stage_seq = change.undo_pre_stage_seq,
    decisions = {},
    sealed_decisions = parked and vim.deepcopy(parked.sealed_decisions or {}) or {},
    hint_id = nil,
    hint_line = nil,
    -- What the review buffer held the last time this engine touched it. The
    -- FileChangedShellPost gate compares against this to tell "a reload put
    -- identical bytes back" (harmless) from "a reload replaced my staged
    -- hunks" (fatal). Refreshed on every hunk resolve, because rejecting a
    -- hunk writes old_lines back and the buffer stops being `after`.
    staged_text = diff.buffer_bytes_snapshot(bufnr),
    fcs_post_count = 0,
    winhl_restore = {},
    augroup = vim.api.nvim_create_augroup("YanaInlineDiff" .. change.id, { clear = true }),
    -- RULING 75/73/57: whether the drift since `timeline_obs` was last set
    -- includes anything OUTSIDE a pending hunk -- see `tl_capture_human_edit`.
    -- Starts false: nothing has happened yet.
    free_standing_edit = false,
  }
  local initial_landing_block = blocks[1]
  if change._retrace_land_model_index ~= nil then
    for _, b in ipairs(blocks) do
      if b.model_index == change._retrace_land_model_index then
        initial_landing_block = b
        break
      end
    end
    change._retrace_land_model_index = nil
  end
  ledger.mark(change_ledger(change, opts), "review_profile_state_allocated")
  stamp_review_workspace(change, opts)
  ledger.mark(change_ledger(change, opts), "review_profile_workspace_stamped")
  -- Watch the buffer from here on: every later repaint re-derives which rows
  -- are the agent's, and this is what gives it a reason to run when the human
  -- types rather than only when a decision is taken.
  attach_buffer_watch(state)
  ledger.mark(change_ledger(change, opts), "review_profile_buffer_watched")
  local st = pool_for(opts or {})
  M._review_tabs_init_for_turn(st, change, opts or {})
  st.active = state
  -- KI-1 / operator ruling 2026-08-24. Start watching this buffer's SINGLE
  -- insert boundary now that `undo_open_seq` -- the sequence the proposal
  -- insertion landed on -- is known and the state is live. See
  -- `M._rewind_note_open` and the section header above it for why this is a
  -- per-buffer `nvim_buf_attach` and not `TextChanged`.
  M._rewind_note_open(state)
  -- The opening row. Recorded once the state is live, so tl_record can read the
  -- change off it, and after the buffer holds the staged content so the buffer
  -- epoch belongs to the tree the review is about to work in.
  --
  -- SKIPPED for a retrace reintegration (FIX-UNDO lane, this session).
  -- `timeline.intent`/`intent_async` unconditionally call
  -- `record.sync_buffer_head`, which advances this buffer's recorded head to
  -- whatever row was JUST written -- correct for a genuine new turn, wrong
  -- here: the retrace walk that opened this reintegration already left the
  -- head exactly where it belongs (pointing at the reversed row's own
  -- predecessor, via `walk_impl.step_buffer`'s own sync). Recording a fresh
  -- "review_opened" row here would advance the head PAST the row retrace
  -- just reversed, which un-reverts it in `record.entries`'s own
  -- head-based derivation (`buffer_state`'s plain seq comparison cannot
  -- tell an accept's reversal apart from never having reversed it at all,
  -- since accepting moves no bytes -- the head override is what actually
  -- carries that fact). Measured 2026-08-21: without this guard, the
  -- operator's own worked-example fixture looped forever reversing the
  -- SAME accepted hunk, because every reintegration re-armed it. A
  -- reintegrated review needs no anchor of its own either way: if the
  -- operator decides it again, that decision's own predecessor in the
  -- journal is simply whatever row was already there (the file's own
  -- history did not go anywhere).
  if not change._retrace_reintegration then
    local obs = tl_observe(bufnr)
    state.timeline_obs = obs
    obs.regime = "buffer"
    tl_record(state, "review_opened", "review opened: " .. (change.rel or change.path or "?"), obs, true)
  end
  ledger.mark(change_ledger(change, opts), "review_profile_state_ready")

  local function show_hint(line, block)
    state.hint_line = line
    -- Remember WHICH hunk the badge belongs to, not just the line it landed
    -- on: the line is an integer and goes stale the moment the human types
    -- above the hunk, so a later redraw has to re-resolve it (WinResized).
    state.hint_block = block
    if state.hint_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, HINT_NS, state.hint_id)
    end
    -- Whole-review abort -- the operator ruling that `cR` rewinds every
    -- file in the turn, not just this one -- is spelled out in full as
    -- "abort review" at the end so
    -- nothing reading this ribbon confuses it with `%s: reject file`
    -- (`maps.reject_file`/cx) above it. `cR` is hardcoded, not `maps`-driven, same
    -- as the keymap.set("cR", ...) below.
    local full_hint = string.format(
      "[%s: accept hunk, %s: reject hunk, %s: accept file, %s: accept everything, %s: reject file, %s: prev, %s: next, %s: abort review]",
      maps.theirs or "ca",
      maps.ours or "cr",
      maps.all_theirs or "cf",
      maps.all_changes or "cA",
      maps.reject_file or "cx",
      maps.prev or "[x",
      maps.next or "]x",
      "cR"
    )
    local compact_hint = string.format(
      "[%s accept · %s reject · %s/%s hunks]",
      maps.theirs or "ca",
      maps.ours or "cr",
      maps.next or "]x",
      maps.prev or "[x"
    )
    local source_line = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
    local source_width = vim.fn.strdisplaywidth(source_line)
    local available = nil
    for _, win in ipairs(vim.api.nvim_list_wins()) do
      if vim.api.nvim_win_get_buf(win) == bufnr then
        local info = vim.fn.getwininfo(win)[1]
        local text_width = info and (info.width - info.textoff) or vim.api.nvim_win_get_width(win)
        local room = math.max(0, text_width - source_width - 1)
        available = available and math.min(available, room) or room
      end
    end
    available = available or math.max(0, vim.o.columns - source_width - 1)
    local hint = nil
    for _, candidate in ipairs({ full_hint, compact_hint, "[review]" }) do
      if vim.fn.strdisplaywidth(candidate) <= available then
        hint = candidate
        break
      end
    end
    -- right_align virtual text overwrites buffer text when both cannot fit.
    -- In that case the mappings remain active, but no hint is safer than
    -- obscuring the change being reviewed.
    if not hint then
      state.hint_id = nil
      return
    end
    state.hint_id = vim.api.nvim_buf_set_extmark(bufnr, HINT_NS, line - 1, -1, {
      virt_text = { { hint, EXT_HL.hint } },
      virt_text_pos = "right_align",
    })
  end

  local function clear_hint()
    -- Delete the HINT MARK, not the namespace. The compound-mode banner lives
    -- in HINT_NS too and is created only at open, so clearing the whole
    -- namespace wipes the operator's mode indicator with nothing to put it
    -- back.
    if state.hint_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, HINT_NS, state.hint_id)
    end
    state.hint_id = nil
    state.hint_line = nil
    state.hint_block = nil
  end

  local function show_compound_mode(change)
    if state.mode_banner_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, HINT_NS, state.mode_banner_id)
      state.mode_banner_id = nil
    end
    local text = compound_mode_text(change)
    if not text then
      return
    end
    state.mode_banner_id = vim.api.nvim_buf_set_extmark(bufnr, HINT_NS, 0, 0, {
      virt_lines = { { { text, EXT_HL.hint } } },
      virt_lines_above = true,
    })
  end

  -- The review buffer being wiped is the engine's blind spot, and it is the
  -- one the operator's complaint is actually about: `:bwipeout` on the file
  -- under review (or on the preview scratch) destroyed the keymaps and the
  -- hunks while leaving `active` set, so the queue parked behind a review
  -- that no longer existed anywhere and every later edit sat unreviewed. The
  -- autocmds die with the buffer, so this is the last moment anything can
  -- notice. Scheduled because teardown must not run inside the wipe itself.
  -- BufUnload too, not just delete/wipe: `:bunload` (and buffer-removal
  -- plugins that use it) destroys the buffer text, extmarks and hunks while
  -- leaving the buffer handle valid, so the review became invisible with
  -- `active` still pointing at it -- the same desync, reached by a route the
  -- delete/wipe hooks miss entirely.
  -- FileChangedShellPost is the third route and the sneakiest: an autoread /
  -- `checktime` reload (`au FocusGained * checktime` is a common setting)
  -- REPLACES the buffer text when the file changes on disk, destroying every
  -- staged hunk and extmark -- while firing none of the unload/delete/wipe
  -- events above. `active` stayed set with stale diff_blocks, so a later `ct`
  -- accepted line ranges that no longer described anything: silent wrong-content
  -- writes, the worst outcome in this subsystem.
  --
  -- But tearing down on the BARE EVENT is just as wrong in the other direction,
  -- and that is the user-reported bug: anything that re-stamps the file without
  -- changing its bytes (a formatter that reformats to the same text, a `cp`, a
  -- checkout, the agent rewriting an identical result) killed a review that was
  -- perfectly intact. G1: content is the authority, stat is only a prefilter.
  --
  -- The obvious gate -- read `v:fcs_reason` and ignore "time" (G2) -- does NOT
  -- work here, and measuring that is what saved this fix from being a no-op.
  -- 'autoread' defaults ON and the staged buffer is deliberately unmodified,
  -- so `buf_check_timestamp` takes the autoread branch and reloads BEFORE it
  -- ever computes a reason or fires FileChangedShell. Probed on this build:
  --   identical-byte touch + checktime -> shell_fired=0 post_fired=1 reason=""
  -- So no reason is available on the route that actually fires, and a reason
  -- stashed by some EARLIER FileChangedShell would be stale -- trusting it
  -- would skip a teardown that was warranted. Content is the only honest input.
  vim.api.nvim_create_autocmd({ "FileChangedShellPost" }, {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      state.fcs_post_count = (state.fcs_post_count or 0) + 1
      local buf_now = diff.buffer_bytes_snapshot(bufnr)
      local did_reload = buf_now ~= nil and state.staged_text ~= nil and buf_now ~= state.staged_text
      local reload_unload_token = nil
      if did_reload then
        state.reload_restaging = true
        state.watch_suspended = true
        reload_unload_token = (state.reload_unload_token or 0) + 1
        state.reload_unload_token = reload_unload_token
        state.ignore_next_reload_unload = reload_unload_token
        vim.defer_fn(function()
          if state.ignore_next_reload_unload == reload_unload_token then
            state.ignore_next_reload_unload = nil
          end
        end, 100)
      else
        state.ignore_next_reload_unload = nil
      end
      vim.schedule(function()
        log.guard("yana.inline_diff FileChangedShellPost", function()
        local function release_reload_restaging()
          vim.schedule(function()
            state.reload_restaging = false
            state.watch_suspended = false
          end)
        end
        local st = pool_for_state(state)
        if st.active ~= state then
          state.reload_restaging = false
          state.watch_suspended = false
          return
        end
        if not did_reload then
          state.reload_restaging = false
          state.watch_suspended = false
          return
        end
        local function tear_down(reason, fp)
          release_reload_restaging()
          state.change.review_error = reason
          -- Every teardown from this handler is the reloaded-file refusal
          -- class. The conflict branch below adds the fingerprint pair; the
          -- branches that never got to read disk have none to add, and a
          -- missing field is honest where a fabricated one would not be.
          do
            local L = change_ledger(state.change, state.opts)
            ledger.record_decision(L, {
              action = "review_refused",
              actor = "system",
              reason = "reloaded_file",
              detail = reason,
              change_id = state.change.id,
              rel = state.change.rel or state.change.path,
              expected_fp = fp and fp.expected_fp or nil,
              actual_fp = fp and fp.actual_fp or nil,
            })
          end
          pcall(M.cleanup, state)
          st.active = nil
          announce_state()
          process_next_for(state.opts)
        end
        -- A deletion review holds no on-disk `after` to compare against, so
        -- there is nothing to re-validate: keep the conservative teardown.
        if change.kind == "delete" then
          return tear_down("the file changed on disk and was reloaded; the staged hunks are gone")
        end
        local disk_now, disk_err = diff.read_file_bytes(change.path)
        if disk_now == nil then
          return tear_down(disk_err or "the file changed on disk and was reloaded; the staged hunks are gone")
        end
        local base = change.disk_at_open or ""
        local was_identical = disk_now == base
        -- Root cause (closed here): a "content-identical" external reload
        -- (e.g. `git checkout -- <file>` restoring exactly `disk_at_open`,
        -- followed by `:checktime`) still routes through Neovim's OWN
        -- autoread reload before this handler ever runs, and that reload
        -- replaces the buffer wholesale. Every block's `authority_extmark_id`
        -- either survives that round trip at its correct position or is
        -- silently left pointing at the WRONG one -- `live_block_range`
        -- cannot tell the difference, because a displaced extmark still
        -- reads as "valid". The former "tier 1" branch trusted those old
        -- extmarks unconditionally (it re-rendered `state.diff_blocks`
        -- as-is), so a displaced one made `paint_spans_for_block` search the
        -- wrong window, find nothing, and withdraw that hunk's band via
        -- `authority_lost` -- while `state.diff_blocks`'s length, and
        -- therefore the pending count, never moved. Worse, `:w`'s
        -- `M._compose_buffer_owned_lines` reads the SAME stale extmark to
        -- decide what to withhold, so the save silently substituted at the
        -- wrong lines too: an agent hunk's bytes reached disk while the
        -- pending count still claimed it was withheld (ruling 72 broken by
        -- silence, not by decision).
        --
        -- The fix is the same one "tier 2" (a genuine outside-hunk disk
        -- edit) already used: never trust a surviving extmark across a
        -- reload. Recompose the file's bytes purely from the MODEL
        -- (`block.start_line`/`old_lines`/`new_lines`, which `absorb_human_edits`
        -- keeps current and which a buffer-replacing reload cannot perturb),
        -- write that composition into the buffer, and only THEN rebuild every
        -- block and its extmark fresh via `M.build_diff_blocks` against the
        -- buffer that is now actually on screen. A content-identical reload
        -- is simply the `disk_hunks == {}` case of the same recompose --
        -- there is no longer a separate "tier 1" path for a stale extmark to
        -- hide in.
        local composed, compose_err = apply_review_blocks_to_reloaded_disk(base, disk_now, state.diff_blocks)
        if not composed then
          -- The one branch here that HAS both sides of the disagreement:
          -- record the fingerprint pair (truncated hashes, never contents) so
          -- "which of the three versions did the check actually see" is
          -- answerable after the fact.
          return tear_down(
            compose_err or "conflict: file changed on disk inside a reviewed hunk",
            { expected_fp = fingerprint(base), actual_fp = fingerprint(disk_now) }
          )
        end
        -- Outside-hunk disk edits (or none at all) are kept. The file's base
        -- evidence is advanced before accept, otherwise the later CAS would
        -- refuse a merge that this handler has already validated and staged.
        --
        -- Sealed either side, like every other product-initiated edit to this
        -- buffer: the re-stage is one undo block of its own, so it neither
        -- swallows the human's last keystroke nor merges into the next
        -- decision.
        break_undo_block(bufnr)
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(composed))
        break_undo_block(bufnr)
        vim.bo[bufnr].modified = false
        change.disk_at_open = disk_now
        -- The CAS the applier runs immediately before the write compares
        -- `change.base_hash`, NOT `disk_at_open`: shadow/apply.lua:302-320
        -- hands that fingerprint to the diary and the diary re-reads the file
        -- one step before the rename. Advancing only `disk_at_open` here
        -- refreshed the evidence this module checks and left the evidence the
        -- WRITE checks pointing at bytes that no longer exist, so every
        -- tier-2 accept was refused as human drift against a merge this
        -- handler had already validated. Advance the fingerprint pair with
        -- the bytes, and nothing else: the read that authorises the write
        -- still happens at the applier, one step before it.
        local rehash = base_fingerprint(disk_now)
        if rehash then
          change.base_hash = rehash
          change.base_state = "file"
          local st_now = (vim.uv or vim.loop).fs_lstat(change.path)
          if st_now and st_now.mode then
            change.base_mode = st_now.mode
          end
        end
        -- `before` is the bytes a reject restores. The review now stands on
        -- the reloaded composition, so leaving it at the pre-reload base would
        -- make a reject wipe the human's outside-hunk edit out of the buffer.
        change.before = disk_now
        state.staged_text = composed
        state.latest_undo_seq = buf_undo_seq(bufnr)
        local recomposed, recomposed_source = recomposed_model(disk_now, composed, change.path)
        state.diff_blocks = stamp_model_index(M.build_diff_blocks(disk_now, composed), recomposed)
        -- The payload the review now stands on is the reloaded composition, so
        -- the model is re-derived from that pair. Comparing the new render
        -- against the ORIGINAL model would report a violation for a legitimate
        -- rebuild, and a check that cries wolf gets ignored.
        state.model_hunks = recomposed
        state.model_source = recomposed_source
        render_blocks(bufnr, state.diff_blocks, {
          site = was_identical and "reload_identical" or "reload_composed",
          model = state.model_hunks,
          model_source = state.model_source,
          change = change,
          opts = state.opts,
        })
        -- R8: the reload finished recomposing and repainting -- fired for
        -- both the content-identical and the genuinely-recomposed case,
        -- never for the two `tear_down(...)` refusal returns above (those
        -- close the review as a refusal, not a settle; `finish_session` is
        -- never reached from either, so no OTHER YanaReviewSettled follows
        -- them either).
        M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "reload")
        release_reload_restaging()
        end)
      end)
    end,
  })

  -- `:edit!` clears the buffer before BufReadPost, and after that callback the
  -- old undo branch is gone. BufReadCmd is the last point where Neovim can
  -- still jump back to the exact live review state. Intercept the read there:
  -- identical disk restores that sequence, preserving human edits and every
  -- decision boundary; changed disk is loaded and the queued BufUnload handler
  -- closes the review rather than guessing a merge.
  vim.api.nvim_create_autocmd("BufReadCmd", {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      local st = pool_for_state(state)
      if st.active ~= state or change.kind == "delete" then
        return
      end
      local disk_now = diff.read_file_bytes(change.path)
      local base = change.disk_at_open or ""
      if disk_now ~= base or type(state.staged_text) ~= "string" then
        local disk_text = disk_now or ""
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(disk_text))
        local has_eol = disk_text:match("\n$") ~= nil
        vim.bo[bufnr].fixendofline = has_eol
        vim.bo[bufnr].endofline = has_eol
        vim.bo[bufnr].modified = false
        return
      end
      local token = (state.reload_unload_token or 0) + 1
      state.reload_unload_token = token
      state.ignore_next_reload_unload = token
      local expected = state.reload_unload_text or state.staged_text
      state.reload_unload_text = nil
      state.restoring_reload = true
      local restored = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent undo")
      end)
      state.restoring_reload = false
      local snap = restored and diff.buffer_bytes_snapshot(bufnr) or nil
      if snap ~= expected then
        state.ignore_next_reload_unload = nil
        state.reload_restore_error = "reload cleared the review's undo history; review closed without accepting anything"
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(disk_now or ""))
        vim.bo[bufnr].modified = false
        return
      end
      state.staged_text = expected
      state.latest_undo_seq = buf_undo_seq(bufnr)
      state.reload_restore_seq = state.latest_undo_seq
      state.reload_redo_guard = true
      vim.bo[bufnr].modified = false
      attach_buffer_watch(state)
      vim.schedule(function()
        log.guard("yana.inline_diff direct reload", function()
          if pool_for_state(state).active ~= state then
            return
          end
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end
          for _, block in ipairs(state.diff_blocks or {}) do
            block.authority_extmark_id = nil
            block.incoming_extmark_id = nil
            block.incoming_extmark_ids = nil
            block.delete_extmark_id = nil
          end
          render_blocks(bufnr, state.diff_blocks, {
            site = "direct_reload_identical",
            model = state.model_hunks,
            model_source = state.model_source,
            change = change,
            opts = state.opts,
          })
          tl_sync_observation(state)
        end)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete", "BufUnload" }, {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      state.reload_unload_text = diff.buffer_bytes_snapshot(bufnr)
      vim.schedule(function()
        log.guard("yana.inline_diff BufWipeout", function()
          if state.ignore_next_reload_unload then
            state.ignore_next_reload_unload = nil
            return
          end
          local st = pool_for_state(state)
          if st.active == state then
            local sfm_refusal = require("yana.shadow.apply").single_file_accept_refusal(state.change, bufnr)
            if sfm_refusal then
              state.reload_restore_error = nil
              M._record_shadow_accept_refusal(state, sfm_refusal)
              return
            end
            state.change.review_error = state.reload_restore_error
              or "review buffer was closed before the hunks were resolved"
            state.reload_restore_error = nil
            pcall(M.cleanup, state)
            st.active = nil
            announce_state()
            process_next_for(state.opts)
          end
        end)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "WinEnter" }, {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      log.guard("yana.inline_diff WinEnter", apply_review_winhl, bufnr, state)
    end,
  })

  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      log.guard("yana.inline_diff CursorMoved", function()
        local block = current_block(state.diff_blocks, bufnr)
        if block then
          show_hint(nav_start_line(bufnr, block), block)
        else
          clear_hint()
        end
      end)
    end,
  })

  vim.api.nvim_create_autocmd("WinResized", {
    group = state.augroup,
    callback = function()
      log.guard("yana.inline_diff WinResized", function()
        if state.hint_block then
          -- Redraw at the hunk's LIVE line. Replaying state.hint_line would
          -- repaint the badge where the hunk WAS before the human typed. A
          -- resolved hunk's badge is cleared at resolve time, so there is no
          -- stale block to replay here.
          show_hint(nav_start_line(bufnr, state.hint_block), state.hint_block)
        elseif state.hint_line then
          -- The no-hunks-left badge at line 1: it belongs to no hunk and no
          -- edit can displace it.
          show_hint(state.hint_line)
        end
      end)
    end,
  })

  --- Park a DECISION ANCHOR over the range this hunk occupied when it was
  --- decided, in the namespace no repaint clears. This is what an un-decide
  --- resurrects the hunk from.
  ---
  --- WHY NOT JUST KEEP THE AUTHORITY MARK. Because the very next repaint takes
  --- it: highlight_blocks clears AUTH_NS wholesale and rebuilds marks only for
  --- the blocks still in the list, so a resolved hunk's authority mark cannot
  --- survive the render that follows its own decision. A separate namespace is
  --- the same idea made repaint-proof, and it also sidesteps the freed-id
  --- reuse hazard clear_extmarks documents below: this id is never freed while
  --- the decision stands, so it cannot be reissued to another hunk.
  ledger.mark(change_ledger(change, opts), "review_profile_watchers_ready")

  local function park_anchor(block, start_line, end_line)
    return park_decision_anchor(bufnr, start_line, end_line)
  end

  local function anchor_range(id)
    if not id then
      return nil
    end
    local ext = vim.api.nvim_buf_get_extmark_by_id(bufnr, ANCHOR_NS, id, { details = true })
    if not ext or ext[1] == nil then
      return nil
    end
    local meta = ext[3] or {}
    local start_line = ext[1] + 1
    local end_line = (meta.end_row or ext[1]) + 1
    return start_line, end_line
  end

  local function drop_anchor(id)
    if id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, ANCHOR_NS, id)
    end
  end

  local function clear_extmarks(block)
    -- REC-PLANT seam (`sticky_paint`, default off, see FAULT above). MEASURED
    -- (tests/headless/rec_plant_sticky_paint_survives_decision.lua): skipping
    -- only the wholesale clear in `highlight_blocks` keeps the PREVIOUS
    -- repaint's marks for hunks that are still pending (doubled bands) and
    -- keeps NOTHING for the hunk just decided -- this runs first and deletes
    -- that block's own ids before any repaint. The staged defect is "the hunk
    -- I just decided is still painted", so the seam is read here too.
    if M._fault_keeps_paint(state.diff_blocks, block) then
      return
    end
    -- Forget the ids as well as deleting the marks. nvim REISSUES a freed id
    -- to the next extmark created in that namespace, so a resolved block that
    -- keeps its old id does not read as invalidated -- it reads as whichever
    -- surviving hunk inherited the number, and any stale reference to this
    -- block then silently resolves to another hunk's position.
    if block.incoming_extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, block.incoming_extmark_id)
      block.incoming_extmark_id = nil
    end
    if block.delete_extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, NS, block.delete_extmark_id)
      block.delete_extmark_id = nil
    end
    if block.authority_extmark_id then
      pcall(vim.api.nvim_buf_del_extmark, bufnr, AUTH_NS, block.authority_extmark_id)
      block.authority_extmark_id = nil
    end
  end


  --- `redo_of` (ruling 75, one register): the id of the register row this
  --- decision PUTS BACK after a cross-file `u` reverted it. The row already
  --- exists and reads `reverted` only because the buffer head sits before it,
  --- so the redo moves the head back onto that row instead of recording a
  --- second row for the same hunk -- two rows for one decision made the next
  --- `u` undo the same hunk twice (measured, r75_redo_after_cross_file_undo).
  local function reject_block_at(idx, redo_of)
    local block = state.diff_blocks[idx]
    if not block then
      return
    end
    -- SEAL FIRST, before anything is recorded or restored: whatever the human
    -- typed before pressing this key becomes its own undo block here, so their
    -- edit and this restoration cannot share one, and every seq read below
    -- names a settled state rather than a block still open.
    break_undo_block(bufnr)
    tl_capture_human_edit(state)
    local start_line, end_line, range_err = live_block_range(bufnr, block)
    if not start_line then
      change.review_error = range_err or "hunk invalidated"
      notify_one_line("yana: " .. change.review_error, vim.log.levels.WARN)
      return
    end
    -- Interior human rows are never part of the proposal (ruling 2026-08-25);
    -- reject restores the agent's old_lines and leaves those rows standing.
    local restored = reject_restoration(bufnr, block, start_line, end_line)
    record_decision(state, "reject_hunk", {
      hunk = idx,
      model_index = block.model_index,
      row = start_line,
      old_count = #(block.old_lines or {}),
      new_count = #(block.new_lines or {}),
    })
    clear_extmarks(block)
    local replaced = (end_line >= start_line) and (end_line - start_line + 1) or 0
    -- ONE HUNK, ONE UNDO BLOCK. `pre_seq` is the state to send the buffer back
    -- to if this decision is taken back; the sync after the restoration seals
    -- it so nothing later can be added to the same block.
    local pre_seq = buf_undo_seq(bufnr)
    if redo_of then
      -- REDO OF A WALK-REVERTED REJECT (ruling 75, one register). The
      -- cross-file `u` took these bytes out with Neovim's own `:undo`, so the
      -- tree's next state forward IS this rejection's bytes at the row's own
      -- seq. Take them back with `:redo` -- writing them afresh would mint a
      -- new seq on a new branch, which the register then read as the human's
      -- edit and pruned every redo step behind it (measured,
      -- r75_redo_replays_mixed_decisions_in_order).
      local ok_redo = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent redo")
      end)
      local now = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, start_line - 1 + #restored, false)
      if not ok_redo or not vim.deep_equal(now, restored) then
        pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("silent undo " .. tonumber(pre_seq))
        end)
        change.review_error = "redo no longer matches the rejection it would put back"
        notify_one_line("yana: " .. change.review_error, vim.log.levels.WARN)
        return
      end
    else
      vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, restored)
    end
    break_undo_block(bufnr)
    -- Truthful modified flag after a per-hunk reject (ruling 79): reset only
    -- the dirtiness this restoration caused. Unrelated outside-hunk bytes keep
    -- modified true; reject-only restoration with sibling pending hunks yields
    -- false. Mirrors reject-all's recompute — do not force true here.
    M._recompute_modified(bufnr, state.diff_blocks, change.path)
    local delta = #restored - replaced
    -- The anchor spans what the restoration LEFT in the buffer, so an
    -- un-decide can find the region again after the human has typed above it.
    local anchor = park_anchor(block, start_line, start_line + math.max(#restored, 1) - 1)
    state.decisions[#state.decisions + 1] = {
      -- A NEW decision makes any remembered undo unredoable: the tree has
      -- branched, and a redo stack pointing into the abandoned branch would
      -- re-apply a decision to bytes that no longer exist.
      action = "reject",
      idx = idx,
      block = block,
      delta = delta,
      pre_seq = pre_seq,
      post_seq = buf_undo_seq(bufnr),
      anchor = anchor,
    }
    if redo_of then
      state.decisions[#state.decisions].timeline_id = redo_of
      M._tl_head_row(state, redo_of, false)
      M._retrace_forget_reverted(change, block.model_index or idx, redo_of)
      -- The bytes moved by Yana's own hand: the next human-edit capture
      -- measures from here, not from before the redo.
      state.timeline_obs = tl_observe(bufnr)
    else
      local obs = tl_observe(bufnr)
      obs.regime = "buffer"
      state.decisions[#state.decisions].timeline_id = tl_record(state, "hunk_rejected",
        "reject hunk " .. tostring(block.model_index or idx), obs)
      state.timeline_obs = obs
    end
    state.diff_blocks = remove_block(state.diff_blocks, idx, false, delta)
    if state.hint_block == block then
      clear_hint()
    end
    local snap = diff.buffer_bytes_snapshot(bufnr)
    if snap then
      state.staged_text = snap
      state.latest_undo_seq = buf_undo_seq(bufnr)
      -- Keep `change.after` in step with `state.staged_text` on EVERY per-hunk
      -- reject that leaves the review open. When `modified` is recomputed
      -- truthfully (ruling 79 / P118) it is often false after a reject with
      -- sibling pending hunks; without this sync the parked reopen's
      -- `existing_modified` gate misses and the reopen falls through to
      -- fresh staging that overwrites still-pending siblings (r75 redo walk).
      -- Retrace reintegration needs the same sync for its fast path.
      change.after = snap
    end
    render_blocks(bufnr, state.diff_blocks, {
      site = "reject_hunk",
      model = state.model_hunks,
      model_source = state.model_source,
      change = change,
      opts = state.opts,
    })
    -- R8: fired AFTER render_blocks (this hunk's paint) whether or not this
    -- was the LAST hunk. If it was, `try_finalize` below closes the review
    -- and finish_session's own tail fires a SECOND event named
    -- `"reject_file"`/`"accept_file"`/`"abort"` -- a waiter for either name
    -- still sees at least one, and a waiter for the specific file-level name
    -- is not fooled by this hunk-level one.
    M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "reject_hunk")
    land_on(change.path, bufnr, nearest_block(state.diff_blocks, bufnr, "next"))
    try_finalize(state)
  end

  local function accept_block_at(idx, redo_of)
    local block = state.diff_blocks[idx]
    if not block then
      return
    end
    -- Seal the human's pending typing into its own block before anything else,
    -- so the seq recorded below names a settled state. Accept moves NO bytes --
    -- the agent's content has been in this buffer since the review opened -- so
    -- this adds no undo state of its own (measured: a sync with nothing pending
    -- creates none), and `pre_seq == post_seq` for an accept is the truth
    -- rather than a placeholder.
    break_undo_block(bufnr)
    tl_capture_human_edit(state)
    local at_seq = buf_undo_seq(bufnr)
    local start_line, _, range_err = live_block_range(bufnr, block)
    if not start_line then
      -- UNTRUSTWORTHY AUTHORITY MARK: a mark this engine can no longer
      -- resolve is STATED and REFUSED, never silently recovered. A prior
      -- version of this branch tried to route around an invalidated mark by
      -- matching the hunk's staged bytes against its last-known static
      -- coordinates, and accepted through that match without saying
      -- anything -- so a hunk this engine can no longer trust its own
      -- position for was accepted (and, being the only pending hunk, the
      -- whole review torn down) with no WARN and no `review_error` at all.
      -- reject_block_at never had that bypass; this makes accept match it,
      -- rather than adding a guard that only closes the one case the
      -- fault-injection fixture injects. Investigated 2026-08-25: every
      -- ordinary path that clears an authority mark (`highlight_blocks`,
      -- `absorb_human_edits`, the reload-restage rebuild) recreates or
      -- reports it before a decision's own `live_block_range` read ever
      -- runs -- `tl_capture_human_edit` above flushes a pending absorb
      -- synchronously, in the same tick, before this line. `:checktime`/
      -- autoread reloads were measured (identical bytes, an outside-hunk
      -- change, and a full rewrite) to leave the mark intact. No real
      -- sequence was found that reaches this branch; it is a fault-
      -- injection guard, not a reachable gap.
      change.review_error = range_err or "hunk invalidated"
      notify_one_line("yana: " .. change.review_error, vim.log.levels.WARN)
      return
    end
    record_decision(state, "accept_hunk", {
      hunk = idx,
      model_index = block.model_index,
      row = start_line,
      old_count = #(block.old_lines or {}),
      new_count = #(block.new_lines or {}),
    })
    local a_start, a_end = live_block_range(bufnr, block)
    local anchor = park_anchor(block, a_start or start_line, a_end or start_line)
    state.decisions[#state.decisions + 1] = {
      -- A NEW decision makes any remembered undo unredoable: the tree has
      -- branched, and a redo stack pointing into the abandoned branch would
      -- re-apply a decision to bytes that no longer exist.
      action = "accept",
      idx = idx,
      block = block,
      delta = 0,
      pre_seq = at_seq,
      post_seq = at_seq,
      anchor = anchor,
    }
    if redo_of then
      state.decisions[#state.decisions].timeline_id = redo_of
      M._tl_head_row(state, redo_of, false)
      M._retrace_forget_reverted(change, block.model_index or idx, redo_of)
      state.timeline_obs = tl_observe(bufnr)
    else
      local obs = tl_observe(bufnr)
      obs.regime = "buffer"
      state.decisions[#state.decisions].timeline_id = tl_record(state, "hunk_accepted",
        "accept hunk " .. tostring(block.model_index or idx), obs)
      state.timeline_obs = obs
    end
    -- Ruling 79/87: accept moves this hunk's lines to buffer ownership
    -- without moving any bytes (the agent's text has sat in this buffer,
    -- unpainted now, since the review opened), so no edit fires here to set
    -- `modified` for us the way a real keystroke would. Set it directly --
    -- not a comparison, so not routed through `M._recompute_modified`; the
    -- same unconditional assignment finish_session's own accept-transfer
    -- branch already makes (line ~2992) for the identical event, whole-
    -- session there, one hunk here.
    vim.bo[bufnr].modified = true
    clear_extmarks(block)
    state.diff_blocks = remove_block(state.diff_blocks, idx, true)
    if state.hint_block == block then
      clear_hint()
    end
    render_blocks(bufnr, state.diff_blocks, {
      site = "accept_hunk",
      model = state.model_hunks,
      model_source = state.model_source,
      change = change,
      opts = state.opts,
    })
    -- R8: see the matching comment in reject_block_at just above.
    M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "accept_hunk")
    land_on(change.path, bufnr, nearest_block(state.diff_blocks, bufnr, "next"))
    try_finalize(state)
  end

  local function reject_hunk()
    local block, idx = current_block(state.diff_blocks, bufnr)
    if not block then
      return
    end
    reject_block_at(idx)
  end

  local function accept_hunk()
    local block, idx = current_block(state.diff_blocks, bufnr)
    if not block then
      return
    end
    accept_block_at(idx)
  end

  --- `redo_of` (ruling 75, one register): the id of the register row this
  --- decision PUTS BACK after a cross-file `u` reverted it -- the same
  --- contract `accept_block_at`'s own `redo_of` carries, generalised to the
  --- whole file. Accept moves no bytes regardless of how many hunks it
  --- covers, so this is exactly `accept_block_at`'s redo_of branch, done once
  --- for every remaining hunk instead of one.
  local function accept_all(redo_of)
    tl_capture_human_edit(state)
    record_decision(state, "accept_file", { hunks_remaining = #state.diff_blocks })
    -- ONE FILE-LEVEL DECISION, ONE REGISTER ROW (ruling 75): every hunk this
    -- ONE `ca` invocation accepts is named in `members` on a SINGLE
    -- `file_accepted` row -- never one `hunk_accepted` row per hunk.
    local members = {}
    for i, block in ipairs(state.diff_blocks) do
      members[#members + 1] = {
        hunk = block.model_index or i,
        old_count = #(block.old_lines or {}),
        new_count = #(block.new_lines or {}),
      }
    end
    if redo_of then
      M._tl_head_row(state, redo_of, false)
      state.timeline_obs = tl_observe(bufnr)
    else
      local obs = tl_observe(bufnr)
      obs.regime = "buffer"
      obs.members = members
      tl_record(state, "file_accepted",
        "accept all " .. #members .. " hunk(s)", obs)
      state.timeline_obs = obs
    end
    state.diff_blocks = {}
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, AUTH_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, HINT_NS, 0, -1)
    finish_session(state, true)
  end

  ----------------------------------------------------------------------
  -- DECISION UNWIND -- `u` and `U` while the review is open.
  --
  -- THE RULE THIS OBEYS. There are two owners here and there always were:
  -- Neovim owns the buffer's TEXT history, and this module already owns the
  -- DECISION history (state.diff_blocks, record_decision, the ledger rows).
  -- Each undoes only its own state. Every byte restoration below is
  -- `:undo {seq}` -- Neovim moving its own buffer through its own tree -- and
  -- what this module holds is INTEGERS and decision records, never a copy of
  -- the text. That is the distinction the product's worst measured defect got
  -- wrong (pre-ce50120 reject wrote a held `change.before` snapshot over the
  -- human's buffer and marked it clean), and the vendor's too
  -- (the upstream rejection behavior, FileChangeTracker.reject).
  --
  -- WHY A DECISION STACK AT ALL, when the ruling says "u hunk by hunk". Because
  -- ACCEPT MOVES NO BYTES. The review buffer holds the agent's content from the
  -- moment it opens, so accepting a hunk is bookkeeping: there is no undo block
  -- for it and no boundary placement can create one. A `u` built only out of
  -- undo blocks could never take an accept back, and most decisions are
  -- accepts. Measured by the per-hunk undo regression case.
  --
  -- WHY THIS CANNOT REACH THE APPLIER, structurally rather than by discipline.
  -- No decision is durable while the review is open: try_finalize calls
  -- finish_session(state, true) only once all_resolved is true, and the review
  -- closes there, releasing these maps with it. So the window in which `u` and
  -- `U` are bound is exactly the window in which un-deciding touches nothing
  -- but extmarks and a Lua table. There is no state in which an un-decide can
  -- reach the real tree, because the review that owns these keys is gone before
  -- the write happens.
  ----------------------------------------------------------------------

  --- One WARN line naming what is wrong, and the hunk keys still work. Never
  --- silent, and never a write.
  local function undo_refuse(why)
    change.review_error = why
    notify_one_line("yana: " .. why .. " -- decide with co/ct/cb", vim.log.levels.WARN)
  end

  --- Plain Neovim undo in this buffer. Reached whenever the newest thing in
  --- the tree is the human's own edit rather than one of this review's
  --- decisions, so the operator's `u` keeps meaning what it means everywhere
  --- else for the text they typed.
  --- Repaint after the buffer has been moved by Neovim's own history rather
  --- than by a decision. F2 (operator report, 2026-08-19): undo and redo move
  --- the TEXT plane without telling the review, so without this the paint keeps
  --- describing rows whose content has changed underneath it. Re-rendering
  --- makes `set_incoming_paint` re-check each hunk's content against the
  --- buffer, so a hunk whose lines are no longer there loses its highlight and
  --- says so, instead of staying green over whatever now occupies the range.
  --- This repaints, it does not reconcile: the decision stack is not rewritten
  --- here, because a tree movement is not a decision and guessing which
  --- decision it corresponds to is exactly the reconciliation that would need
  --- to be right every time.
  local function rerender_after_history_move(site)
    local snap = diff.buffer_bytes_snapshot(bufnr)
    if snap then
      state.staged_text = snap
      state.latest_undo_seq = buf_undo_seq(bufnr)
    end
    -- The move above was YANA's -- this review's own `u`/`<C-r>` issued the
    -- `:undo`/`:redo`. Tell the register where it left the buffer, or the head
    -- keeps naming the position before the press and the NEXT press reads that
    -- as the operator having moved the tree out of band ("undo sequence
    -- drift: buffer is at seq N, but Yana's register head is seq N+1"), which
    -- refuses and undoes nothing, for the rest of the session. See
    -- `record.absorb_own_history_move` for the measurement.
    pcall(function()
      require("yana.timeline.record").absorb_own_history_move(bufnr)
    end)
    render_blocks(bufnr, state.diff_blocks, {
      site = site,
      model = state.model_hunks,
      model_source = state.model_source,
      change = change,
      opts = state.opts,
    })
    -- R8: `site` is already one of "native_undo"/"native_redo" (this
    -- function's only two callers), so it doubles as the settle reason with
    -- no extra parameter.
    M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, site)
  end

  local function native_undo()
    -- `silent` because "Already at oldest change" is Neovim's own message for a
    -- perfectly ordinary press and belongs to the editor, not to a review. It
    -- is a message and not an exception, so it does not reach the pcall; the
    -- pcall is there for the genuine faults, which get one logged line rather
    -- than being swallowed.
    local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("silent undo")
    end)
    if not ok then
      log.write("WARN", "yana.inline_diff native undo: " .. tostring(err))
    end
    rerender_after_history_move("native_undo")
  end

  --- The redo half of ONE popped decision (ruling 75, one register). Called
  --- by `yana.timeline.retrace.redo` when the top of the cross-file redo
  --- register is a decision THIS review popped (`pop_decision` pushed it
  --- there). Returns true when the decision stands again, or false plus a
  --- reason; the caller owns the message and the register entry.
  ---
  --- PRUNE RULE (Vim's own, row r75_new_action_prunes_redo): the buffer must
  --- sit exactly where the undo left it. Anything typed since makes the popped
  --- decision unreachable, and the caller drops it rather than replaying a
  --- decision over bytes it never described.
  local function redo_local(entry)
    local stack = state.undone_decisions or {}
    local top = stack[#stack]
    if top == nil then
      return false, "this review has no undone decision to put back"
    end
    if entry and entry.id ~= nil and top.timeline_id ~= nil and entry.id ~= top.timeline_id then
      return false, "the register's next step is not this review's last undone decision"
    end
    local before = buf_undo_seq(bufnr)
    if before == nil or top.pre_seq ~= before then
      return false, "pruned"
    end
    if before ~= state.reload_restore_seq then
      state.reload_redo_guard = nil
      state.reload_restore_seq = nil
    end
    -- Accepting a hunk moves no buffer bytes, so taking that decision back
    -- created no matching Neovim redo step. Restore only the review decision;
    -- consuming the editor's next redo here would replay an unrelated human
    -- edit and make the two histories disagree.
    local after = before
    if top.action ~= "accept" then
      local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent redo")
      end)
      if not ok then
        log.write("WARN", "yana.inline_diff redo: " .. tostring(err))
        rerender_after_history_move("native_redo")
        return false, tostring(err)
      end
      after = buf_undo_seq(bufnr)
    end
    if after ~= top.post_seq then
      -- The redo went somewhere other than the state this decision produced,
      -- so re-applying the decision would describe bytes that are not there.
      -- Put the buffer back and refuse: BOTH owners unchanged is the contract.
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent undo " .. tonumber(before))
      end)
      return false, "redo no longer matches the decision it would put back"
    end
    local redo_start, redo_end = live_block_range(bufnr, top.block)
    if not redo_start then
      pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent undo " .. tonumber(before))
      end)
      return false, "redo cannot recover that decision's hunk position"
    end
    -- Put the decision back beside its bytes. This is the exact inverse of
    -- the re-adoption in pop_decision: the block leaves the list again, the
    -- later blocks take their shift back, and the decision returns to the
    -- stack it came off.
    table.remove(stack)
    -- A decided hunk holds no authority mark. `reject_block_at` and
    -- `accept_block_at` both clear the block's extmarks before the decision
    -- is recorded, and re-applying a decision has to do the same or the block
    -- stays actionable while being resolved, caught by the review-state invariant,
    -- which asks the authority marks rather than the decision list.
    clear_extmarks(top.block)
    top.anchor = park_anchor(top.block, redo_start, redo_end)
    local blocks = state.diff_blocks
    for i, b in ipairs(blocks) do
      if b == top.block then
        table.remove(blocks, i)
        break
      end
    end
    if (top.delta or 0) ~= 0 then
      for i = top.idx, #blocks do
        blocks[i].new_start_line = blocks[i].new_start_line + top.delta
        blocks[i].new_end_line = blocks[i].new_end_line + top.delta
      end
    end
    state.decisions[#state.decisions + 1] = top
    -- ROW 112, the mirror of the pop: the decision stands again, so its
    -- register row does too.
    M._tl_head_row(state, top.timeline_id, false)
    record_decision(state, "redo_decision", {
      hunk = top.idx,
      model_index = top.block.model_index,
      redone = top.action,
    })
    local snap = diff.buffer_bytes_snapshot(bufnr)
    if snap then
      state.staged_text = snap
      state.latest_undo_seq = buf_undo_seq(bufnr)
    end
    rerender_after_history_move("native_redo")
    return true
  end

  --- `<C-r>` inside an open review. ONE register (ruling 75): every undone
  --- step -- this review's own popped decisions, another file's, a
  --- reintegrated one -- sits on `yana.timeline.retrace`'s redo stack in the
  --- order it was undone, and this key replays the top of it, whichever file
  --- it names. Only when that register has nothing for this press is redo
  --- the editor's own operation, passed straight through and repainted.
  ---
  --- Before this, `<C-r>` consulted a per-review stack first and asked the
  --- register only when the per-review stack was empty; the two disagreed
  --- about order (a decision undone in THIS file was skipped for an older one
  --- in another file) and a reintegrated undo's accept was announced as
  --- redone without ever being re-applied (operator clips 2026-08-23
  --- 12-41-06 and 12-43-32).
  local function redo_key()
    -- RULING 52 FIRST, and it is a LIFO question rather than a special case:
    -- the last thing `U` did was sweep the turn, so the first thing redo owes
    -- is that sweep's staged removals. Only once they are back does redo mean
    -- what it has always meant inside this review.
    if M._redo_staged_restores(state) then
      return
    end
    local before = buf_undo_seq(bufnr)
    if state.reload_redo_guard and before == state.reload_restore_seq then
      undo_refuse("redo cannot reapply the transient buffer state used by reload")
      rerender_after_history_move("native_redo")
      return
    end
    if before ~= state.reload_restore_seq then
      state.reload_redo_guard = nil
      state.reload_restore_seq = nil
    end
    local retrace_ok, retrace = pcall(require, "yana.timeline.retrace")
    local ok_tl, tl = pcall(require, "yana.timeline")
    if retrace_ok and retrace.redo and ok_tl then
      local known = tl.known_workspaces and tl.known_workspaces() or {}
      if #known == 0 then
        known = { vim.fn.getcwd() }
      end
      if retrace.redo(known) then
        return
      end
    end
    -- Nothing of Yana's to put back: the editor's own redo, repainted, and
    -- the editor's own silence when there is nothing newer (operator ruling
    -- 2026-08-23 night, ruling #100 extended to redo: a press Yana does
    -- nothing for must look exactly as if Yana were not installed). `redo`
    -- is run unsilenced so Neovim's own "Already at newest change" shows.
    local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
      vim.cmd("redo")
    end)
    if not ok then
      log.write("WARN", "yana.inline_diff redo: " .. tostring(err))
    end
    rerender_after_history_move("native_redo")
  end

  --- Take ONE decision back. Returns true when a decision was popped, false
  --- when it refused (and said so), and nil when there was no decision to pop.
  local function pop_decision()
    local top = state.decisions[#state.decisions]
    if top == nil then
      return nil
    end
    -- REJECT: Neovim puts the agent's bytes back, by walking its own tree to
    -- the state that held them. Nothing here writes lines.
    if top.action == "reject" and top.pre_seq ~= nil then
      -- SUPPRESSED (KI-1 ruling 2026-08-24): this is YANA's own `:undo {seq}`,
      -- not the operator time travelling. Without the guard the rewind
      -- reconciler reads Yana's own transaction as a crossing of the insert
      -- boundary.
      local ok = pcall(M._rewind_suppress, function()
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("silent undo " .. tonumber(top.pre_seq))
        end)
      end)
      if not ok then
        -- A reload past 'undoreload' clears the tree and the bookmark dies with
        -- it. Refuse by name; the decision stands and the hunk keys still work.
        undo_refuse("undo history no longer matches this review")
        return false
      end
    end
    -- Where the hunk is NOW. The anchor, not a stored line number: the human
    -- may have typed above it since the decision.
    local start_line, end_line = anchor_range(top.anchor)
    if start_line ~= nil then
      -- The anchor's END is a zero-width mark at the row after the hunk's
      -- last line (`park_decision_anchor`, end_right_gravity=true). A REJECT
      -- decision's own `:undo` just above -- reverting straight back through
      -- this hunk's row -- widens that boundary by one row (measured: (4,4)
      -- before the undo, (4,5) after), so re-deciding a `U`-resurrected hunk
      -- ate one extra live line (issue row 97). The hunk's own known content
      -- length is authoritative; re-derive the end from it instead of
      -- trusting the anchor's end row.
      local n = #(top.block.new_lines or {})
      end_line = (n > 0) and (start_line + n - 1) or (start_line - 1)
    end
    if start_line == nil then
      start_line, end_line = live_block_range(bufnr, top.block)
    end
    if start_line == nil then
      undo_refuse("that hunk's position is no longer knowable, so the decision cannot be taken back")
      return false
    end
    -- ATTRIBUTION. Clean case: the region holds exactly what the agent
    -- proposed, so re-adopting it is free. Otherwise the human has been in
    -- there -- most sharply after a `<C-r>` that re-applied a rejection's bytes
    -- without re-making the decision -- and the same separator every reject
    -- path uses decides whether the two authors can still be told apart. It
    -- refuses BY NAME rather than merging, and the decision stands.
    local live = {}
    if end_line >= start_line then
      live = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
    end
    if not lines_equal(live, top.block.new_lines or {}) then
      local restored, merge_err = reject_restoration(bufnr, top.block, start_line, end_line)
      if not restored then
        record_decision(state, "undo_decision_refused", {
          hunk = top.idx,
          model_index = top.block.model_index,
          reason = "undo_would_discard_human_edit",
          detail = merge_err,
        })
        undo_refuse("refused to take back that decision -- " .. tostring(merge_err) .. "; it stands")
        return false
      end
    end
    -- Re-adopt. remove_block shifted every later block by `delta` when this one
    -- left; put that back before the block returns to its own index.
    --
    -- REMEMBERED FOR REDO. Until 2026-08-19 `<C-r>` re-applied a rejection's
    -- BYTES without re-making the decision, so the buffer said the hunk was
    -- rejected while the review still listed it as pending — the disagreement
    -- the review-state invariant forbids and users experience as the review
    -- "losing track". Keeping the popped decision here is what lets redo move
    -- both owners together or refuse.
    state.undone_decisions = state.undone_decisions or {}
    state.undone_decisions[#state.undone_decisions + 1] = top
    table.remove(state.decisions)
    -- ONE REGISTER (ruling 75): the popped decision joins the cross-file redo
    -- register in undo order, so `<C-r>` -- pressed here or in any other
    -- file of the turn -- replays steps in the reverse of the order they were
    -- undone, never this review's stack ahead of an older one elsewhere.
    pcall(function()
      local retrace = require("yana.timeline.retrace")
      local ws = change.review_workspace or (state.opts and state.opts.workspace) or vim.fn.getcwd()
      retrace.push_review_redo({
        workspace = ws,
        rel = change.rel or change.path,
        id = top.timeline_id,
        kind = top.action == "accept" and "hunk_accepted" or "hunk_rejected",
        regime = "review",
        bufnr = bufnr,
        hunk = top.block and top.block.model_index or top.idx,
        redo = redo_local,
      })
    end)
    -- ROW 112: one register. This decision's own timeline row now reads
    -- `reverted`, so the cross-file `u` never spends a press on it again.
    M._tl_head_row(state, top.timeline_id, true)
    drop_anchor(top.anchor)
    local blocks = state.diff_blocks
    if (top.delta or 0) ~= 0 then
      for i = top.idx, #blocks do
        blocks[i].new_start_line = blocks[i].new_start_line - top.delta
        blocks[i].new_end_line = blocks[i].new_end_line - top.delta
      end
    end
    top.block.new_start_line = start_line
    top.block.new_end_line = math.max(end_line, start_line - 1)
    -- The authority mark this block used to own went with the repaint that
    -- followed its decision. Forget the dead id so live_block_range does not
    -- read a number that has since been reissued, and let highlight_blocks
    -- rebuild the mark from the range just resolved.
    top.block.authority_extmark_id = nil
    top.block.incoming_extmark_id = nil
    top.block.delete_extmark_id = nil
    table.insert(blocks, math.min(top.idx, #blocks + 1), top.block)
    record_decision(state, "undo_decision", {
      hunk = top.idx,
      model_index = top.block.model_index,
      undone = top.action,
      row = start_line,
      to_undo_seq = top.pre_seq,
    })
    local snap = diff.buffer_bytes_snapshot(bufnr)
    if snap then
      state.staged_text = snap
      state.latest_undo_seq = buf_undo_seq(bufnr)
    end
    render_blocks(bufnr, state.diff_blocks, {
      site = "undo_decision",
      model = state.model_hunks,
      model_source = state.model_source,
      change = change,
      opts = state.opts,
    })
    -- R8: this review's own decision was taken back and repainted.
    M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "undo_decision")
    land_on(change.path, bufnr, top.block)
    return true
  end

  --- `u` inside an open review.
  ---
  --- It is NOT a remap of undo in any general sense: whenever the newest thing
  --- in this buffer's undo tree is the human's own edit, this hands straight to
  --- Neovim's undo. It diverges only when the newest thing is one of THIS
  --- review's decisions, and then it takes that decision back -- which for a
  --- reject is still Neovim restoring the bytes, and for an accept is bytes
  --- that never moved. Released the moment the review closes, after which `u`
  --- is the editor's own again and steps per hunk because the boundaries are
  --- there.
  local function undo_key()
    local top = state.decisions[#state.decisions]
    local cur = buf_undo_seq(bufnr)
    if top == nil or cur == nil or top.post_seq == nil or cur > top.post_seq then
      -- THE FLOOR. Below the state this review opened in lies the staging
      -- itself, and undoing into it strips the agent's proposal out of a buffer
      -- whose hunk list still claims to describe it -- the review would keep
      -- painting and offering decisions on lines that are gone. Measured before
      -- this guard existed: a third `u` after two decisions had been taken back
      -- left three hunks over the pre-turn file. Refuse by name; the file-level
      -- keys are the way out of a review, not undo.
      if cur ~= nil and state.undo_open_seq ~= nil and cur <= state.undo_open_seq then
        -- ROW 74 (issue log, orchestrator ruling 2026-08-21): this
        -- review's OWN decision stack is empty and its buffer has not
        -- moved since it opened (e.g. the queue just auto-advanced
        -- here) -- that is not the same fact as "nothing to undo
        -- anywhere". Ask the cross-file order index before refusing:
        -- `u` must answer from the WHOLE turn's history, never just the
        -- file under the cursor. This is a lookup only when THIS file's
        -- own stack is empty; every other branch of this function
        -- (popping a real decision) is unchanged.
        local retrace_ok, retrace = pcall(require, "yana.timeline.retrace")
        if retrace_ok and retrace.try_from_floor and retrace.try_from_floor() then
          return
        end
        -- RULING #100. The cross-file register is exhausted, so the only
        -- question left is whether this review has anything of its OWN below
        -- the floor that the press would destroy.
        --
        -- IT IS A MEASUREMENT, NOT A MARKER TEST. `undo_pre_stage_seq` names
        -- the buffer as it was before this review wrote its first byte into
        -- it; `undo_open_seq` names it as the operator was first shown it. A
        -- FRESH review staged the agent's proposal between those two, so they
        -- differ, and the next step down is yana's own staging edit being torn
        -- out from under a hunk list that still paints it -- refuse, exactly
        -- as before. A review RETRACE ITSELF REOPENED wrote nothing: the
        -- buffer already held the proposal (see `open_review_buffer`'s
        -- reintegration fast path, which returns the buffer AS-IS), so the two
        -- seqs are EQUAL and everything below the floor is the operator's own
        -- history, which `u` has always meant. Measured on the fixture in
        -- `r113_undo_past_register_floor` (fresh 1/2, reopened 2/2) and in
        -- `r113_r100_register_exhausted_is_silent` (fresh 2/3, reopened 3/3).
        --
        -- What this buys, and what it costs (operator informed, ruling 71):
        -- the reopened review CLOSES and its pending hunks go with it. They
        -- were never on disk. The alternative -- floor-green's choice (i),
        -- refusing by name -- is what #100 supersedes: it made `u`, a key
        -- shared with Neovim, print a line and move nothing, once per press,
        -- for the rest of the session.
        -- KI-1 amendment (2026-08-24): no review-open undo floor remains.
        -- Once the cross-file register is exhausted, crossing the proposal
        -- insertion with `u` MUST withdraw the whole review silently and then
        -- hand the press to plain Neovim undo.
        return M._withdraw_for_plain_undo(state, retrace_ok and retrace or nil)
      end
      return native_undo()
    end
    pop_decision()
  end

  --- `U` inside an open review: take back EVERY decision, back to the review
  --- as it opened. Stops at the first refusal and names it, rather than
  --- carrying on and leaving a half-unwound review nobody can reason about.
  ---
  --- `:undo {undo_open_seq}` at the end is Neovim putting the buffer back to
  --- the state it was in when the operator was first shown this review. After
  --- a clean unwind the buffer is already there and it changes nothing; after
  --- an operator edit mid-review it is what discards that edit, which is what
  --- "undo all" asks for and is still recoverable with `<C-r>`.
  ---
  --- Neovim's `U` is undo-line. Overriding it is a keymap the operator did not
  --- ask for anywhere else, so it is buffer-local to the review and released
  --- with it. Hardcoded rather than configurable: the ruling names the key and
  --- this lane adds no dial.
  local function undo_turn()
    local n = #state.decisions
    while #state.decisions > 0 do
      local popped = pop_decision()
      if popped ~= true then
        return
      end
    end
    if state.undo_open_seq ~= nil then
      -- SUPPRESSED (KI-1 ruling 2026-08-24): `U` is Yana's own transaction.
      local ok = pcall(M._rewind_suppress, function()
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("silent undo " .. tonumber(state.undo_open_seq))
        end)
      end)
      if not ok then
        undo_refuse("undo history no longer reaches the state this review opened in")
        return
      end
      local snap = diff.buffer_bytes_snapshot(bufnr)
      if snap then
        state.staged_text = snap
        state.latest_undo_seq = buf_undo_seq(bufnr)
      end
      render_blocks(bufnr, state.diff_blocks, {
        site = "undo_turn",
        model = state.model_hunks,
        model_source = state.model_source,
        change = change,
        opts = state.opts,
      })
    end
    -- Ruling 79 applies to the active file's turn reset too. Taking back an
    -- accept moves that hunk back to pending without a buffer edit, and the
    -- optional undo above may also leave Neovim's generic dirty bit behind.
    -- After `U`, the buffer-owned composition is the turn-start text; a stale
    -- `modified` flag would make the next `]x`/`[x` park+reopen refuse its own
    -- buffer as unrelated human work.
    M._recompute_modified(bufnr, state.diff_blocks, change.path)
    -- THE REST OF THE TURN. Ruling 48: `U` is the reset -- it undoes every
    -- edit in the ENTIRE BLOCK of inline hunks, not just this file's. The
    -- block above put the ACTIVE review back to the state it opened in; the
    -- sweep below does the same for every other file of the turn, including
    -- the two cases the ruling names by hand: a file already settled and
    -- CLOSED has no buffer to pop, so it is reopened; and a file already
    -- ACCEPTED is already on disk, so putting it back is a real-tree WRITE
    -- with no accept behind it -- permitted here, said out loud as it
    -- happens, and journaled like every other write.
    local restored, reverted, refused, removed = M._undo_rest_of_turn(state)
    record_decision(state, "undo_turn", {
      decisions_undone = n,
      to_undo_seq = state.undo_open_seq,
      hunks = #state.diff_blocks,
      files_undone = #restored + 1,
      files_written_back = #reverted,
      files_refused = #refused,
    })

    -- ONE message for the whole turn, naming how many files it covered.
    -- Silence would leave the operator guessing whether the other files were
    -- touched, which is the whole reason the ruling asks for this line.
    local names = { change.rel or change.path }
    for _, rel in ipairs(restored) do
      names[#names + 1] = rel
    end
    local summary = string.format(
      "yana: undid every edit in this turn -- %d file(s) back to the state you were first shown: %s",
      #names,
      table.concat(names, ", ")
    )
    log.write("WARN", summary)
    notify_one_line(summary, vim.log.levels.INFO)
    if #removed > 0 then
      -- RETENTION, SAID IN THE MESSAGE ITSELF (ruling 52). The staged copy
      -- lives in this turn's private evidence directory and nowhere else, so
      -- it dies with the turn's evidence. This is redo-scoped recovery, not an
      -- archive, and an operator who is told only "recoverable" will assume
      -- the wrong one.
      local rels = {}
      for _, entry in ipairs(removed) do
        rels[#rels + 1] = entry.rel
      end
      local mmsg = string.format(
        "yana: removed %d file(s) created this turn (recoverable): %s",
        #rels,
        table.concat(rels, ", ")
      )
      -- TWO LINES, and the second one is short ON PURPOSE. `notify_one_line`
      -- truncates to the panel width, so a retention clause appended to the
      -- line above is exactly the half that gets cut (the same lesson ruling
      -- 46's disclosure line learned). The operator has to be able to READ the
      -- retention, so it gets its own line that fits, and the long form goes
      -- durable.
      local retention = "yana: redo-scoped recovery, not an archive -- pruning the turn ends it"
      log.write(
        "WARN",
        mmsg .. " -- the copy lives in this turn's private evidence dir, so redo puts it back; "
          .. "once that evidence is pruned the bytes are gone. Redo-scoped recovery, not an archive."
      )
      notify_one_line(mmsg, vim.log.levels.WARN)
      notify_one_line(retention, vim.log.levels.WARN)
    end
    if #refused > 0 then
      local rmsg = string.format(
        "yana: %d file(s) could NOT be undone and are still as you left them: %s",
        #refused,
        table.concat(refused, "; ")
      )
      log.write("WARN", rmsg)
      notify_one_line(rmsg, vim.log.levels.WARN)
    end

    -- ...and the cursor goes back to the turn's FIRST pending hunk, which
    -- after a full unwind is the first hunk of the first file reviewed.
    M._focus_turn_first_hunk(state)
  end

  if not opts.preview then
    -- BufWriteCmd on the review buffer. A human :w must never be blocked
    -- (CORE), and it writes BUFFER-OWNED TEXT ONLY (ruling 72): every pending
    -- hunk is put back the way disk has it, so an added line does not reach
    -- disk and a line the hunk proposes to delete stays there. `:w!` is
    -- IDENTICAL to `:w` -- withholding is not a refusal, so `!` has nothing to
    -- force. `:w <other-path>` writes the same composition (ruling 78) and
    -- never touches the reviewed file. Product saves use `noautocmd write!`
    -- (diff.save_buffer) and bypass this handler entirely; keep it that way.
    --
    -- PENDING ONLY, which ruling 87 makes load-bearing rather than incidental:
    -- an ACCEPTED hunk's lines are the buffer's and a save must write them.
    -- The representation relied on is `state.diff_blocks` itself -- there is no
    -- per-block status field; `remove_block` (:913) drops a block from that
    -- list the moment it is accepted (:4576) or rejected (:4507) -- so
    -- iterating it is iterating exactly the undecided hunks.
    --
    -- THE WRITE MECHANISM, and why it is neither of the two obvious ones.
    -- `diff.save_buffer` writes the buffer VERBATIM (diff.lua:494-499) and so
    -- cannot write a composition at all. Swapping the buffer to the
    -- composition, writing, and swapping back feeds two whole-buffer edits
    -- through this review's own `nvim_buf_attach` watch -- which does NOT
    -- exclude the product's own edits (see attach_buffer_watch) -- and
    -- `absorb_human_edits` reads their accumulated `last_new - last_orig` as
    -- the human widening every hunk. So the composition is written straight to
    -- disk through `diff.write_file`, the same atomic temp/fsync/rename
    -- primitive the diary accepts through (`diff.diary_atomic_write`): the
    -- buffer is never touched, so the watch sees nothing, mode and ownership
    -- are preserved, and a crash mid-write leaves the original file whole
    -- rather than half-written.
    --
    -- The two things Vim would otherwise have done for us:
    --   * E13 noclobber on `:w <existing-other-path>` -- Vim's own
    --     `check_overwrite` runs in `do_write` BEFORE BufWriteCmd is applied,
    --     so E13 is raised and this callback never runs (measured).
    --   * clearing 'modified' -- done explicitly below, per ruling 79: the
    --     flag follows the BUFFER's half, and after this write the buffer's
    --     half is durable.
    -- What is NOT recovered by construction: Neovim's recorded file info for
    -- this buffer, because the bytes did not travel through `buf_write`.
    -- Neovim exposes no way to re-stamp it that does not RELOAD the buffer,
    -- and a reload would replace the review composition. What that costs was
    -- MEASURED rather than reasoned about:
    --   * while the review is open, W12 cannot arm: BufWriteCmd short-circuits
    --     `buf_write` ahead of its `check_mtime`, measured with a deliberately
    --     stale mtime and a modified buffer.
    --   * a `:checktime` in between lands on the FileChangedShellPost
    --     handler's tier-1 branch, which is exactly why `disk_at_open`
    --     advances to the bytes written and `state.staged_text` stays the
    --     BUFFER snapshot below.
    --   * after the review closes: driven end to end -- review open (buffer
    --     created fresh, and buffer pre-`:edit`ed), a save that really changed
    --     disk bytes, a full reject (which writes nothing), then a human edit
    --     and `:w` -- the write succeeded silently with the right bytes and no
    --     W12, in every flow tried, with the file's mtime more than a second
    --     newer than the read. The same `diff.write_file` DOES arm W12 on a
    --     plain buffer with no review, so the check is live; a review's own
    --     lifecycle keeps re-stamping it.
    -- A save whose composition already equals the bytes on disk writes nothing
    -- at all, so the common case -- pending hunks, no human edit -- never
    -- restamps the file and never goes stale in the first place.
    -- ONE registration for every write path Neovim offers from this buffer
    -- (ruling 72/87, "saving a copy to another path" keeps hunk ownership
    -- scoped to the requested range): BufWriteCmd (bare `:w`, `:w newname`, `:wq`, `:update`,
    -- and -- because Vim renames the buffer to the new name BEFORE firing
    -- this event -- `:saveas newname` too), FileWriteCmd (`:{range}w file`,
    -- a write that is not the whole buffer), and FileAppendCmd (`:w >>file`).
    -- One callback, branching only on what each event's own semantics
    -- require (the write's line range, and whether it appends) -- there is
    -- no per-command special case beyond this one `nvim_create_autocmd` call
    -- naming the three events.
    vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd", "FileAppendCmd" }, {
      buffer = bufnr,
      group = state.augroup,
      callback = function(ev)
       log.guard("yana.inline_diff " .. ev.event, function()
        -- <amatch> is the write's actual target (the argument to `:w`, or
        -- the buffer's own name for a bare `:w`). "Own" is the REVIEW's
        -- identity, `change.path` -- not the buffer's live name -- so that
        -- `:saveas newname` (which renames the buffer to `newname` before
        -- this fires) is correctly read as writing somewhere OTHER than the
        -- file this review is anchored on, and falls through to the same
        -- withheld-copy handling as `:w <other-path>` (ruling 78) rather
        -- than silently overwriting the stale original path.
        local target = vim.fn.expand("<amatch>")
        local own = diff.abs_path(change.path)
        if target ~= "" then
          target = diff.abs_path(target)
        end
        local to_own = (target == "" or target == own)

        -- FileWriteCmd/FileAppendCmd set the '[ / '] marks to the exact line
        -- range being written (measured against real nvim; BufWriteCmd sets
        -- them to the whole buffer, so reading them unconditionally needs no
        -- per-event branch). Clip to the buffer's current extent defensively.
        local total = vim.api.nvim_buf_line_count(bufnr)
        local q1 = math.max(1, vim.fn.line("'["))
        local q2 = math.min(total, math.max(q1, vim.fn.line("']")))
        local is_full_range = (q1 <= 1 and q2 >= total)
        local is_append = (ev.event == "FileAppendCmd")

        -- Binary is already safe: buffer_bytes_snapshot refuses a binary
        -- buffer or one holding NUL bytes (diff.lua:563-570), and this bails
        -- with the named reason rather than composing bytes it cannot encode.
        -- The snapshot is also what `state.staged_text` is set from below.
        local snap, snap_err = diff.buffer_bytes_snapshot(bufnr)
        if snap == nil then
          notify_one_line(
            "yana: could not save " .. (change.rel or change.path) .. ": " .. tostring(snap_err),
            vim.log.levels.ERROR
          )
          return
        end

        local composed, withheld, skip_reason, skipped =
          M._compose_buffer_owned_lines(bufnr, state.diff_blocks, { q1, q2 })
        if skip_reason then
          -- One screen line, aggregated: several separate notifies would wedge
          -- a `--clean` editor on the hit-enter prompt (issue-log row 81).
          local skip_msg = string.format(
            "yana: save left %d hunk(s) in the file -- %s",
            skipped,
            tostring(skip_reason)
          )
          notify_one_line(skip_msg, vim.log.levels.WARN)
          if to_own and is_full_range and not is_append then
            notify_one_line("yana: not written — pending hunks could not be mapped safely", vim.log.levels.WARN)
            return
          end
        end
        local bytes = M._encode_buffer_lines(bufnr, composed)
        local withheld_msg =
          string.format("yana: wrote buffer-owned lines only — %d hunks withheld", withheld)
        local authority_lost = 0
        for _, b in ipairs(state.diff_blocks or {}) do
          if b.authority_lost then
            authority_lost = authority_lost + 1
          end
        end

        -- Only a FULL-BUFFER write of the review's OWN identity, that does
        -- not append, is "the ordinary save" the bookkeeping below is about.
        -- Everything else -- a different target (`:w <other-path>`, ruling
        -- 78; `:saveas`, above), a partial range even to the reviewed file's
        -- own name (Vim's own E140 already marks that as unusual), or an
        -- append to anywhere -- withholds and writes the composed slice
        -- verbatim and never touches `change.*`: none of them is a claim
        -- that the review's anchor file now equals the buffer.
        if not (to_own and is_full_range and not is_append) then
          -- The target directory must already exist. `diff.write_file` would
          -- `mkdir -p` it, and this is the one branch whose path is arbitrary
          -- text the human just typed: a mistyped `:w /tpm/x` must refuse the
          -- way Vim refuses it, not silently create `/tpm`.
          local dir = vim.fn.fnamemodify(target, ":h")
          if target == "" or dir == "" or vim.fn.isdirectory(dir) ~= 1 then
            notify_one_line(
              "yana: could not write to " .. target .. ": no such directory " .. tostring(dir),
              vim.log.levels.WARN
            )
            return
          end
          local out_bytes = bytes
          if is_append then
            -- Vim's own `:w >>file` refuses (E212) when `file` does not
            -- already exist rather than creating it; once this event is
            -- registered Vim's default handling never runs, so that refusal
            -- has to be reproduced here.
            local existing = diff.read_file_bytes(target)
            if existing == nil then
              notify_one_line(
                "yana: could not append to " .. target .. ": no such file or directory",
                vim.log.levels.WARN
              )
              return
            end
            out_bytes = existing .. out_bytes
          end
          local ok, err = diff.write_file(target, out_bytes)
          if not ok then
            notify_one_line(
              "yana: could not write to " .. target .. ": " .. tostring(err),
              vim.log.levels.WARN
            )
            return
          end
          -- A count of zero is not a withholding notice: nothing was
          -- withheld, so saying so would be noise that a row asserting the
          -- notice fires only when it should would (correctly) red on.
          if withheld > 0 then
            notify_one_line(withheld_msg, vim.log.levels.WARN)
          end
          return
        end
        if authority_lost > 0 then
          notify_one_line(
            string.format(
              "yana: not written — %d pending hunk(s) no longer match the buffer",
              authority_lost
            ),
            vim.log.levels.WARN
          )
          return
        end

        -- KIND GUARD. An agent-CREATED file is reviewed against an empty base,
        -- so its composition is the empty file — and ruling 81 forbids that
        -- path to exist at all until the creation is accepted. The reason is
        -- the ruling, NOT an absence of buffer-owned text: a human line typed
        -- on the row after the hunk's last row is not absorbed
        -- (absorb_human_edits) and is theirs, and this still writes nothing.
        -- 'modified' stays set, which is the honest signal that those bytes
        -- are not on disk.
        -- `change.before == nil` is tested alongside the flag because it is
        -- the DEFINITION of an agent-created file (open_review_buffer reads it
        -- that way), while the flag is set on only one of the routes into a
        -- review -- the retrace-reintegration fast path returns before it.
        if change.disk_absent_at_open or change.before == nil then
          notify_one_line(
            "yana: not written — file exists only in the review until accept",
            vim.log.levels.WARN
          )
          return
        end
        -- A delete-kind review carries `after == nil`, so its whole staged
        -- buffer is ONE pending deletion hunk and there is no buffer-owned
        -- text in it at all; the deletion itself is a non-buffer change
        -- (ruling 81) that only accept may apply. Writing nothing keeps the
        -- file exactly as disk has it — and, unlike composing, cannot truncate
        -- it if that single hunk's extmark is invalidated.
        if change.kind == "delete" or change.after == nil then
          notify_one_line(
            "yana: not written — the file stays until you decide the pending deletion",
            vim.log.levels.WARN
          )
          return
        end

        -- Writing bytes disk already holds would restamp the file for nothing:
        -- it bumps mtime under every external watcher and hands this buffer's
        -- recorded file info a staleness it did not have to have.
        local disk_before = diff.read_file_bytes(change.path)
        if disk_before ~= bytes then
          local ok, err = diff.write_file(change.path, bytes)
          if not ok then
            notify_one_line(
              "yana: could not save " .. (change.rel or change.path) .. ": " .. tostring(err),
              vim.log.levels.ERROR
            )
            return
          end
        end

        -- ANCHORS ADVANCE ONLY AFTER A SUCCESSFUL WRITE, and against bytes
        -- read back from disk rather than the string handed to the writer —
        -- an anchor may only ever claim bytes that are provably there. The
        -- reverse order is silently wrong: `disk_at_open` naming bytes that
        -- are not on disk sends a later reload into tier-2 composition against
        -- a base that never existed.
        local on_disk, read_err = diff.read_file_bytes(change.path)
        if on_disk == nil then
          notify_one_line(
            "yana: saved " .. (change.rel or change.path) .. " but could not re-read it: " .. tostring(read_err),
            vim.log.levels.WARN
          )
          return
        end
        change.disk_at_open = on_disk
        -- THE ACCEPT-TIME CAS. `shadow/apply.lua:824-829` hands `base_hash` to
        -- the diary and `safety/diary.lua`'s `state_matches` compares hash AND
        -- state AND mode one syscall before the rename. Advancing only
        -- `disk_at_open` is what the reload path's own comment records as
        -- having "left every tier-2 accept refused as human drift"; here it
        -- would brick the review after the first save.
        local rehash = base_fingerprint(on_disk)
        if rehash then
          change.base_hash = rehash
          change.base_state = "file"
          local st_now = (vim.uv or vim.loop).fs_lstat(change.path)
          if st_now and st_now.mode then
            change.base_mode = st_now.mode
          end
        end
        -- `change.before` moves WITH the fingerprint, and must: they are read
        -- as a pair. `shadow/apply.lua`'s `scope_revert` writes `change.before`
        -- under a `change.base_hash` CAS, and `revert_to_turn_start` writes it
        -- outright — leaving `before` at turn-start while `base_hash` names
        -- the saved file gives both a licence to write a pre-save snapshot
        -- over bytes the human has already durably saved. That is the exact
        -- shape of this file's worst measured defect (pre-ce50120 reject) and
        -- the reason the reload path advances `before` too (:4045-4050).
        change.before = on_disk
        -- THE BUFFER SNAPSHOT, never the bytes written. The reload handler's
        -- tier 1 restores `staged_text` into the buffer; the composition there
        -- would overwrite the review with its own hunk-less text and destroy
        -- every pending hunk on screen, silently. It would also permanently
        -- falsify `staged_snapshot_unchanged`, so every delete-accept would
        -- refuse "buffer holds edits that accepting this deletion would
        -- discard".
        state.staged_text = snap
        state.latest_undo_seq = buf_undo_seq(bufnr)
        -- Ruling 79: the flag follows the BUFFER's half, and the buffer's half
        -- is now on disk. Pending hunks never move it in either direction.
        vim.bo[bufnr].modified = false
        do
          local obs = tl_observe(bufnr)
          obs.regime = "buffer"
          tl_record(state, "save_marker", "save marker " .. (change.rel or change.path or "?"), obs)
          state.timeline_obs = obs
        end
        if withheld > 0 then
          notify_one_line(withheld_msg, vim.log.levels.INFO)
        end
        return
      end)
      end,
    })
  end

  --- `redo_of` (ruling 75, one register): mirrors `accept_all`'s own -- the
  --- id of the register row this decision puts back. Only meaningful on the
  --- fresh whole-file branch below (`#state.decisions == 0`); the
  --- with-prior-decisions sweep is always a fresh series of per-hunk `co`
  --- steps and has no file-level row of its own to redo.
  local function reject_all(redo_of)
    tl_capture_human_edit(state)
    record_decision(state, "reject_file", { hunks_remaining = #state.diff_blocks })
    -- A hunk already decided is a RECORDED decision and stands. This record
    -- has only ever claimed the REMAINING hunks (hunks_remaining), so the old
    -- whole-file restore contradicted the ledger row it had just written: an
    -- accepted hunk's accept_hunk record survived while its bytes vanished.
    -- With prior decisions, reject the remaining hunks through the same path
    -- `co` takes, letting try_finalize compose base + exactly the accepted
    -- hunks; a hunk that refuses (human edit inside it) keeps the review open,
    -- identical to the single-hunk contract. Only a review with NO decisions
    -- yet takes the whole-file restore -- the "reject-all writes nothing"
    -- contract (P2), which per-hunk rejection could not honour because
    -- try_finalize would write base bytes over an untouched file.
    if #state.decisions > 0 then
      -- Skip-and-continue on a refused hunk (human edit inseparable from the
      -- agent's), exactly like the whole-file path: the refused hunk stays
      -- pending and the review stays open for it, while every other remaining
      -- hunk is still swept. Terminates because each pass either shrinks the
      -- block list or advances past a refusal.
      local i = 1
      local all_rejected = true
      while i <= #state.diff_blocks do
        local before = #state.diff_blocks
        reject_block_at(i)
        if #state.diff_blocks >= before then
          all_rejected = false
          i = i + 1
        end
      end
      return all_rejected
    end
    -- ONE FILE-LEVEL DECISION, ONE REGISTER ROW (ruling 75): `finish_session`'s
    -- bulk-reject branch below reads this flag to seal the WHOLE restoration
    -- into one undo-tree entry and record exactly one `file_rejected` row,
    -- rather than one `hunk_rejected` row (and one undo block) per hunk.
    state.timeline_bulk_reject = true
    state.timeline_bulk_redo_of = redo_of
    local ok = finish_session(state, false)
    state.timeline_bulk_reject = nil
    state.timeline_bulk_redo_of = nil
    return ok
  end

  -- cA: accept every pending change for the whole turn — the active review
  -- plus everything still queued behind it. Drain the queue FIRST so that
  -- finish_session's process_next (called once the active review resolves)
  -- finds an empty queue and does not try to open a review we just settled.
  -- The active file needs no buffer guard here: finish_session saves the live
  -- buffer, so whatever the human typed is what gets written. The QUEUED files
  -- are the exposure -- they are written from the stored change.after, per
  -- file, and a human edit sitting in file 4's buffer would be overwritten
  -- silently while the active file accepted cleanly.
  local function accept_everything()
    local st = pool_for(state.opts or {})
    local drained = st.queue
    local shadow_apply = require("yana.shadow.apply")
    local active_refusal = shadow_apply.single_file_accept_refusal(state.change, state.bufnr)
    if active_refusal then
      M._record_shadow_accept_refusal(state, active_refusal)
      return false
    end
    record_decision(state, "accept_turn", {
      hunks_remaining = #state.diff_blocks,
      queued_files = #drained,
    })
    st.queue = {}
    local skipped = {}
    local clashed = {}
    local to_requeue = {}

    -- A queued file has no staged review yet, so it has no staged_text to
    -- compare against; the equivalent question is whether its buffer holds
    -- unsaved human text. If it does, this accept would overwrite it.
    local function buffer_clash(path)
      local b = vim.fn.bufnr(path, false)
      return b > 0 and vim.api.nvim_buf_is_loaded(b) and vim.bo[b].modified
    end

    -- A PARKED change is the exception to that question, and the whole of
    -- ruling 47 (issue log row 47). Parking is a NAVIGATION event, never a
    -- decision (ruling 7), so a parked change is still PENDING and accept-all
    -- must cover it. Its buffer is `modified` because THIS ENGINE staged the
    -- agent's proposal into it and `]x` left it there -- reading that as
    -- "changed outside the inline engine" made accept-all silently skip the
    -- one change an operator is most likely to ask it about (the live E2E's
    -- "a hunk still pending after accept-all").
    --
    -- The composition is the parked review's OWN bytes, not `change.after`:
    -- a hunk the operator rejected before parking is already back to base in
    -- them, so accepting the parked file covers what was still pending and
    -- reverts nothing that was decided. Accept-all is not a reset (that is
    -- `U`, row 48).
    --
    -- The buffer is still compared against what the park recorded, so a HUMAN
    -- edit made after the park is a clash exactly as before.
    local function parked_composition(change_i)
      local parked = change_i and change_i._parked_review
      if not parked then
        return nil, nil, nil
      end
      local staged = parked.staged_text
      local b = vim.fn.bufnr(change_i.path, false)
      if b > 0 and vim.api.nvim_buf_is_loaded(b) then
        local live = diff.buffer_bytes_snapshot(b)
        if live ~= nil then
          if staged ~= nil and not diff.text_equal_snapshot(live, staged) then
            return nil, "the parked review buffer was edited after it was parked"
          end
          return live, nil, b
        end
      end
      if staged == nil then
        return nil, "the parked review kept no staged content to accept"
      end
      return staged, nil, nil
    end

    local parked_covered = 0
    for _, item in ipairs(drained) do
      if item.change and item.change._parked_review then
        parked_covered = parked_covered + 1
      end
    end

    -- DISCLOSE BEFORE APPLY. accept_everything applies the active review AND
    -- drains the whole queued turn onto the real tree. Historically it reported
    -- only the skipped/clashed paths AFTER the loop, so an operator hitting
    -- accept-all committed a change set they were never shown -- the honesty
    -- defect behind the 2026-08-16 incident, where a bulk-accept silently
    -- included .git writes. Emit the full set this call is ABOUT TO WRITE here,
    -- before the loop below performs the first real-tree write, so disclosure
    -- always precedes mutation. This ordering is the whole point and must not
    -- move below the apply loop. The record is DURABLE via log.write("WARN")
    -- (INFO never reaches disk, per log.lua), with a transient one-line panel
    -- note for the on-screen half. The set is the active change plus every
    -- drained queued change -- exactly what the loop and finish_session then
    -- attempt to apply, so the disclosed count/paths match the work.
    --
    -- AND THE MODE WITH THE PATH. Paths and a count alone were measured to be
    -- an incomplete disclosure that READS as complete: on one turn with three
    -- replaced 0755 scripts, bulk accept announced "3 change(s)", named one
    -- mode transition -- incidentally, because that file happened to be the
    -- active review and its banner was drawn at review open -- and moved all
    -- three to 0664. A queued change never opens a review, so no banner is
    -- ever drawn for it and nothing else named it. Since the mode ruling
    -- deliberately removed inference (the product cannot tell a deliberate
    -- chmod from a umask artifact left by an agent that replaced the file),
    -- disclosure is the whole protection here with nothing behind it, on the
    -- exact path the 2026-08-16 incident ran through.
    --
    -- COMPLETENESS IS NOT YET LEGIBILITY, and that is deliberate. A list of 36
    -- paths each carrying a mode note is not something a human can act on --
    -- the same problem `the accepted build design` 2c already names for the
    -- partition, and it is to be settled THERE, with the bulk-disclosure
    -- partition work, not invented here. A complete unreadable list beats an
    -- incomplete one that reads as complete.
    local function disclose_label(change_i)
      if not change_i then
        return "?"
      end
      local label = change_i.rel or change_i.path or "?"
      local before = tonumber(change_i.base_mode)
      local after = tonumber(change_i.after_mode)
      if before and after and (before % 4096) ~= (after % 4096) then
        label = string.format("%s (mode %o → %o)", label, before % 4096, after % 4096)
      end
      return label
    end
    local disclose_paths = {}
    if state.change then
      disclose_paths[#disclose_paths + 1] = disclose_label(state.change)
    end
    for _, item in ipairs(drained) do
      disclose_paths[#disclose_paths + 1] = disclose_label(item.change)
    end
    local disclose_msg = string.format(
      "yana: accept-all about to apply %d change(s) to the real tree: %s",
      #disclose_paths,
      table.concat(disclose_paths, ", ")
    )

    log.write("WARN", disclose_msg)
    notify_one_line(disclose_msg, vim.log.levels.INFO)

    -- Ruling 47: the panel names what accept-all covered, INCLUDING how many
    -- of those changes were parked. Its OWN line rather than a clause appended
    -- to the disclosure: `notify_one_line` truncates to the panel width, and
    -- measured on the two-file case the appended clause was the half that got
    -- cut -- a disclosure that names the parked coverage only when the path
    -- list happens to be short is not a disclosure. Durable too, since INFO
    -- never reaches disk (log.lua) and this is the half a live run is read
    -- back for.
    if parked_covered > 0 then
      local parked_msg = string.format(
        "yana: accept-all covers %d parked change(s) -- parking is navigation, not a decision",
        parked_covered
      )
      log.write("WARN", parked_msg)
      notify_one_line(parked_msg, vim.log.levels.INFO)
    end

    for _, item in ipairs(drained) do
      local change_i = item.change
      local path = diff.abs_path(change_i.path)
      change_i.path = path
      local ok, err
      -- What a PARKED change contributes: its own staged bytes, and the
      -- reason it cannot be used if the human moved them after the park.
      local parked_text, parked_err, parked_bufnr = parked_composition(change_i)
      -- Control-plane fail-safe before any accept write, covering
      -- BOTH the shadow_apply route and the legacy direct write/delete below.
      -- Classify the lexical path so a `.git` name is not resolved away.
      if control_plane.is_control_plane(diff.abs_path_literal(change_i.path)) then
        change_i.review_error = "refused — control-plane path (never written): " .. change_i.path
        table.insert(skipped, change_i.rel or path)
        table.insert(to_requeue, item)
        goto continue
      end
      if parked_err then
        change_i.review_error = parked_err
        table.insert(clashed, change_i.rel or path)
        table.insert(to_requeue, item)
        goto continue
      end
      -- `parked_text` IS the parked review's own staging, already compared
      -- against what the park recorded, so the modified flag says nothing
      -- more here.
      if parked_text == nil and buffer_clash(path) then
        change_i.review_error = "review buffer changed outside the inline engine"
        table.insert(clashed, change_i.rel or path)
        table.insert(to_requeue, item)
        goto continue
      end

      -- SOLE-WRITER CONTRACT. Under shadow mode the journaled applier is the
      -- only thing allowed to change the real tree (CORE: "The journaled
      -- applier is the sole real-tree writer"). This loop used to call
      -- diff.write_file / diff.delete_file directly for every queued item
      -- regardless of mode, so `cA` wrote the real tree outside the diary
      -- entirely: no intent row, no displaced copy, no verification, and
      -- nothing for crash recovery or revert_turn to work from. The active
      -- file was fine — finish_session routes it correctly — which is exactly
      -- why this stayed invisible.
      --
      -- A queued change has no review buffer of its own, and buffer_clash
      -- above has already refused any that holds unsaved human text, so the
      -- agent's `after` IS the composed content here. Freshness is not
      -- re-checked in this branch because the diary revalidates base_hash
      -- immediately before it acts, which is the authoritative check.
      if item.opts and item.opts.shadow_apply then
        if not item.opts.on_shadow_accept then
          change_i.review_error = "shadow accept handler missing for a queued change"
          table.insert(skipped, change_i.rel or path)
          table.insert(to_requeue, item)
          goto continue
        end
        local composed_i = nil
        if change_i.kind ~= "delete" then
          if change_i.after == nil and parked_text == nil then
            change_i.review_error = change_i.review_error or "queued change has no after content"
            table.insert(skipped, change_i.rel or path)
            table.insert(to_requeue, item)
            goto continue
          end
          composed_i = parked_text or change_i.after
        end
        local allowed, why = review_action_allowed({ opts = item.opts }, change_i)
        if not allowed then
          change_i.review_error = tostring(why)
          table.insert(skipped, change_i.rel or path)
          table.insert(to_requeue, item)
          goto continue
        end
        local accept_opts = parked_bufnr and { staged_bufnr = parked_bufnr } or nil
        local aok, aerr, applied_i = item.opts.on_shadow_accept(change_i, composed_i, accept_opts)
        if aok == true then
          change_i.status = "accepted"
          if type(applied_i) == "table" and applied_i.kind == "transfer" then
            vim.bo[applied_i.bufnr].modified = true
            change_i._accept_regime = "transfer"
            change_i._accept_bufnr = applied_i.bufnr
            change_i._accept_composed_hash = applied_i.composed_hash
            ledger.mark(change_ledger(change_i, item.opts), "accept_transferred")
          else
            change_i._accept_regime = "durable"
            ledger.mark(change_ledger(change_i, item.opts), "accept_applied")
          end
          -- The park is over: nothing may reopen this review from the parked
          -- staging once its bytes are on disk.
          change_i._parked_review = nil
          change_i._parked_item = nil
          -- CLEAR PAINTED BANDS. The active review's own buffer gets its
          -- incoming/authority/hint namespaces cleared once, below, after
          -- this whole loop (on `bufnr`/`state.bufnr`) -- but this accept is
          -- for a change that was never `state`, so that clear never
          -- touches its buffer. A parked review keeps its pending hunks
          -- painted on purpose while parked (ROW 112, `park_and_open_state`'s
          -- `retrace_repaint`), and nothing else is responsible for taking
          -- that paint back off when accept-everything (not a park+reopen)
          -- is what resolves it. Measured: after a redo walk across several
          -- files left one file active and a second merely parked with its
          -- own still-pending hunk, `cA` correctly zeroed every pending
          -- count but left the parked file's green bands on screen, still
          -- describing hunks that had just been accepted
          -- (r75_four_file_walk_mirror's `[cA] ... no bands left`). Any
          -- buffer this change happens to have loaded (parked, or merely
          -- opened earlier in the turn) gets the same three-namespace clear
          -- the active file's own accept already does.
          local band_bufnr = parked_bufnr or vim.fn.bufnr(path, false)
          if band_bufnr and band_bufnr > 0 and vim.api.nvim_buf_is_valid(band_bufnr) then
            vim.api.nvim_buf_clear_namespace(band_bufnr, NS, 0, -1)
            vim.api.nvim_buf_clear_namespace(band_bufnr, AUTH_NS, 0, -1)
            vim.api.nvim_buf_clear_namespace(band_bufnr, HINT_NS, 0, -1)
          end
          notify_owner(item.opts.on_accept, change_i, "on_accept")
          -- No `diff.reload_file(path)` here any more. shadow/apply.lua now
          -- reconciles this buffer itself, against the stat its own write left
          -- behind. The old call ran a BARE `checktime`, which sweeps EVERY
          -- loaded buffer and so could raise the blocking dialog for some
          -- unrelated stale one, and it re-read the file with no proof that
          -- disk still held the applier's result.
          if applied_i and applied_i.reconcile_error then
            notify_one_line(
              "yana: applied " .. (change_i.rel or path) .. " but could not reconcile its buffer: "
                .. tostring(applied_i.reconcile_error),
              vim.log.levels.WARN
            )
          end
          -- OPERATOR RULING ROW 72(b), 2026-08-21: "undo should cover
          -- [a file not open in Neovim] if not too complex to code."
          -- This change NEVER had a review buffer (`M.open` never ran for
          -- it), so `finish_session`'s own `tl_record(state, "applied",
          -- ...)` -- the ONLY other place a durable row gets recorded --
          -- never runs for it either, and nothing in the timeline ever
          -- named this write. Record it here, the same way, so the
          -- EXISTING `diary.revert_operation` walk step (already the
          -- durable half of `walk_impl.lua`, already exercised by every
          -- in-review accept) can find and reverse it later. A missing
          -- `diary_dir`/`op_id` (a handler that did not go through the
          -- journal) is a named, logged gap, never a silent one -- the
          -- warning below is exactly ruling 72(b)'s "print a warning
          -- naming the file" floor.
          if type(applied_i) == "table" and applied_i.diary_dir and applied_i.op_id then
            tl_record(
              { change = change_i, opts = item.opts },
              "applied",
              "applied " .. (change_i.rel or path),
              { regime = "durable", diary_dir = applied_i.diary_dir, op_id = applied_i.op_id }
            )
          elseif not (type(applied_i) == "table" and applied_i.kind == "transfer") then
            local warn = "yana: "
              .. (change_i.rel or path)
              .. " was accepted without ever being opened, but no journaled op id came back -- "
              .. "undo will not be able to reach it; the write itself still happened"
            log.write("WARN", warn)
            notify_one_line(warn, vim.log.levels.WARN)
          end
        else
          change_i.review_error = tostring(aerr or "shadow accept failed")
          local qlog = change_ledger(state.change, state.opts)
          ledger.record_decision(qlog, {
            action = "review_refused",
            actor = "system",
            reason = "shadow_accept_failed",
            detail = tostring(aerr),
            change_id = change_i.id,
            rel = change_i.rel or path,
          })
          local detail = change_i.shadow_refusal
          if type(detail) == "table" and type(detail.actual_fp) == "string" then
            local origin, drift_reason = attribute_drift(change_i, detail.reason or "stale_file", detail.actual_fp)
            detail = vim.tbl_extend("force", {}, detail)
            if origin then
              detail.origin = origin
            end
            if drift_reason then
              detail.reason = drift_reason
            end
          end
          ledger.attach_refusal(qlog, detail)
          table.insert(skipped, change_i.rel or path)
          table.insert(to_requeue, item)
        end
        goto continue
      end

      change_i.review_error = "queued accept reached the removed legacy path — shadow_apply required"
      table.insert(skipped, change_i.rel or path)
      table.insert(to_requeue, item)
      ::continue::
    end
    if #clashed > 0 then
      notify_one_line(
        "yana: refused " .. #clashed .. " change(s) — review buffer changed outside the inline engine: "
          .. table.concat(clashed, ", "),
        vim.log.levels.WARN
      )
    end
    if #skipped > 0 then
      notify_one_line(
        "yana: skipped " .. #skipped .. " stale queued change(s), left on disk unchanged: "
          .. table.concat(skipped, ", "),
        vim.log.levels.WARN
      )
    end
    state.diff_blocks = {}
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, AUTH_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, HINT_NS, 0, -1)
    state._skip_queue_advance = true
    finish_session(state, true)
    state._skip_queue_advance = nil
    for _, item in ipairs(to_requeue) do
      table.insert(st.queue, item)
    end
    if #to_requeue > 0 then
      process_next_for(state.opts)
    end
  end

  ledger.mark(change_ledger(change, opts), "review_profile_actions_ready")

  -- The review's own decision primitives, reachable from
  -- `yana.timeline.retrace.redo` so a reintegrated undo's accept/reject can be
  -- put back through the SAME code path the keys use (ruling 75, one
  -- register). Per-state, never global: the retrace module finds the review
  -- by (workspace, rel) and calls these on it.
  state._ops = {
    accept_block_at = accept_block_at,
    reject_block_at = reject_block_at,
    -- RULING 75: the file-level twins, each taking the same `redo_of` a
    -- reintegrated file-level row's redo needs (`retrace.redo_file_decision`).
    accept_all = accept_all,
    reject_all = reject_all,
    redo_local = redo_local,
  }

  M._test = {
    -- Re-exposed here because this assignment REPLACES the table (see FAULT).
    fault = FAULT,
    state = state,
    bufnr = bufnr,
    fcs_post_count = function()
      return state.fcs_post_count or 0
    end,
    extmark_count = function()
      return #vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
    end,
    current_block = function()
      return current_block(state.diff_blocks, bufnr)
    end,
    accept_hunk = accept_hunk,
    reject_hunk = reject_hunk,
    accept_block_at = accept_block_at,
    reject_block_at = reject_block_at,
    reject_all = reject_all,
    accept_all = accept_all,
    undo_turn = undo_turn,
    undo_key = undo_key,
    decisions = function()
      return state.decisions
    end,
    undo_open_seq = function()
      return state.undo_open_seq
    end,
    accept_everything = accept_everything,
    prompt_close_owned_tabs = M.prompt_close_owned_tabs,
    review_tabs_state_path = M.review_tabs_state_path,
  }

  local km = { buffer = bufnr, nowait = true, silent = true }
  ledger.mark(change_ledger(change, opts), "review_profile_test_seam_ready")
  -- Wrap only at the keymap.set call, not the underlying functions: those
  -- (reject_hunk, accept_hunk, ...) are also exposed unwrapped via M._test
  -- above, and must keep returning their real values there.
  local function guarded(ctx, fn)
    return function(...)
      log.guard(ctx, fn, ...)
    end
  end
  if not opts.preview then
    vim.keymap.set({ "n", "v" }, maps.ours or "cr", guarded("yana.inline_diff reject_hunk", reject_hunk), vim.tbl_extend("force", km, { desc = "yana: reject hunk (ours)" }))
    vim.keymap.set({ "n", "v" }, maps.theirs or "ca", guarded("yana.inline_diff accept_hunk", accept_hunk), vim.tbl_extend("force", km, { desc = "yana: accept hunk (theirs)" }))
    vim.keymap.set({ "n", "v" }, maps.all_theirs or "cf", guarded("yana.inline_diff accept_all", accept_all), vim.tbl_extend("force", km, { desc = "yana: accept all hunks" }))
    vim.keymap.set({ "n", "v" }, maps.all_changes or "cA", guarded("yana.inline_diff accept_everything", accept_everything), vim.tbl_extend("force", km, { desc = "yana: accept ALL changes (whole turn)" }))
    vim.keymap.set({ "n", "v" }, maps.reject_file or "cx", guarded("yana.inline_diff reject_all", reject_all), vim.tbl_extend("force", km, { desc = "yana: reject file" }))
    -- cR: whole-review abort. SAME code path as `:YanaAbortReview` -- both
    -- call M.abort_active, which shows the consequence dialog before
    -- touching anything (operator ruling 2026-08-25). Hardcoded, not a
    -- `maps.xxx` dial (see the `keys` table above); not wrapped by
    -- `guarded()` above either: M.abort_active needs `opts` (this review's
    -- pool), which none of the zero-argument decision primitives above carry.
    vim.keymap.set({ "n", "v" }, "cR", function()
      log.guard("yana.inline_diff abort_active", function()
        M.abort_active(opts)
      end)
    end, vim.tbl_extend("force", km, { desc = "yana: abort the whole review (undo everything, confirmed first)" }))
    -- `u` and `U`, buffer-local and only while this review is open. `u` hands
    -- to Neovim's own undo whenever the newest thing in the tree is the
    -- human's edit, and takes a decision back only when the newest thing is
    -- one of this review's own. Both are released by M.cleanup with the rest
    -- of state.keys, after which the buffer has the editor's `u` and `U` back.
    vim.keymap.set({ "n", "v" }, "u", guarded("yana.inline_diff undo_key", undo_key), vim.tbl_extend("force", km, { desc = "yana: undo (human edit, else take back the last hunk decision)" }))
    vim.keymap.set({ "n", "v" }, "U", guarded("yana.inline_diff undo_turn", undo_turn), vim.tbl_extend("force", km, { desc = "yana: take back every hunk decision in this review" }))
    vim.keymap.set({ "n", "v" }, "<C-r>", guarded("yana.inline_diff redo_key", redo_key), vim.tbl_extend("force", km, { desc = "yana: redo (repaints the review afterwards)" }))
    vim.keymap.set({ "n", "v" }, maps.next or "]x", function()
      log.guard("yana.inline_diff next hunk", function()
        M._navigate_or_park_state(state, "next")
      end)
    end, vim.tbl_extend("force", km, { desc = "yana: next hunk" }))
    vim.keymap.set({ "n", "v" }, maps.prev or "[x", function()
      log.guard("yana.inline_diff prev hunk", function()
        M._navigate_or_park_state(state, "prev")
      end)
    end, vim.tbl_extend("force", km, { desc = "yana: prev hunk" }))
  end
  ledger.mark(change_ledger(change, opts), "review_profile_keymaps_ready")

  -- A mode transition is part of the decision, not optional guidance. Show it
  -- before the review becomes actionable so an immediate ca/cA cannot write a
  -- mode the operator was never shown. Navigation and key hints remain safe to
  -- defer; this disclosure does not.
  show_compound_mode(change)

  -- The closest in-process proxy for "the user can now see the review": a
  -- schedule after the render drains on the next main-loop tick, which is
  -- after the redraw the render queued. True paint time is only observable
  -- from the terminal capture tier (limitations register L6), and this stamp
  -- is named as a proxy rather than presented as paint time.
  vim.schedule(function()
    ledger.mark(change_ledger(change, opts), "review_redraw")
  end)

  -- Synchronous end of the open path: the review exists, keymaps and watches
  -- are armed, and the user can act as soon as the next loop turn paints.
  -- Navigation to the first hunk and the hint/banner are display guidance, not
  -- authority, so they run on the next loop turn rather than spending the
  -- synchronous open-tail budget.
  ledger.mark(change_ledger(change, opts), "review_setup_complete")

  vim.schedule(function()
    announce_state()
    apply_review_winhl(bufnr, state)
    -- Rung 1 over the render that staged this review. It observes only, so it
    -- runs after the open-path budget closes: the diagnostic must not spend the
    -- user's review-open tail. Its inputs are the just-rendered buffer, extmarks
    -- and palette state captured above.
    render_invariant({
      site = "open",
      bufnr = bufnr,
      blocks = blocks,
      model = model,
      model_source = model_source,
      change = change,
      opts = opts,
    })
    -- R8: fired AFTER the Rung-1 render check above, not before -- an
    -- observer polling for "review open" must see a review the invariant has
    -- already accepted, never one still mid-paint.
    M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "open")
    -- The first-hunk landing does NOT happen here. This callback is queued
    -- (via vim.schedule) strictly before the one below that calls focus_buf /
    -- tabnew, and vim.schedule preserves registration order -- so at this
    -- point bufnr is never yet shown in any window. jump_to_block's own
    -- `win_for_buf(bufnr)` guard would find nothing and silently no-op every
    -- single time (measured: every review open, first file included). The
    -- landing is issued from the next schedule below instead, right after the
    -- window that shows bufnr is attached, so win_for_buf(bufnr) is
    -- guaranteed non-nil at jump time -- an ordering fix, not a timing one.
    show_compound_mode(change)
    if state.diff_blocks[1] then
      show_hint(nav_start_line(bufnr, state.diff_blocks[1]), state.diff_blocks[1])
    else
      -- A hunkless review is reachable: an agent-created empty file diffs to
      -- zero hunks but still needs an explicit accept or reject. Without a hint
      -- the user sees an empty buffer and no affordance at all.
      show_hint(1)
    end
  end)

  vim.schedule(function()
    if opts.preview then
      -- This closure outlives its caller, so it can fire AFTER a failure in
      -- the preview's own setup has already torn the session down. Opening a
      -- tab onto the dead scratch buffer then resurrects a ghost the user
      -- cannot close. Only display a session that is still the live one.
      local st = pool_for_state(state)
      if st.active ~= state then
        return
      end
      vim.cmd("tabnew")
      -- Remembered so the preview's teardown can close exactly this tab
      -- rather than leaking one tab (and one scratch buffer) per open.
      state.preview_tab = vim.api.nvim_get_current_tabpage()
      vim.api.nvim_win_set_buf(0, bufnr)
      vim.bo[bufnr].filetype = "python"
      -- tabnew+set_buf also skips WinEnter on some paths; re-apply now that
      -- a window actually shows the preview buffer.
      apply_review_winhl(bufnr, state)
      -- The window now exists (nvim_win_set_buf just attached it, above), so
      -- win_for_buf(bufnr) inside jump_to_block is guaranteed to find it.
      -- Landing here -- after the attach, in the same tick -- rather than in
      -- the earlier schedule is the fix; see the comment there.
      land_on(change.path, bufnr, initial_landing_block)
    else
      -- Same identity guard the preview branch above carries, and it was
      -- missing here: this closure fires a tick after the open, by which time
      -- the session can already be torn down. abort_undisplayable_review
      -- clears `active` UNCONDITIONALLY, so if a newer review B had become
      -- active in that tick it lost its singleton -- orphaning B's write
      -- guard and keymaps while process_next opened C on top. Exactly the
      -- class the last two rounds closed everywhere else.
      local st = pool_for_state(state)
      if st.active ~= state then
        return
      end
      local focused = focus_buf(change.path, bufnr)
      if not focused then
        -- focus_buf could not put the review anywhere visible (e.g. E37 from
        -- a modified current buffer with 'hidden' off). Leaving it parked
        -- with no window would strand the whole queue behind an
        -- unreachable review, so tear it down without touching disk.
        notify_one_line(
          "yana: could not display review for `" .. (change.rel or change.path)
            .. "` — no window available; left pending",
          vim.log.levels.WARN
        )
        abort_undisplayable_review(state)
        return
      end
      -- apply_review_winhl ran during M.open while the buffer was in no
      -- window, so wins_for_buf was empty. Opening into the current window
      -- does not fire WinEnter. Re-apply now that a window actually shows
      -- the review, or the hunks stay unmapped (PLAIN) for a single-window
      -- user.
      apply_review_winhl(bufnr, state)
      -- Same reason as apply_review_winhl above: focus_buf just attached the
      -- window that shows bufnr, so win_for_buf(bufnr) inside jump_to_block
      -- is guaranteed to find it now. This lands the cursor on the first
      -- hunk's live-authority start line (nav_start_line / live_block_range
      -- -- the same path ]x/[x use via jump_to_block), not a stale stored
      -- line -- keeping the drift-precision this call already relied on.
      land_on(change.path, bufnr, initial_landing_block)
      -- One screen line, always. Without noice, vim.notify is a plain echo:
      -- anything wider than `columns` raises a hit-enter prompt, which blocks
      -- the main loop and every queued vim.schedule behind it — the review
      -- opens and the editor then freezes until the user presses Enter.
      -- Measured 2026-08-12: this exact banner deadlocked a test harness for
      -- ~50s. The full key list already lives in the in-buffer hint extmark
      -- (show_hint above), which is where the user is actually looking.
      local banner = string.format(
        "yana: review %s — %s accept · %s reject",
        change.rel,
        maps.theirs or "ca",
        maps.ours or "cr"
      )
      notify_one_line(banner, vim.log.levels.INFO)
    end
  end)
  return true, state
end

function M.enqueue(change, opts)
  opts = opts or {}
  local st = pool_for(opts)
  if st.active and st.active.change == change then
    return false
  end
  for _, item in ipairs(st.queue) do
    if item.change == change then
      process_next(opts)
      return "already_queued"
    end
  end
  change.review_error = nil
  stamp_review_workspace(change, opts)
  local item = {
    change = change,
    opts = opts,
    owner = freeze_review_owner(opts),
  }
  remember_batch_item(st, item)
  table.insert(st.queue, item)
  local attempted = process_next_for(opts)
  if attempted == change then
    return "opened"
  end
  return "inserted"
end

-- Drop active and queued reviews owned by one panel/stream epoch inside a
-- workspace pool. Other owners' work in the same pool survives (H4).
function M.discard_for_owner(owner, opts)
  if not owner then
    return M.discard_pool(opts)
  end
  local st = pool_for(opts or {})
  local cleared_active = false
  if st.active then
    local active_owner = st.active.opts and st.active.opts.review_owner
    if owners_match(active_owner, owner) then
      pcall(M.cleanup, st.active)
      st.active = nil
      cleared_active = true
    end
  end
  local kept = {}
  for _, item in ipairs(st.queue) do
    if not owners_match(queue_item_owner(item), owner) then
      kept[#kept + 1] = item
    end
  end
  st.queue = kept
  M._rewind_forget_owner(owner)
  announce_state()
  if cleared_active then
    process_next_for(opts)
  end
end

-- Abandon every review in a workspace pool without resolving hunks. Used when
-- the owning conversation is discarded (new_chat) so active/queued work cannot
-- outlive the claim release.
function M.discard_pool(opts)
  local st = pool_for(opts or {})
  local tabs_path = review_tabs_state_path(opts or {})
  if tabs_path then
    pcall(vim.fn.delete, tabs_path)
  end
  if st.active then
    pcall(M.cleanup, st.active)
    st.active = nil
  end
  st.queue = {}
  st.batched = {}
  st.order = {}
  st.order_seq = 0
  st.review_tabs = nil
  M._rewind_forget_owner(nil)
  announce_state()
end

-- The direct review path (panel picker -> diff.review -> here) used to call
-- M.open unconditionally. M.open sets the `active` singleton with no guard, so
-- reviewing change B while change A was open silently overwrote it: A's
-- keymaps, BufWriteCmd guard and extmarks stayed live with nothing owning
-- them, and A's eventual finish_session cleared `active` out from under B.
-- Queueing instead makes that state unreachable — one review is open at a
-- time by construction, which is the same invariant process_next already
-- assumes. The queue is checked as well as `active`: between finish_session
-- clearing `active` and its scheduled process_next running, `active` is nil
-- while the queue is not empty, and opening directly in that window would
-- jump ahead of older changes.
function M.review(change, opts)
  opts = opts or {}
  local st = pool_for(opts)
  if st.active or #st.queue > 0 then
    M.enqueue(change, opts)
    return true
  end
  -- Same orphan contract as the queue path: a throw here must not leave the
  -- write guard and keymaps armed. It also must not RE-RAISE: this path's only
  -- caller is the panel picker's vim.ui.select callback, where a raw
  -- multi-line traceback is echoed straight to the message area -- the
  -- hit-enter deadlock class notify.one_line exists to prevent, and the one
  -- entry that had no one-line report of its own. Fail like the queue path
  -- does: stamped (in open_or_abandon), announced, reported in one line, and
  -- falsy to the caller.
  local ok, err = open_or_abandon(change, opts)
  if not ok then
    M._announce_open_failure(change, "inline review failed: " .. notify.error_headline(err), vim.log.levels.ERROR)
    return false
  end
  return true
end

function M.pending_count(opts)
  if opts then
    local st = pool_for(opts)
    return #st.queue + (st.active and 1 or 0)
  end
  local n = 0
  for _, st in pairs(pools) do
    n = n + #st.queue + (st.active and 1 or 0)
  end
  return n
end

function M.active_change(opts)
  if opts then
    local st = pool_for(opts)
    return st.active and st.active.change or nil
  end
  for _, st in pairs(pools) do
    if st.active then
      return st.active.change
    end
  end
  return nil
end

-- How many reviews a queued change actually waits on: everything ahead of it
-- in the queue, plus the open one. Callers used `pending_count() - 1`, which
-- is position-blind -- it reports the same number for every queued change, so
-- items queued BEHIND one inflated its own "behind N". Returns nil when the
-- change is not queued (open, resolved, or unknown to the engine).
function M.queue_wait(change, opts)
  local st
  if opts then
    st = pool_for(opts)
  else
    st = find_active_for_change(change)
    if not st then
      for _, candidate in pairs(pools) do
        for _, item in ipairs(candidate.queue) do
          if item.change == change then
            st = candidate
            break
          end
        end
        if st then break end
      end
    end
  end
  if not st then
    return nil
  end
  for i, item in ipairs(st.queue) do
    if item.change == change then
      return (i - 1) + (st.active and 1 or 0)
    end
  end
  return nil
end

-- Is `bufnr` under active or queued review? Consumed by the user's autosave
-- config to suppress writes while a review is pending. Cheap and
-- side-effect free: bufnr(path, false) never creates a buffer.
function M.is_reviewing(bufnr)
  if not bufnr then
    return false
  end
  for _, st in pairs(pools) do
    if st.active and st.active.bufnr == bufnr then
      return true
    end
    for _, item in ipairs(st.queue) do
      if vim.fn.bufnr(diff.abs_path(item.change.path), false) == bufnr then
        return true
      end
    end
    for path in pairs(st.batched) do
      if vim.fn.bufnr(path, false) == bufnr then
        return true
      end
    end
  end
  return false
end

--- Panel-level accept/reject while inline review is open for this change.
function M.resolve_change(change, action)
  local st = find_active_for_change(change)
  if not st or not st.active or not change or st.active.change.id ~= change.id then
    return false
  end
  local active = st.active
  if action == "accept" then
    active.diff_blocks = {}
    vim.api.nvim_buf_clear_namespace(active.bufnr, NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(active.bufnr, AUTH_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(active.bufnr, HINT_NS, 0, -1)
    return finish_session(active, true)
  end
  if action == "reject" then
    return finish_session(active, false)
  end
  return false
end

function M.focus_active(opts)
  local st = pool_for(opts or {})
  if not st.active then
    return false
  end
  if not land_on(st.active.change.path, st.active.bufnr, nil) then
    focus_buf(st.active.change.path, st.active.bufnr)
  end
  return true
end

function M.active_state(opts)
  if opts then
    return pool_for(opts).active
  end
  for _, st in pairs(pools) do
    if st.active then
      return st.active
    end
  end
  return nil
end

function M.review_tabs_state_path(opts)
  return review_tabs_state_path(opts or {})
end

local function review_tabs_pending_paths(st, owned)
  local pending = {}
  local function mark_if_pending(c)
    if not c or not c.path then
      return
    end
    local abs = diff.abs_path(c.path)
    if not owned[abs] then
      return
    end
    local blocks = (c._parked_review and c._parked_review.blocks) or {}
    if c.status == "pending" then
      pending[abs] = c.rel or c.path
      return
    end
    if c.status ~= "accepted" and c.status ~= "rejected" and #blocks > 0 then
      pending[abs] = c.rel or c.path
    end
  end
  for _, item in ipairs(st.order or {}) do
    mark_if_pending(item and item.change)
  end
  if st.active then
    mark_if_pending(st.active.change)
  end
  return pending
end

local function review_tabs_load_owned_record(st, opts)
  local path = review_tabs_state_path(opts)
  if not path then
    return nil, "unknown"
  end
  local rec = read_json_file(path)
  if type(rec) ~= "table" or rec.turn_key == nil or type(rec.owned) ~= "table" then
    return nil, "unknown"
  end
  local owned = {}
  for abs, entry in pairs(rec.owned) do
    if type(abs) ~= "string" or type(entry) ~= "table" or type(entry.tab_id) ~= "number" then
      return nil, "unknown"
    end
    local tab = select(1, tab_for_path(abs))
    if not tab or tab ~= entry.tab_id then
      return nil, "unknown"
    end
    owned[abs] = { tab_id = tab, rel = entry.rel or abs }
  end
  return {
    path = path,
    turn_key = tostring(rec.turn_key),
    owned = owned,
  }, nil
end

local function review_tabs_prompt_yes(on_choice)
  local fired = false
  local picked_yes = nil
  local select_returned = false
  local function choice_is_yes(choice, idx)
    if idx == 1 then
      return true
    end
    if idx == 2 then
      return false
    end
    if type(choice) == "number" then
      if choice == 1 then
        return true
      end
      if choice == 2 then
        return false
      end
      return nil
    end
    if type(choice) == "string" then
      if choice:find("Yes", 1, true) then
        return true
      end
      if choice:find("No", 1, true) then
        return false
      end
      return nil
    end
    if type(choice) == "table" then
      if type(choice.label) == "string" and choice.label:find("Yes", 1, true) then
        return true
      end
      if type(choice.label) == "string" and choice.label:find("No", 1, true) then
        return false
      end
      if type(choice.text) == "string" and choice.text:find("Yes", 1, true) then
        return true
      end
      if type(choice.text) == "string" and choice.text:find("No", 1, true) then
        return false
      end
      if type(choice[1]) == "string" and choice[1]:find("Yes", 1, true) then
        return true
      end
      if type(choice[1]) == "string" and choice[1]:find("No", 1, true) then
        return false
      end
    end
    return nil
  end
  local function schedule_once(fn)
    vim.schedule(fn)
  end

  local function fire_once(yes)
    if fired then
      return
    end
    fired = true
    picked_yes = yes and true or false
    if on_choice and select_returned then
      schedule_once(function()
        on_choice(picked_yes)
      end)
    end
  end
  vim.ui.select({
    "Yes - close tabs opened by this review",
    "No - keep review tabs open",
  }, {
    prompt = "Close tabs opened by this review?",
  }, function(choice, idx)
    local yes = choice_is_yes(choice, idx)
    if yes == nil then
      -- A cancelled prompt is still a settled answer under the review-apply
      -- contract: leave tabs open, but do not strand the turn claim.
      fire_once(false)
      return
    end
    fire_once(yes)
  end)
  select_returned = true
  if fired then
    return { status = "answered", yes = picked_yes }
  end
  return { status = "prompted" }
end

local function review_tabs_owned_snapshot(owned)
  local snap = {}
  for abs, entry in pairs(owned or {}) do
    snap[abs] = { tab_id = entry.tab_id, rel = entry.rel or abs }
  end
  return snap
end

local function review_tabs_record_matches(path, expected_turn_key, expected_owned)
  local rec = read_json_file(path)
  if type(rec) ~= "table" or tostring(rec.turn_key or "") ~= tostring(expected_turn_key or "") then
    return false
  end
  if type(rec.owned) ~= "table" then
    return false
  end
  for abs, entry in pairs(expected_owned or {}) do
    local got = rec.owned[abs]
    if type(got) ~= "table" or type(got.tab_id) ~= "number" or got.tab_id ~= entry.tab_id then
      return false
    end
  end
  for abs, _ in pairs(rec.owned) do
    if expected_owned[abs] == nil then
      return false
    end
  end
  return true
end

function M.prompt_close_owned_tabs(opts)
  opts = opts or {}
  local st = pool_for(opts)
  local rec = review_tabs_load_owned_record(st, opts)
  if not rec then
    -- Unknown ownership is a fail-closed control path, not a product fault.
    -- Keep it silent so clean turns do not append warning lines to yana.log.
    st.review_tabs = nil
    return { ok = false, reason = "unknown_ownership", closed = {}, refused = {} }
  end
  if vim.tbl_isempty(rec.owned) then
    pcall(vim.fn.delete, rec.path)
    st.review_tabs = nil
    return { ok = true, reason = "none_owned", closed = {}, refused = {} }
  end
  local captured_turn_key = rec.turn_key
  local captured_owned = review_tabs_owned_snapshot(rec.owned)
  local settled = nil

  local function finalize_once(result)
    if settled then
      return
    end
    settled = result
    if opts and type(opts.after_close) == "function" then
      pcall(opts.after_close, result)
    end
  end

  local function clear_live_owner_if_same_turn()
    if st.review_tabs and tostring(st.review_tabs.turn_key or "") == tostring(captured_turn_key) then
      st.review_tabs = nil
    end
  end

  local function apply_choice(yes)
    if settled then
      return
    end
    if not review_tabs_record_matches(rec.path, captured_turn_key, captured_owned) then
      notify_one_line("yana: stale close-tabs choice ignored", vim.log.levels.WARN)
      finalize_once({ ok = false, reason = "stale_ownership", closed = {}, refused = {} })
      return
    end

    if not yes then
      pcall(vim.fn.delete, rec.path)
      clear_live_owner_if_same_turn()
      finalize_once({ ok = true, reason = "declined", closed = {}, refused = {} })
      return
    end

    local pending = review_tabs_pending_paths(st, captured_owned)
    for abs, entry in pairs(captured_owned) do
      local tab = select(1, tab_for_path(abs))
      if not tab or tab ~= entry.tab_id then
        notify_one_line("yana: stale close-tabs choice ignored", vim.log.levels.WARN)
        finalize_once({ ok = false, reason = "stale_ownership", closed = {}, refused = {} })
        return
      end
    end

    local closed, refused = {}, {}
    for abs, entry in pairs(captured_owned) do
      local rel = entry.rel or abs
      local tab = entry.tab_id
      if tab then
        if pending[abs] then
          refused[rel] = true
          notify_one_line("yana: keeping tab open for pending hunks in " .. rel, vim.log.levels.WARN)
        else
          local switched = pcall(vim.api.nvim_set_current_tabpage, tab)
          if switched then
            local closed_ok = pcall(vim.cmd, "tabclose")
            if closed_ok then
              closed[rel] = true
            end
          end
          if not switched then
            notify_one_line("yana: failed to focus tab for " .. rel .. "; leaving open", vim.log.levels.WARN)
          elseif not closed[rel] then
            notify_one_line("yana: failed to close tab for " .. rel .. "; leaving open", vim.log.levels.WARN)
          end
        end
      end
    end
    pcall(vim.fn.delete, rec.path)
    clear_live_owner_if_same_turn()
    finalize_once({ ok = true, reason = "closed", closed = closed, refused = refused })
  end

  local prompt = review_tabs_prompt_yes(apply_choice)
  if settled then
    return settled
  end
  if prompt.status == "answered" then
    apply_choice(prompt.yes)
    return settled or { ok = false, reason = "prompt_unresolved", closed = {}, refused = {} }
  end
  if prompt.status == "prompted" then
    return { ok = true, reason = "prompted", closed = {}, refused = {} }
  end

  return settled or { ok = false, reason = "prompt_unresolved", closed = {}, refused = {} }
end

function M.rerender(state)
  if not state or not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
    return
  end
  apply_palette_highlights()
  apply_review_winhl(state.bufnr, state)
  render_blocks(state.bufnr, state.diff_blocks, {
    site = "rerender",
    model = state.model_hunks,
    model_source = state.model_source,
    change = state.change,
    opts = state.opts,
  })
end

--- Rung 1 on demand (`:YanaRenderCheck`). Same function the invariant
--- capture runs, so what the operator sees is what production recorded.
--- Returns a list of results, one per active review, newest pool order.
function M.render_check(opts)
  local out = {}
  local states = {}
  if opts and (opts.workspace or opts.review_owner) then
    local st = pool_for(opts)
    if st.active then
      states[#states + 1] = st.active
    end
  else
    for _, st in pairs(pools) do
      if st.active then
        states[#states + 1] = st.active
      end
    end
  end
  for _, state in ipairs(states) do
    local result = render_invariant({
      site = "on_demand",
      bufnr = state.bufnr,
      blocks = state.diff_blocks,
      model = state.model_hunks,
      model_source = state.model_source,
      change = state.change,
      opts = state.opts,
    })
    if result then
      out[#out + 1] = result
    end
  end
  return out
end

--- Read-only snapshot of every review pool and its decoration state, for
--- `:YanaDump`. Pure reads: no repair, no rerender, no side effects.
function M.introspect()
  local out = { pools = {}, ns = NS, hint_ns = HINT_NS }
  for key, st in pairs(pools) do
    local pool = {
      workspace = key,
      queued = #st.queue,
      batched = {},
      queue = {},
      active = nil,
    }
    for path in pairs(st.batched) do
      pool.batched[#pool.batched + 1] = path
    end
    for i, item in ipairs(st.queue) do
      pool.queue[i] = {
        change_id = item.change and item.change.id or nil,
        rel = item.change and (item.change.rel or item.change.path) or nil,
        status = item.change and item.change.status or nil,
        review_error = item.change and item.change.review_error or nil,
      }
    end
    if st.active then
      local state = st.active
      local blocks = {}
      for i, b in ipairs(state.diff_blocks or {}) do
        blocks[i] = {
          index = i,
          model_index = b.model_index,
          new_start_line = b.new_start_line,
          new_end_line = b.new_end_line,
          old_count = #(b.old_lines or {}),
          new_count = #(b.new_lines or {}),
          incoming_extmark_id = b.incoming_extmark_id,
          delete_extmark_id = b.delete_extmark_id,
          authority_extmark_id = b.authority_extmark_id,
        }
      end
      pool.active = {
        change_id = state.change and state.change.id or nil,
        rel = state.change and (state.change.rel or state.change.path) or nil,
        bufnr = state.bufnr,
        review_error = state.change and state.change.review_error or nil,
        model_source = state.model_source,
        blocks = blocks,
        hint_line = state.hint_line,
        hint_id = state.hint_id,
        decorations = render_check.collect({
          site = "dump",
          bufnr = state.bufnr,
          blocks = state.diff_blocks,
          model = state.model_hunks,
          model_source = state.model_source,
          ns = NS,
          hint_ns = HINT_NS,
          ext_hl = EXT_HL,
          palette = PALETTE,
          change_id = state.change and state.change.id or nil,
          rel = state.change and (state.change.rel or state.change.path) or nil,
        }),
      }
    end
    out.pools[#out.pools + 1] = pool
  end
  return out
end

function M.close_active(opts)
  local st = pool_for(opts or {})
  if not st.active then
    return false
  end
  finish_session(st.active, false)
  return true
end

--- One sibling file's share of a whole-review abort (operator ruling
--- 2026-08-25). `change` is a turn-mate of the review being aborted — either
--- still queued (never opened: `M.open` is the only writer of proposal
--- bytes into a buffer, so an unopened file's buffer, if it exists at all
--- via a pre-opened owned tab, already holds nothing but plain disk text)
--- or PARKED (opened once, staged, then set aside — `change._parked_review`
--- and `change.undo_pre_stage_seq` both survive that, because parking
--- deliberately leaves the buffer staged so reopening is instant).
---
--- A parked file's buffer genuinely holds proposal bytes and needs the same
--- bookmarked `:undo {seq}` jump `M.abort_active` gives the active file —
--- against ITS OWN bookmark, because a seq number from one buffer's undo
--- tree means nothing on another's. An unopened file has no bookmark and
--- skips the jump; there is nothing on its buffer to rewind.
--- Either way the paint (all four yana namespaces) and any retrace
--- undo/redo maps `M.cleanup` may have installed at park time both go, so
--- every buffer this abort ever touches ends up with Neovim's own `u`/
--- `<C-r>` — the same bar `M.cleanup`'s `_abort_no_retrace` branch holds the
--- active file to.
local function abort_rewind_sibling(st, change)
  if not change or not change.path then
    return
  end
  local abs = diff.abs_path(change.path)
  local bufnr = vim.fn.bufnr(abs, false)
  if bufnr and bufnr > 0 and vim.api.nvim_buf_is_valid(bufnr) then
    if change.undo_pre_stage_seq ~= nil then
      pcall(M._rewind_suppress, function()
        vim.api.nvim_buf_call(bufnr, function()
          vim.cmd("silent undo " .. tonumber(change.undo_pre_stage_seq))
        end)
      end)
    end
    vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, AUTH_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, ANCHOR_NS, 0, -1)
    vim.api.nvim_buf_clear_namespace(bufnr, HINT_NS, 0, -1)
    for _, mode in ipairs({ "n", "v" }) do
      pcall(vim.keymap.del, mode, "u", { buffer = bufnr })
      pcall(vim.keymap.del, mode, "<C-r>", { buffer = bufnr })
    end
  end
  M._rewind_forget_path(change.path)
  queue_remove_change(st, change)
  -- Same status a review the operator withdraws by hand always lands on
  -- (`M._withdraw_for_plain_undo`'s ruling #100 comment): nothing of this
  -- file's proposal survives, byte for byte the outcome IS a reject, and
  -- `pending_hunk_count_for`/the panel's own pending tally both key off
  -- `status`, never off whether a dialog happened to fire on this exact file.
  change.status = "rejected"
  change.review_error = nil
  change._parked_review = nil
  change._parked_item = nil
  change._parked_already_staged = nil
end

--- The Yes half of `M.abort_active`'s dialog. Everything that changes state
--- lives here, and only here — the caller has already shown the consequence
--- and gotten "Yes" back before this runs.
local function perform_whole_review_abort(st, state, turn_changes)
  if st.active ~= state then
    -- The review moved on while the dialog was open (a real-usage race; the
    -- headless shim answers synchronously so this never fires under test).
    -- Refuse rather than rewind a review that is no longer the one the
    -- operator was just shown.
    notify_one_line("yana: abort cancelled — the review changed before you answered", vim.log.levels.WARN)
    return false
  end
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    notify_one_line("yana: the review's buffer is gone; nothing to put back", vim.log.levels.WARN)
    return false
  end

  -- SIBLINGS FIRST, active file last. Order does not matter to the buffers
  -- themselves (each rewinds against its own bookmark, on its own tree) but
  -- it matters to the claim: marking every sibling non-pending BEFORE
  -- `finish_session` resolves the active file means the panel's own
  -- `on_close` (pending == 0 across `p.changes`) fires true the instant the
  -- active file closes, instead of waiting on siblings `finish_session`
  -- never touches. That single existing check is what closes the owned
  -- tabs and releases the turn claim — this function does not reach into
  -- ui.lua to do either by hand.
  for _, sibling in ipairs(turn_changes) do
    if sibling ~= state.change then
      abort_rewind_sibling(st, sibling)
    end
  end

  if state.undo_pre_stage_seq == nil then
    -- Never guess a sequence number. Without the bookmark this cannot know
    -- where the file ended and the proposal began, and jumping to the wrong
    -- state would take the operator's own work with it.
    notify_one_line(
      "yana: cannot abort — this review has no pre-staging bookmark, so the file before the hunks is not identifiable",
      vim.log.levels.WARN
    )
    return false
  end

  -- SUPPRESSED (KI-1 ruling 2026-08-24). An abort deliberately lands BELOW
  -- the insert boundary, which is exactly the shape the rewind reconciler
  -- reacts to -- so Yana's own abort transaction must not be mistaken for the
  -- operator time travelling. The watch is dropped outright below: the
  -- operator withdrew this review by hand, and a later `:later` must not
  -- resurrect it.
  local ok = pcall(M._rewind_suppress, function()
    vim.api.nvim_buf_call(bufnr, function()
      vim.cmd("silent undo " .. tonumber(state.undo_pre_stage_seq))
    end)
  end)
  if not ok then
    -- A reload past 'undoreload' clears the tree and the bookmark dies with it.
    -- Refuse with everything intact rather than closing a review over a buffer
    -- that is still holding the proposal.
    notify_one_line(
      "yana: cannot abort — undo history no longer reaches the state before this review staged its hunks",
      vim.log.levels.WARN
    )
    return false
  end

  local L = change_ledger(state.change, state.opts)
  ledger.record_decision(L, {
    action = "review_aborted",
    actor = "user",
    reason = "abort_to_pre_stage",
    change_id = state.change and state.change.id,
    rel = state.change and (state.change.rel or state.change.path),
  })

  -- The blocks are dropped BEFORE the session is finished, and that ordering is
  -- the whole of it. `finish_session(state, false)` is the REJECT path: it walks
  -- the remaining hunks and restores each one's pre-turn content over its live
  -- range. Here the buffer is already at the pre-staging state — there is
  -- nothing left to restore, and asking it to try is worse than pointless.
  -- Measured: with the hunks still listed, the reject correctly REFUSED
  -- ("the human rewrote the agent's own lines in this hunk") because the
  -- operator's mid-review edit was unattributable, and the review stayed open
  -- over a buffer that no longer held the proposal — the exact incoherent state
  -- this operation exists to prevent.
  state.diff_blocks = {}
  state.decisions = {}
  M._rewind_forget_path(state.change and state.change.path)
  -- ABORT RELEASES THE RETRACE MAPS (row `r_abort_releases_u_and_cr_maps`):
  -- this review closed by
  -- undoing every decision, so there is no decision left anywhere for a
  -- cross-file retrace to walk back into. `M.cleanup` (called inside
  -- `finish_session`, shortly) checks this flag and skips installing the
  -- retrace `u`/`<C-r>` it installs on every OTHER close — leaving Neovim's
  -- own undo/redo in this buffer too, same as every sibling just got above.
  state._abort_no_retrace = true
  finish_session(state, false)
  notify_one_line(
    "yana: review aborted — every file is back as it was before the hunks",
    vim.log.levels.INFO
  )
  return true
end

--- Abort the WHOLE review: every file it touched — the active buffer and any
--- parked or still-queued sibling — rewinds to its pre-stage state in one
--- act, behind a confirmation dialog that discloses the consequence first.
--- (Operator ruling 2026-08-25, superseding the single-file abort below it
--- replaced: "on abort, every accept/reject is undone and all buffers
--- return to the pre-review state, behind a confirmation dialog that
--- explains the consequence.")
---
--- WHY THIS IS NOT UNDO. The operator's request, 2026-08-19: *"undo should go
--- back to the state right BEFORE the hunks appeared not land me in the middle
--- of hunk creation process"*. Raw `u` cannot deliver that, and the reason is
--- structural rather than a missing key. Undo walks Neovim's tree one state at
--- a time, and between the pre-turn file and the review there are several: each
--- rejected hunk's restoration, whatever the operator typed, and the staging.
--- Walking them is what "landing in the middle" IS. Worse, undoing into the
--- staging while the review is still open strips the agent's proposal out of a
--- buffer whose hunk list still claims to describe it, which is why `u` refuses
--- at that floor rather than doing it.
---
--- So this is a TRANSACTION, not a bigger undo: the decision state is unwound
--- first, then each buffer is moved in ONE jump to its own pre-staging
--- bookmark, then the review is closed and its marks and keymaps released. At
--- no point is there a buffer without a review or a review without its buffer.
---
--- `U` remains what it was — take back every decision and return to the review
--- AS OPENED, hunks still staged, still deciding. This goes one bookmark
--- further and ends the review. Both are kept because they answer different
--- questions: "let me start these decisions again" and "take this whole thing
--- away".
---
--- SAFETY. Nothing here writes the real tree, and nothing needs to: no decision
--- is durable while a review is open (`finish_session` is the single writer and
--- it also closes). Aborting after the review has closed is not this operation
--- and is refused — by then the applier has moved the real file and the answer
--- is the journaled revert, not a buffer undo.
---
--- Recoverable: each jump is `:undo {seq}`, so `<C-r>` still reaches that
--- file's proposal until its tree is otherwise disturbed -- right up until the
--- Yes-abort itself releases the key back to Neovim (see `M.cleanup` above).
function M.abort_active(opts)
  local st = pool_for(opts or {})
  local state = st.active
  if not state then
    notify_one_line("yana: no review is open to abort", vim.log.levels.WARN)
    return false
  end
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    notify_one_line("yana: the review's buffer is gone; nothing to put back", vim.log.levels.WARN)
    return false
  end
  if state.undo_pre_stage_seq == nil then
    -- Never guess a sequence number. Without the bookmark this cannot know
    -- where the file ended and the proposal began, and jumping to the wrong
    -- state would take the operator's own work with it.
    notify_one_line(
      "yana: cannot abort — this review has no pre-staging bookmark, so the file before the hunks is not identifiable",
      vim.log.levels.WARN
    )
    return false
  end

  -- SCOPE + DISCLOSURE, read-only. Every file this turn ever staged (the
  -- active buffer, plus any sibling parked or still queued behind it) --
  -- computed and counted BEFORE the dialog fires, and before anything below
  -- is allowed to touch a byte, so what "Yes" discloses is exactly what
  -- "Yes" is about to do.
  local turn_changes = review_tabs_collect_turn_changes(st, state.change)
  local file_count = #turn_changes
  local accepted_count, rejected_count = 0, 0
  local function tally(list)
    for _, d in ipairs(list or {}) do
      if d.action == "accept" then
        accepted_count = accepted_count + 1
      elseif d.action == "reject" then
        rejected_count = rejected_count + 1
      end
    end
  end
  tally(state.sealed_decisions)
  tally(state.decisions)
  for _, c in ipairs(turn_changes) do
    if c ~= state.change and type(c._parked_review) == "table" then
      tally(c._parked_review.sealed_decisions)
    end
  end

  local prompt = string.format(
    "Abort the whole review? %d file%s in this review — %d hunk%s accepted, %d hunk%s rejected — "
      .. "will ALL be undone, including your own edits made during the review.",
    file_count,
    file_count == 1 and "" or "s",
    accepted_count,
    accepted_count == 1 and "" or "s",
    rejected_count,
    rejected_count == 1 and "" or "s"
  )

  -- `vim.ui.select`, the same mechanism the close-tabs prompt uses (see
  -- `review_tabs_prompt_yes` above), item 1 "Yes", item 2 "No" -- so a test
  -- (or a picker plugin) can auto-answer without knowing anything about
  -- abort specifically. "No" and a dismissed prompt both reach `choice ==
  -- nil` here and this function has not mutated a single field by then:
  -- that IS the no-op contract, not a separate branch enforcing it.
  vim.ui.select({
    "Yes - abort the whole review",
    "No - keep reviewing",
  }, { prompt = prompt }, function(choice)
    if type(choice) ~= "string" or choice:sub(1, 3) ~= "Yes" then
      return
    end
    perform_whole_review_abort(st, state, turn_changes)
  end)
  return true
end

function M.process_next(opts)
  process_next_for(opts)
end

function M.batched_count(opts)
  if opts then
    local n = 0
    for _ in pairs(pool_for(opts).batched) do
      n = n + 1
    end
    return n
  end
  local n = 0
  for _, st in pairs(pools) do
    for _ in pairs(st.batched) do
      n = n + 1
    end
  end
  return n
end

M._test = M._test or {}
M._test.fault = FAULT
M._test.pools = pools
M._test.pool_for = pool_for
M._test.discard_pool = M.discard_pool
M._test.discard_for_owner = M.discard_for_owner
M._test.process_next = M.process_next
M._test.owners_match = owners_match
M._test.prompt_close_owned_tabs = M.prompt_close_owned_tabs
M._test.review_tabs_state_path = M.review_tabs_state_path

return M
