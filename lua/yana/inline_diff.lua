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
    end
    return
  end
  pcall(tl.intent, entry)
end

local function tl_same_observation(a, b)
  return type(a) == "table"
    and type(b) == "table"
    and a.buffer_epoch == b.buffer_epoch
    and a.undo_seq == b.undo_seq
    and a.expected_hash == b.expected_hash
end

--- Record typing that occurred since the last review event. The row stores the
--- post-edit undo bookmark; the walker resolves its destination from the
--- nearest older buffer row.
local function tl_capture_human_edit(state)
  if not (state and state.bufnr and vim.api.nvim_buf_is_valid(state.bufnr)) then
    return
  end
  local obs = tl_observe(state.bufnr)
  if state.timeline_obs and not tl_same_observation(state.timeline_obs, obs) then
    obs.regime = "buffer"
    tl_record(state, "human_edit", "edit " .. (state.change.rel or state.change.path or "?"), obs)
  end
  state.timeline_obs = obs
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
  for _, w in ipairs(vim.api.nvim_list_wins()) do
    if vim.api.nvim_win_get_buf(w) == bufnr then
      return w
    end
  end
  return nil
end

local function focus_buf(path, bufnr)
  local win = win_for_buf(bufnr)
  if win and vim.api.nvim_win_is_valid(win) then
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
    if diff.text_equal_snapshot(cur, change.after or "") then
      change.disk_at_open = diff.read_file_bytes(path)
      change.undo_pre_stage_seq = buf_undo_seq(existing)
      return existing, nil
    end
  end

  local existing_modified = existing > 0
    and vim.api.nvim_buf_is_loaded(existing)
    and vim.bo[existing].modified
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
    -- (e.g. the parked snapshot) instead of fixing the flag at its source
    -- was tried and reverted -- a parked snapshot is captured AFTER
    -- whatever dirtied the buffer, agent decision or genuinely unrelated
    -- human edit alike, so it always matches trivially and cannot tell the
    -- two apart; it would have let a real unrelated edit back in.
    local cur = diff.buffer_text_normalized(existing)
    if not diff.text_equal_snapshot(cur, change.before or "") then
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
  if not diff.text_equal_snapshot(disk_bytes, change.before) then
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

local function jump_to_block(bufnr, block)
  if not block then
    return
  end
  local win = win_for_buf(bufnr)
  if not win then
    return
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

-- Rejecting a hunk restores THE AGENT'S lines, and only those. Text the human
-- typed inside the hunk's live range while the review was open is theirs and
-- survives (operator ruling, 2026-08-19: "my edit stays").
--
-- Nothing in the product identifies "the human's text": the range holds
-- whatever is live, which may be neither `old_lines` nor `new_lines`. It is
-- separated here by a three-way read -- `new_lines` is what this range held
-- when the review opened, so diffing new_lines -> live isolates exactly what
-- the human did to it, and that delta is replayed onto `old_lines`.
--
-- Two shapes of delta are separable and neither loses a byte the human wrote:
--   * a pure ADD (count_a == 0) of lines the agent never proposed -- those
--     lines are the human's whole and entire, and they are kept around the
--     restored `old_lines` at the end they anchor to;
--   * a pure DELETE (count_b == 0) of the agent's own lines -- the human wrote
--     no text there, and rejecting withdraws those lines anyway.
-- Everything else is the collision CORE refuses BY NAME rather than merging:
-- a delta that both removes agent lines and adds text (the human rewrote the
-- very lines being rejected, so no line is wholly one author's), and an
-- insertion landing strictly BETWEEN agent lines (its position is defined only
-- inside the proposal being withdrawn). Those return nil plus a reason, so the
-- caller keeps BOTH versions and leaves the decision to the operator.
--
-- What this cannot distinguish: a human edit that reproduces the agent's own
-- proposal byte-for-byte (indistinguishable by construction, so it counts as
-- the agent's); which side authored a line the human rewrote in place (that is
-- the refusal, not a merge); and anything at all inside a pure-deletion hunk,
-- whose live range is empty by construction (#new_lines == 0) so no human text
-- can be attributed to it here.
local function reject_restoration(bufnr, block, start_line, end_line)
  local old_lines = block.old_lines or {}
  local new_lines = block.new_lines or {}
  local live = {}
  if end_line >= start_line then
    live = vim.api.nvim_buf_get_lines(bufnr, start_line - 1, end_line, false)
  end
  if lines_equal(live, new_lines) then
    -- Untouched by the human: the pre-ruling restoration, unchanged.
    return old_lines, nil
  end
  local function joined(lines)
    if #lines == 0 then
      return ""
    end
    return table.concat(lines, "\n") .. "\n"
  end
  local delta = vim.diff(joined(new_lines), joined(live), {
    algorithm = "histogram",
    result_type = "indices",
    ctxlen = 0,
  }) or {}
  local head, tail = {}, {}
  for _, hunk in ipairs(delta) do
    local start_a, count_a, start_b, count_b = unpack(hunk)
    if count_a > 0 and count_b > 0 then
      return nil, "the human rewrote the agent's own lines in this hunk"
    end
    local added = {}
    for i = start_b, start_b + count_b - 1 do
      added[#added + 1] = live[i]
    end
    if count_a > 0 then
      -- Pure delete of the agent's lines: nothing of the human's to carry.
    elseif start_a <= 0 then
      vim.list_extend(head, added)
    elseif start_a >= #new_lines then
      vim.list_extend(tail, added)
    else
      return nil, "the human's lines sit between the agent's own lines in this hunk"
    end
  end
  local out = {}
  vim.list_extend(out, head)
  vim.list_extend(out, old_lines)
  vim.list_extend(out, tail)
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
    if #replacement > 0 and replacement[#replacement] == "" then
      table.remove(replacement)
    end
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

--- Within the live authority range, paint only rows whose text matches the
--- hunk's own new_lines (earliest unclaimed row per line). Interior human
--- inserts become gaps between spans.
local function paint_spans_for_block(bufnr, block, start_line, end_line)
  if #block.new_lines == 0 then
    return {}
  end
  if end_line < start_line then
    return {}
  end
  local spans = {}
  local search_from = start_line
  for _, want in ipairs(block.new_lines) do
    local found = nil
    for r = search_from, end_line do
      local line = (vim.api.nvim_buf_get_lines(bufnr, r - 1, r, false) or {})[1]
      if line == want then
        found = r
        break
      end
    end
    if not found then
      -- SKIP, do not abort. A line the human has replaced is one line the
      -- product cannot claim; it is not a reason to stop claiming the rest of
      -- the hunk. Aborting here painted nothing for a hunk whose FIRST line had
      -- been edited even though its remaining lines were still the agent's,
      -- word for word — found by the property runner, which asked for
      -- [3,5,7,8] and got [5,7,8] after one `replace_inside`.
      --
      -- `search_from` is deliberately not advanced: nothing was consumed, so
      -- the next line of the hunk may legitimately match at the same row.
      goto continue
    end
    local last = spans[#spans]
    if last and last.last + 1 == found then
      last.last = found
    else
      spans[#spans + 1] = { first = found, last = found }
    end
    search_from = found + 1
    ::continue::
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
local function set_incoming_paint(bufnr, block, start_line, end_line)
  block.incoming_extmark_id = nil
  block.incoming_extmark_ids = nil
  if #block.new_lines == 0 then
    block.authority_lost = nil
    block.incoming_extmark_id = vim.api.nvim_buf_set_extmark(
      bufnr,
      NS,
      math.min(math.max(start_line - 1, 0), vim.api.nvim_buf_line_count(bufnr) - 1),
      0,
      {
        hl_group = EXT_HL.incoming,
        hl_eol = true,
        hl_mode = "combine",
        priority = INCOMING_PRIO,
        end_row = start_line - 1,
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
      math.min(math.max(span.first - 1, 0), line_count - 1),
      0,
      {
        hl_group = EXT_HL.incoming,
        hl_eol = true,
        hl_mode = "combine",
        priority = INCOMING_PRIO,
        end_row = span.last,
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
  vim.api.nvim_buf_clear_namespace(bufnr, NS, 0, -1)
  vim.api.nvim_buf_clear_namespace(bufnr, AUTH_NS, 0, -1)
  local max_col = vim.o.columns
  local line_count = vim.api.nvim_buf_line_count(bufnr)
  for _, block in ipairs(blocks) do
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
    block.delete_extmark_id = vim.api.nvim_buf_set_extmark(
      bufnr,
      NS,
      math.min(math.max(deleted_row, 0), line_count - 1),
      0,
      {
        virt_lines = deleted_virt,
        virt_lines_above = deleted_above,
        hl_eol = true,
        hl_mode = "combine",
        end_row = deleted_row,
        right_gravity = false,
        end_right_gravity = true,
      }
    )
    set_incoming_paint(bufnr, block, start_line, end_line_1)

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
  return false, (b ~= nil and tostring(b)) or (change and change.review_error) or "review did not open"
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
    notify_one_line("yana: inline review failed: " .. notify.error_headline(err), vim.log.levels.ERROR)
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

local function process_next_impl(st)
  if st.active or #st.queue == 0 then
    return nil
  end
  local item = table.remove(st.queue, 1)
  local change = item.change
  local ok, err = open_or_abandon(change, item.opts)
  if not ok then
    notify_one_line("yana: inline review failed: " .. notify.error_headline(err), vim.log.levels.ERROR)
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
  vim.schedule(function()
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
  st.active = nil
  queue_insert_original(st, parked_item)
  announce_state()

  local target_change = target_item and target_item.change
  if not target_change then
    return false
  end
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
        jump_to_block(active_state.bufnr, block)
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
    jump_to_block(bufnr, nearest_block(blocks, bufnr, direction))
    return
  end
  local at_edge = (direction == "next" and idx == #blocks)
    or (direction == "prev" and idx == 1)
  if not at_edge then
    jump_to_block(bufnr, nearest_block(blocks, bufnr, direction))
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
        -- SAID BEFORE IT HAPPENS, and durably: this is the one write in the
        -- product that lands on the real tree without an accept behind it.
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
    jump_to_block(state.bufnr, state.diff_blocks and state.diff_blocks[1])
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
--- was cleared. Rebuild hunks from the retained change so both versions stay
--- enumerable (CORE: "both versions are retained"; integration lab L26).
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
  if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  local staged = state.staged_text
  if type(staged) == "string" then
    break_undo_block(bufnr)
    pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, buffer_lines(staged))
    break_undo_block(bufnr)
    vim.bo[bufnr].modified = false
  end
  render_blocks(bufnr, state.diff_blocks, {
    site = "accept_refused_restore",
    model = state.model_hunks,
    model_source = state.model_source,
    change = change,
    opts = state.opts,
  })
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
            local aok, aerr, aapplied = state.opts.on_shadow_accept(change, nil)
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
            local aok, aerr, aapplied = state.opts.on_shadow_accept(change, composed)
            ok = aok == true
            err = aerr
            applied = aapplied
          end
        end
      end
      if ok then
        change.status = "accepted"
        ledger.mark(turn_log, "accept_applied")
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
      -- is theirs and survives the restoration (ruling 2026-08-19), separated
      -- by reject_restoration -- the same function reject_block_at calls, so
      -- the two paths cannot disagree about the same keystroke -- and the
      -- collision it cannot separate is REFUSED BY NAME below rather than
      -- merged, leaving both versions and the review open.
      --
      -- Last hunk first: each range is resolved immediately before its own
      -- replacement, so a line-count change in one hunk cannot shift a range
      -- already read for another.
      local blocks = state.diff_blocks or {}
      local kept, refusal = {}, nil
      for i = #blocks, 1, -1 do
        local block = blocks[i]
        local start_line, end_line, range_err = live_block_range(bufnr, block)
        if start_line then
          local restored, merge_err = reject_restoration(bufnr, block, start_line, end_line)
          if not restored then
            -- Refused, not resolved: this hunk stays in the review exactly as
            -- it is, with the human's text and the agent's both still present.
            table.insert(kept, 1, block)
            refusal = refusal or merge_err
          else
            -- The ruling's `u` is per HUNK, and this loop is the one place the
            -- engine rewrites several hunks without the operator touching the
            -- keyboard between them -- so it is the one place a boundary has to
            -- be asked for rather than inherited from the main loop's idle.
            -- The loop runs last hunk first (see above: ranges must be read
            -- immediately before their own replacement), so `u` walks the
            -- restorations back FIRST hunk first. There is no operator ordering
            -- to preserve here: reject-file is a single decision, and what the
            -- ruling asks for is that one press gives back one hunk.
            break_undo_block(bufnr)
            local pre_seq = buf_undo_seq(bufnr)
            local replaced = (end_line >= start_line) and (end_line - start_line + 1) or 0
            local restore_ok, restore_err = pcall(
              vim.api.nvim_buf_set_lines,
              bufnr,
              start_line - 1,
              end_line,
              false,
              restored
            )
            break_undo_block(bufnr)
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
                pre_seq = pre_seq,
                post_seq = buf_undo_seq(bufnr),
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
              if state.timeline_bulk_reject then
                local obs = tl_observe(bufnr)
                obs.regime = "buffer"
                tl_record(state, "hunk_rejected",
                  "reject hunk " .. tostring(block.model_index or i), obs)
                state.timeline_obs = obs
              end
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
      if ok and refusal then
        -- Reject-all refused for at least one hunk. Everything separable was
        -- restored; the rest is left for the operator to decide, so the review
        -- does NOT close and the turn is not "rejected". Nothing was written to
        -- the real tree here, which is what reject guarantees either way.
        state.diff_blocks = kept
        change.review_error = refusal
        change.status = "pending"
        ledger.record_decision(turn_log, {
          action = "review_refused",
          actor = "system",
          reason = "reject_would_discard_human_edit",
          detail = refusal,
          change_id = change.id,
          rel = change.rel or change.path,
        })
        local snap = diff.buffer_bytes_snapshot(bufnr)
        local on_disk = change.path and diff.read_file_bytes(change.path) or nil
        vim.bo[bufnr].modified = not (snap ~= nil and snap == on_disk)
        render_blocks(bufnr, state.diff_blocks, {
          site = "reject_refused",
          model = state.model_hunks,
          model_source = state.model_source,
          change = change,
          opts = state.opts,
        })
        notify_one_line(
          "yana: refused to reject "
            .. (#kept == 1 and "1 hunk" or (#kept .. " hunks"))
            .. " of "
            .. (change.rel or change.path)
            .. " -- "
            .. refusal
            .. "; both versions kept, the review stays open",
          vim.log.levels.WARN
        )
        announce_state()
        return false
      end
      if ok then
        -- Truthful modified flag: after a reject the buffer holds the human's
        -- text, and the file may already hold something else (a bare `:w`
        -- during the review persists the live composition). Clean only when
        -- buffer and file actually agree.
        local snap = diff.buffer_bytes_snapshot(bufnr)
        local on_disk = change.path and diff.read_file_bytes(change.path) or nil
        vim.bo[bufnr].modified = not (snap ~= nil and snap == on_disk)
        change.status = "rejected"
        -- Reject completed once the buffer is restored. on_reject failure is
        -- presentation only — same rule as accept: do not undo a durable action.
        notify_owner(state.opts.on_reject, change, "on_reject")
      end
    end
    if not ok then
      change.review_error = tostring(err or (accepted and "accept failed" or "reject failed"))
      if accepted then
        ledger.record_decision(turn_log, {
          action = "review_refused",
          actor = "system",
          reason = "shadow_accept_failed",
          detail = tostring(err),
          change_id = change.id,
          rel = change.rel or change.path,
        })
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
        change.status = "pending"
        notify_one_line(
          "yana: shadow accept failed for " .. (change.rel or change.path) .. ": " .. tostring(err),
          vim.log.levels.ERROR
        )
        restore_agent_proposal_after_refusal(state)
        if #state.diff_blocks > 0 then
          announce_state()
          schedule_queue_advance(state)
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
  local function absorb_human_edits(changes)
    for _, block in ipairs(state.diff_blocks or {}) do
      local start_line, end_line = live_block_range(bufnr, block)
      local extends_block = false
      local extra_lines = 0
      for _, change in ipairs(changes) do
        -- `first` names the first old buffer row that changed. A newline
        -- entered on the hunk's last row therefore belongs to that hunk;
        -- typing on the following row does not.
        if start_line and change.first >= start_line - 1 and change.first <= end_line then
          extends_block = true
          extra_lines = extra_lines + math.max(0, change.last_new - change.last_orig)
        end
      end
      if start_line and extends_block then
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
        end
      end
    end
  end
  state.watch_pending = false
  state.watch_detached = false
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function(_, _, _, first, last_orig, last_new)
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
      if state.watch_detached or state.closed or not state.diff_blocks or #state.diff_blocks == 0 then
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
      -- the reentrancy entirely.
      if state.watch_pending then
        return
      end
      state.watch_pending = true
      vim.schedule(function()
        state.watch_pending = false
        local changes = state.watch_changes or {}
        state.watch_changes = {}
        if state.watch_detached or state.closed then
          return
        end
        if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
          return
        end
        if not state.diff_blocks or #state.diff_blocks == 0 then
          return
        end
        absorb_human_edits(changes)
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
      end)
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
    local retrace_ok, retrace = pcall(require, "yana.timeline.retrace")
    if retrace_ok and retrace.install_post_review_keys then
      retrace.install_post_review_keys(bufnr)
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
      notify_one_line("yana: could not open review buffer: " .. open_err_text, vim.log.levels.WARN)
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
  local target = model_target(change)
  -- Model FIRST, blocks second, join last: the model must not be able to
  -- inherit anything from the block list.
  local model, model_source = payload_model(change, target)
  local parked = change._parked_review
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
    -- See `open_review_buffer`'s own "RETRACE REINTEGRATION FAST PATH"
    -- comment: when that fast path fired, the buffer was returned WITHOUT
    -- being staged, and it already holds exactly `target` -- writing
    -- `blocks` into it here would be the SAME phantom undo-tree entry that
    -- fast path exists to avoid, on top of overwriting content that is
    -- already correct. `highlight_blocks` alone still paints correctly:
    -- `blocks`' positions were computed against `target`, which IS the
    -- buffer's current content in this path.
    if not change._retrace_reintegration then
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
    ledger.bump(L, "reviews_opened")
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

  local maps = config.options.diff_keymaps or {}
  local keys = {
    maps.ours or "co",
    maps.theirs or "ct",
    maps.all_theirs or "ca",
    maps.all_changes or "cA",
    maps.both or "cb",
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
  }
  ledger.mark(change_ledger(change, opts), "review_profile_state_allocated")
  stamp_review_workspace(change, opts)
  ledger.mark(change_ledger(change, opts), "review_profile_workspace_stamped")
  -- Watch the buffer from here on: every later repaint re-derives which rows
  -- are the agent's, and this is what gives it a reason to run when the human
  -- types rather than only when a decision is taken.
  attach_buffer_watch(state)
  ledger.mark(change_ledger(change, opts), "review_profile_buffer_watched")
  local st = pool_for(opts or {})
  st.active = state
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
    local full_hint = string.format(
      "[%s: OURS, %s: THEIRS, %s: ALL, %s: ALL FILES, %s: ABORT, %s: PREV, %s: NEXT]",
      maps.ours or "co",
      maps.theirs or "ct",
      maps.all_theirs or "ca",
      maps.all_changes or "cA",
      maps.both or "cb",
      maps.prev or "[x",
      maps.next or "]x"
    )
    local compact_hint = string.format(
      "[%s accept · %s reject · %s/%s hunks]",
      maps.theirs or "ct",
      maps.ours or "co",
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
      local reload_unload_token = nil
      if buf_now ~= nil and state.staged_text ~= nil and buf_now ~= state.staged_text then
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
        local st = pool_for_state(state)
        if st.active ~= state then
          return
        end
        local function tear_down(reason, fp)
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
        local staged = state.staged_text
        if disk_now == base then
          -- Tier 1: an identical-content reload may still have replaced the
          -- buffer with base bytes. Restore the review composition first, then
          -- rebuild extmarks; rebuilding over reloaded base bytes is unsafe.
          if staged then
            local buf_now, buf_err = diff.buffer_bytes_snapshot(bufnr)
            if buf_now == nil then
              return tear_down(buf_err or "review buffer is not text-safe after reload")
            end
            if buf_now ~= staged then
              break_undo_block(bufnr)
              vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(staged))
              break_undo_block(bufnr)
              vim.bo[bufnr].modified = false
            end
          end
          render_blocks(bufnr, state.diff_blocks, {
            site = "reload_identical",
            model = state.model_hunks,
            model_source = state.model_source,
            change = change,
            opts = state.opts,
          })
          return
        end
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
        -- Tier 2: outside-hunk disk edits are kept. The file's base evidence is
        -- advanced before accept, otherwise the later CAS would refuse a merge
        -- that this handler has already validated and staged.
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
          site = "reload_composed",
          model = state.model_hunks,
          model_source = state.model_source,
          change = change,
          opts = state.opts,
        })
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


  local function reject_block_at(idx)
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
    -- The human's text inside this hunk survives the restoration; the case it
    -- cannot be separated from the agent's is refused by name, with both
    -- versions left in place and this hunk still in the review. Identical to
    -- what finish_session's reject-all does for the same edit.
    local restored, merge_err = reject_restoration(bufnr, block, start_line, end_line)
    if not restored then
      change.review_error = merge_err
      record_decision(state, "reject_hunk_refused", {
        hunk = idx,
        model_index = block.model_index,
        row = start_line,
        reason = "reject_would_discard_human_edit",
        detail = merge_err,
      })
      notify_one_line(
        "yana: refused to reject hunk " .. idx .. " -- " .. merge_err
          .. "; both versions kept, the review stays open",
        vim.log.levels.WARN
      )
      return
    end
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
    -- Was anything ALREADY unaccounted-for dirty before this decision's own
    -- edit? Captured before the write below so the answer is about the
    -- buffer this reject inherited, not the one it is about to leave.
    local pre_dirty = vim.bo[bufnr].modified
    vim.api.nvim_buf_set_lines(bufnr, start_line - 1, end_line, false, restored)
    break_undo_block(bufnr)
    -- `nvim_buf_set_lines` unconditionally marks the buffer modified, unlike
    -- accept (CORE: "accept moves no bytes", so it never dirties the buffer
    -- at all). Nothing downstream of a per-hunk reject ever clears that flag
    -- -- bulk reject-all and accept-all both compute a truthful one in
    -- finish_session, but this per-hunk path (`co` on one hunk, leaving
    -- siblings pending) returns straight to the still-open review. Left
    -- alone, `modified` stays wrongly true for the rest of the review,
    -- including any later `]x`/`[x` park+reopen, and open_review_buffer's
    -- unsaved-edits guard reads that stale bit and refuses the reopen even
    -- though the buffer holds nothing but this review's own decided and
    -- still-pending hunks (MEASURED 2026-08-21, FIX-NAV lane: reject one
    -- hunk, leave a sibling pending, `]x` away, `[x` back misfired
    -- "buffer has unsaved edits unrelated to this review"). Reset only what
    -- THIS decision dirtied: if the buffer was already carrying an
    -- unaccounted-for edit before this reject ran, that edit is still there
    -- afterward and the flag must keep saying so.
    if not pre_dirty then
      vim.bo[bufnr].modified = false
    end
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
    do
      local obs = tl_observe(bufnr)
      obs.regime = "buffer"
      tl_record(state, "hunk_rejected",
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
    end
    render_blocks(bufnr, state.diff_blocks, {
      site = "reject_hunk",
      model = state.model_hunks,
      model_source = state.model_source,
      change = change,
      opts = state.opts,
    })
    jump_to_block(bufnr, nearest_block(state.diff_blocks, bufnr, "next"))
    try_finalize(state)
  end

  local function accept_block_at(idx)
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
    do
      local obs = tl_observe(bufnr)
      obs.regime = "buffer"
      tl_record(state, "hunk_accepted",
        "accept hunk " .. tostring(block.model_index or idx), obs)
      state.timeline_obs = obs
    end
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
    jump_to_block(bufnr, nearest_block(state.diff_blocks, bufnr, "next"))
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

  local function accept_all()
    tl_capture_human_edit(state)
    record_decision(state, "accept_file", { hunks_remaining = #state.diff_blocks })
    local obs = tl_observe(bufnr)
    obs.regime = "buffer"
    for i, block in ipairs(state.diff_blocks) do
      tl_record(state, "hunk_accepted", "accept hunk " .. tostring(block.model_index or i), obs)
    end
    state.timeline_obs = obs
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
    render_blocks(bufnr, state.diff_blocks, {
      site = site,
      model = state.model_hunks,
      model_source = state.model_source,
      change = change,
      opts = state.opts,
    })
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

  --- `<C-r>` inside an open review. It was not mapped at all, so redo moved the
  --- buffer with the review none the wiser and the disagreement surfaced only
  --- when the next decision was attempted. Redo stays the editor's own
  --- operation — nothing here refuses it or rewrites it — but the review
  --- repaints afterwards so what is on screen still describes what is in the
  --- buffer.
  local function redo_key()
    -- RULING 52 FIRST, and it is a LIFO question rather than a special case:
    -- the last thing `U` did was sweep the turn, so the first thing redo owes
    -- is that sweep's staged removals. Only once they are back does redo mean
    -- what it has always meant inside this review.
    if M._redo_staged_restores(state) then
      return
    end
    local stack = state.undone_decisions or {}
    local top = stack[#stack]
    local before = buf_undo_seq(bufnr)
    -- Is the newest thing in this buffer's history a decision this review took
    -- back? Only then does redo owe the review anything. Any other redo -- of
    -- the operator's own typing, say -- is the editor's own operation and is
    -- passed straight through, exactly as `u` does in the mirror case.
    local owed = top ~= nil and before ~= nil and top.pre_seq == before
    -- REINTEGRATION REDO PRIORITY (FIX-UNDO lane, this session), decided
    -- BEFORE trying native `:redo` at all -- unlike a genuine review, a
    -- reintegrated one's buffer IS the exact same tree retrace's own
    -- cross-file bookkeeping already walked backward through. Trying
    -- native `:redo` first (the code below does, for every other review)
    -- can succeed on its own -- Neovim's tree genuinely has forward states
    -- retrace's own earlier `:undo` calls put there -- which moves the
    -- buffer WITHOUT retrace's redo_stack popping or its own
    -- `sync_buffer_head` bookkeeping updating. The two mechanisms then
    -- disagree about where the buffer is, and retrace's NEXT press pops an
    -- entry for a position the buffer has already passed, re-issuing a
    -- `:redo` that lands nowhere new -- measured 2026-08-21: exactly this,
    -- as duplicate "redid hunk_accepted" presses that never reached b.py's
    -- own entries at all. Going straight to retrace when nothing is
    -- locally owed keeps ONE mechanism moving this buffer, never two.
    if not owed and change._retrace_reintegration then
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
    end
    if not owed and state.reload_redo_guard and before == state.reload_restore_seq then
      undo_refuse("redo cannot reapply the transient buffer state used by reload")
      rerender_after_history_move("native_redo")
      return
    end
    if before ~= state.reload_restore_seq then
      state.reload_redo_guard = nil
      state.reload_restore_seq = nil
    end

    -- Accepting a hunk moves no buffer bytes, so taking that decision back
    -- creates no matching Neovim redo step. Restore only the review decision;
    -- consuming the editor's next redo here would replay an unrelated human
    -- edit and make the two histories disagree.
    local after = before
    if not (owed and top.action == "accept") then
      local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent redo")
      end)
      if not ok then
        log.write("WARN", "yana.inline_diff redo: " .. tostring(err))
        rerender_after_history_move("native_redo")
        return
      end
      after = buf_undo_seq(bufnr)
    end

    if not owed and after == before then
      -- A reintegrated review already tried retrace's own cross-file redo
      -- BEFORE native `:redo` ran at all (see the check above, right after
      -- `owed` -- this is the general refusal for a GENUINE review, whose
      -- staging boundary is real and must not be reached past).
      undo_refuse("there is no newer buffer state to redo inside this review")
      rerender_after_history_move("native_redo")
      return
    end

    if owed then
      if after ~= top.post_seq then
        -- The redo went somewhere other than the state this decision produced,
        -- so re-applying the decision would describe bytes that are not there.
        -- Put the buffer back and refuse: BOTH owners unchanged is the contract,
        -- and a redo that moved one of them is the defect being fixed.
        pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("silent undo " .. tonumber(before))
        end)
        undo_refuse("redo no longer matches the decision it would put back")
        return
      end
      local redo_start, redo_end = live_block_range(bufnr, top.block)
      if not redo_start then
        pcall(vim.api.nvim_buf_call, bufnr, function()
          vim.cmd("silent undo " .. tonumber(before))
        end)
        undo_refuse("redo cannot recover that decision's hunk position")
        return
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
      local ok = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent undo " .. tonumber(top.pre_seq))
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
        -- REINTEGRATION FLOOR EXCEPTION (FIX-UNDO lane, this session). The
        -- refusal above protects a GENUINE agent turn's staging boundary --
        -- real bytes retrace cannot see past. A review retrace itself
        -- reintegrated (`change._retrace_reintegration`) staged nothing:
        -- `open_review_buffer`'s own fast path left the buffer exactly as
        -- it was, so there is no staging step here to strip a proposal out
        -- of. Once cross-file retrace ALSO has nothing left, the correct
        -- floor for a reintegrated review is the SAME one the post-review
        -- hook (`on_u_key`) already falls through to: plain Neovim undo,
        -- reaching whatever real history sits below where this reintegration
        -- opened. Measured 2026-08-21: without this, the undo-survives-a-reload
        -- row's case got stuck refusing the instant its
        -- own first reintegration opened -- the operator's own further `u`
        -- presses toward the true pre-turn buffer went nowhere.
        if change._retrace_reintegration then
          return native_undo()
        end
        undo_refuse("that is as far back as undo goes inside this review")
        return
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
      local ok = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent undo " .. tonumber(state.undo_open_seq))
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
    -- BufWriteCmd on the review buffer: human :w must reach disk (CORE); product
    -- saves use `noautocmd write!` (diff.save_buffer) and bypass this handler.
    -- Bare :w persists the live review composition and advances disk_at_open;
    -- :w! still accepts all; :w other copies without touching the reviewed file.
    vim.api.nvim_create_autocmd("BufWriteCmd", {
      buffer = bufnr,
      group = state.augroup,
      callback = function()
       log.guard("yana.inline_diff BufWriteCmd", function()
        -- <amatch> is the write's actual target (the argument to `:w`, or
        -- the buffer's own name for a bare `:w`) — resolve it before
        -- deciding whether this is a write to the reviewed file itself.
        local target = vim.fn.expand("<amatch>")
        local own = diff.abs_path(vim.api.nvim_buf_get_name(bufnr))
        if target ~= "" then
          target = diff.abs_path(target)
        end
        if target ~= "" and target ~= own then
          -- A write to a DIFFERENT path never touches the reviewed file, so
          -- it cannot violate the invariant that disk keeps the agent's
          -- `after` until accept/reject — let it through as a plain copy.
          -- `noautocmd` mirrors diff.save_buffer's own writes and keeps this
          -- same handler from re-firing on itself.
          local wcmd = (vim.v.cmdbang == 1) and "noautocmd write!" or "noautocmd write"
          local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
            vim.cmd(wcmd .. " " .. vim.fn.fnameescape(target))
          end)
          if not ok then
            notify_one_line("yana: could not write copy to " .. target .. ": " .. tostring(err), vim.log.levels.WARN)
            return
          end
          -- The copy holds the buffer's mid-review state (some hunks
          -- resolved, some not) — that is literally what `:w other` asked
          -- for, but surprising enough to call out explicitly.
          notify_one_line(
            "yana: wrote copy to " .. target
              .. " with in-progress review state — " .. (change.rel or change.path) .. " itself is untouched",
            vim.log.levels.WARN
          )
          return
        end
        if vim.v.cmdbang == 1 then
          -- :w! — explicit override: resolve everything as accepted.
          accept_all()
          return
        end
        -- Bare :w on the reviewed file: CORE requires human saves never be
        -- blocked. The buffer holds the live review composition; persist it
        -- and advance the disk anchor so later accept sees the human's edit as
        -- drift rather than silently swallowing the write (integration lab L25).
        local snap, snap_err = diff.buffer_bytes_snapshot(bufnr)
        if snap == nil then
          notify_one_line(
            "yana: could not save " .. (change.rel or change.path) .. ": " .. tostring(snap_err),
            vim.log.levels.ERROR
          )
          return
        end
        local ok, err = diff.save_buffer(bufnr)
        if not ok then
          notify_one_line(
            "yana: could not save " .. (change.rel or change.path) .. ": " .. tostring(err),
            vim.log.levels.ERROR
          )
          return
        end
        change.disk_at_open = snap
        state.staged_text = snap
        state.latest_undo_seq = buf_undo_seq(bufnr)
        return
      end)
      end,
    })
  end

  local function reject_all()
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
    state.timeline_bulk_reject = true
    local ok = finish_session(state, false)
    state.timeline_bulk_reject = nil
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
        return nil, nil
      end
      local staged = parked.staged_text
      local b = vim.fn.bufnr(change_i.path, false)
      if b > 0 and vim.api.nvim_buf_is_loaded(b) then
        local live = diff.buffer_bytes_snapshot(b)
        if live ~= nil then
          if staged ~= nil and not diff.text_equal_snapshot(live, staged) then
            return nil, "the parked review buffer was edited after it was parked"
          end
          return live, nil
        end
      end
      if staged == nil then
        return nil, "the parked review kept no staged content to accept"
      end
      return staged, nil
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
      local parked_text, parked_err = parked_composition(change_i)
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
        local aok, aerr, applied_i = item.opts.on_shadow_accept(change_i, composed_i)
        if aok == true then
          change_i.status = "accepted"
          -- The park is over: nothing may reopen this review from the parked
          -- staging once its bytes are on disk.
          change_i._parked_review = nil
          change_i._parked_item = nil
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
          else
            local warn = "yana: "
              .. (change_i.rel or path)
              .. " was accepted without ever being opened, but no journaled op id came back -- "
              .. "undo will not be able to reach it; the write itself still happened"
            log.write("WARN", warn)
            notify_one_line(warn, vim.log.levels.WARN)
          end
        else
          change_i.review_error = tostring(aerr or "shadow accept failed")
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

  M._test = {
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
    vim.keymap.set({ "n", "v" }, maps.ours or "co", guarded("yana.inline_diff reject_hunk", reject_hunk), vim.tbl_extend("force", km, { desc = "yana: reject hunk (ours)" }))
    vim.keymap.set({ "n", "v" }, maps.theirs or "ct", guarded("yana.inline_diff accept_hunk", accept_hunk), vim.tbl_extend("force", km, { desc = "yana: accept hunk (theirs)" }))
    vim.keymap.set({ "n", "v" }, maps.all_theirs or "ca", guarded("yana.inline_diff accept_all", accept_all), vim.tbl_extend("force", km, { desc = "yana: accept all hunks" }))
    vim.keymap.set({ "n", "v" }, maps.all_changes or "cA", guarded("yana.inline_diff accept_everything", accept_everything), vim.tbl_extend("force", km, { desc = "yana: accept ALL changes (whole turn)" }))
    vim.keymap.set({ "n", "v" }, maps.both or "cb", guarded("yana.inline_diff reject_all", reject_all), vim.tbl_extend("force", km, { desc = "yana: reject file" }))
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
      jump_to_block(bufnr, state.diff_blocks[1])
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
      jump_to_block(bufnr, state.diff_blocks[1])
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
        maps.theirs or "ct",
        maps.ours or "co"
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
  if st.active then
    pcall(M.cleanup, st.active)
    st.active = nil
  end
  st.queue = {}
  st.batched = {}
  st.order = {}
  st.order_seq = 0
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
    notify_one_line("yana: inline review failed: " .. notify.error_headline(err), vim.log.levels.ERROR)
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
  focus_buf(st.active.change.path, st.active.bufnr)
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

--- Abort the open review: put the buffer back to the file as it was BEFORE any
--- hunk appeared, and close the review in the same act.
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
--- first, then the buffer is moved in ONE jump to the pre-staging bookmark, then
--- the review is closed and its marks and keymaps released. At no point is
--- there a buffer without a review or a review without its buffer.
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
--- Recoverable: the jump is `:undo {seq}`, so `<C-r>` still reaches the
--- proposal until the tree is otherwise disturbed.
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

  local ok = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("silent undo " .. tonumber(state.undo_pre_stage_seq))
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
  finish_session(state, false)
  notify_one_line("yana: review aborted — the file is back as it was before the hunks", vim.log.levels.INFO)
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
M._test.pools = pools
M._test.pool_for = pool_for
M._test.discard_pool = M.discard_pool
M._test.discard_for_owner = M.discard_for_owner
M._test.process_next = M.process_next
M._test.owners_match = owners_match

return M
