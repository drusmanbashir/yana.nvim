-- Per-tab review controls. The strip is SIDEBAR CHROME: it belongs to the
-- panel, is split between that panel's conversation and prompt, and its
-- existence has exactly ONE condition -- a live Turn for the panel's pool
-- (`turn_start` attaches, `turn_end` removes). Sidebar toggle, resize, tab
-- mirroring, park/resume, review close and a zero pending count never remove
-- it; no pending work only DIMS buttons (F-BUTTON-STRIP).
--
-- THE HEIGHT RULE, recorded once (design 2026-09-06, adversary round 2).
--
--  1. BUDGETING IS AN OPEN-TIME EVENT. The strip pays for itself once, out of
--     its own panel's named donors, and after that the column belongs to the
--     operator. No resize event ever re-splits the column again. (It used to,
--     from the pane weights frozen at open, and a bare `doautocmd VimResized`
--     therefore discarded an operator's own conversation/prompt split.)
--  2. ITS HEIGHT IS WHAT IT PAINTS: clamp(rendered lines, min_height,
--     max_height), always. A by-hand drag of the strip's own divider is not
--     honoured -- the next refresh puts the strip back on its render.
--  3. WHEN ITS OWN HEIGHT MUST CHANGE the delta is exchanged with the ANCHOR
--     window directly above it, the conversation the `belowright split` was
--     cut from, and with nobody else; every other window in the column is
--     pinned at the height the operator left it (`exchange_with_anchor`).
--  4. THE ONE THING RESTORED AFTER AN OUTSIDE RESIZE is the panes' RATIOS,
--     and only when the column's TOTAL changed -- Neovim redistributes those
--     rows as it likes and the other panes keep their ratios across
--     resize/relayout. The ratios restored are the ones
--     the panes had before that event, never the open-time weights
--     (`keep_pane_ratios`).
--
-- The budget REFUSAL (donors cannot pay -> the strip does not open) and the
-- retry augroup are unchanged by all of this.
local config = require("yana.config")
local notify = require("yana.notify")
local log = require("yana.log")
local grid = require("yana.ui_grid")
local views = require("yana.ui_panel_views")
local M = {}
local MIN_CONV, FLASH_MS = 3, 38
local HL = { live = "YanaReviewBtn", dim = "YanaReviewBtnDim", hover = "YanaReviewBtnHover", flash = "YanaReviewBtnFlash", marked = "YanaReviewBtnMarked", key = "YanaReviewBtnKey" }
local STRIP_MAP_DESC = { ["<LeftMouse>"] = "yana: review button press", ["<LeftRelease>"] = "yana: review button release", ["<MouseMove>"] = "yana: review button hover" }
for name, spec in pairs({ YanaReviewBtn = { default = true, link = "Pmenu" }, YanaReviewBtnDim = { default = true, link = "Comment" }, YanaReviewBtnHover = { default = true, link = "PmenuSel" }, YanaReviewBtnFlash = { default = true, link = "IncSearch" }, YanaReviewBtnMarked = { default = true, underline = true, sp = "Orange" }, YanaReviewBtnKey = { default = true, link = "Special" } }) do pcall(vim.api.nvim_set_hl, 0, name, spec) end

-- ONE strip per (pool, tab). The strip is the sidebar's chrome for a live
-- Turn, and a Turn belongs to a POOL (keyed by workspace), not to a panel, so
-- two panels stacked in one tab share the one strip. A second strip would have
-- to be paid for by the second panel's own conversation, and F-STRIP-BUDGET
-- says a sibling panel never yields a row -- an operator-named constraint that
-- outranks any symmetry argument. `.panel` is the HOST: the view the strip is
-- split under and the only one that donates.
local strips = {}
local function entry_for_pool(pool, tab) for _, e in ipairs(strips) do if e.pool == pool and e.tab == tab then return e end end end
local function entry_for(panel, tab) for _, e in ipairs(strips) do if e.panel == panel and e.tab == tab then return e end end end
local function entries_in_tab(tab) local out = {}; for _, e in ipairs(strips) do if e.tab == tab then out[#out + 1] = e end end; return out end
local function all_entries() local out = {}; for _, e in ipairs(strips) do out[#out + 1] = e end; return out end
local function forget(e) for i, x in ipairs(strips) do if x == e then table.remove(strips, i); return end end end
local function valid_win(w) return type(w) == "number" and w > 0 and vim.api.nvim_win_is_valid(w) end
local function valid_buf(b) return type(b) == "number" and b > 0 and vim.api.nvim_buf_is_valid(b) end
local function valid_tab(t) return type(t) == "number" and vim.api.nvim_tabpage_is_valid(t) end
local function cfg() return config.options.ui.review_buttons end
-- ui.review_buttons has no normalizer, so a non-numeric operator value falls back
-- to the shipped default rather than to a second copy of it.
local function min_h() return math.max(1, tonumber(cfg().min_height) or config.defaults.ui.review_buttons.min_height) end
local function max_h() return math.max(1, tonumber(cfg().max_height) or config.defaults.ui.review_buttons.max_height) end
local function maps() return config.options.mappings end

local function review_win(state, tab)
  if not (state and valid_buf(state.bufnr)) then return nil end
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(tab or 0)) do if valid_win(w) and vim.api.nvim_win_get_buf(w) == state.bufnr then return w end end
end
-- THE LEDGER IS THE ONE THING A BUTTON READS THAT CAN THROW. Every button's
-- liveness comes from `hunk_ledger`, and a ledger corrupted by any upstream
-- defect raises on `pending()`/`count()`. Nothing about the strip's EXISTENCE
-- depends on that (the ruling's one condition is a live Turn), so the read is
-- contained here, once, the way `guarded_open` contains an open-time failure:
-- the error is counted and logged, the operator is told ONCE per session, and
-- the caller gets nil -- which renders every button DIM instead of throwing a
-- traceback out of a CursorMoved autocmd on every cursor move, or out of a
-- button press. `where` names the event so the log line is the one the
-- operator can grep for.
local ledger_errors, ledger_notified = { refresh = 0, press = 0 }, false
local function ledger_call(where, fn)
  -- MUTATION ONLY: the uncontained read, straight through to the caller.
  if M._test.uncontained then return fn() end
  -- OPEN TIME IS NOT THIS SEAM'S. This seam exists for the two events the
  -- ruling names -- a CursorMoved refresh and a button press -- where a
  -- traceback would land in the operator's face on every keystroke. The
  -- open-time read has its own owner: `guarded_open` counts it
  -- (`review.strip_open_error`), tells the operator "strip failed to open"
  -- once, and returns false to the caller. Containing it HERE instead would
  -- swallow that report and hand back a strip whose open really failed.
  if where == "open" then return fn() end
  local ok, res = xpcall(fn, debug.traceback)
  if ok then return res end
  local slot = where == "press" and "press" or "refresh"
  ledger_errors[slot] = ledger_errors[slot] + 1
  log.lifecycle_later(where == "press" and "review.strip_press_error" or "review.strip_refresh_error",
    { err = tostring(res):gsub("%s+", " "):sub(1, 400), count = ledger_errors[slot] })
  if not ledger_notified then
    ledger_notified = true
    -- SCHEDULED: this runs inside a CursorMoved autocmd, where a notify of
    -- its own throws (`Vim(append)`) -- containment that raises its own error
    -- at the operator is not containment.
    vim.schedule(function() notify.one_line("yana: review buttons — the review ledger could not be read; the buttons are dim (see :YanaLog review.strip_refresh_error)", vim.log.levels.ERROR) end)
  end
  return nil
end
local function hunk_index(state, tab, where)
  if not (state and state.hunk_ledger and valid_buf(state.bufnr)) then return nil end
  local w = review_win(state, tab); if not w then return nil end
  local cursor = vim.api.nvim_win_get_cursor(w)[1]
  local blocks = ledger_call(where, function() return state.hunk_ledger:pending() end)
  -- SECOND RETURN: "unreadable", which is not the same fact as "the cursor is
  -- in no hunk". A caller that cannot tell them apart leaves the file-wide
  -- buttons live over a ledger nobody can read.
  if type(blocks) ~= "table" then return nil, true end
  for idx, block in ipairs(blocks) do
    local ok, a, b, err, collapsed = false, nil, nil, nil, false
    if not block.authority_lost then ok, a, b, err, collapsed = pcall(require("yana.inline_diff").live_block_range, state.bufnr, block) end
    if ok and a and not err and not collapsed and not block.authority_lost then
      b = #(block.new_lines or {}) == 0 and a - 1 or math.max(b, a)
      if cursor >= a and cursor <= b then return idx end
    elseif not block.authority_extmark_id and not block.authority_lost then
      -- SEQUENCED, never `a, b = ...`: Lua evaluates the whole right-hand
      -- side of a multiple assignment before assigning any of it, so an `a`
      -- read inside math.max would still be the pre-assignment value -- nil
      -- on every path that reaches this branch -- and throw `bad argument #2
      -- to 'max'` into a caller that pcalls M.open: no strip, no error.
      a = block.new_start_line or 0
      b = #(block.new_lines or {}) == 0 and a - 1 or math.max(block.new_end_line or a, a)
      if cursor >= a and cursor <= b then return idx end
    end
  end
end
-- nil, never 0, when the ledger cannot be read: a dim strip and an EMPTY one
-- are different facts and the callers each decide what to do with "unknown".
local function pending_count(state, where)
  if not (state and state.hunk_ledger) then return 0 end
  return ledger_call(where, function() return state.hunk_ledger:count("pending") end)
end
-- `state` is `pool.active` READ AT RENDER TIME and is legitimately nil while
-- the Turn is live with nothing open (parked, or between files): the strip
-- stays, every button dims.
local function button_list(state, tab, where)
  -- ONE ledger read per event: when the count cannot be read the blocks
  -- cannot either, and a second attempt would only log the same failure twice.
  local m = maps()
  local pending = pending_count(state, where)
  local idx, unreadable = hunk_index(state, tab, where)
  local readable = pending ~= nil and not unreadable
  local inside = readable and idx ~= nil
  -- An unreadable ledger dims EVERY button, the file-wide ones included: with
  -- no idea what is pending, no press can be honoured.
  local has = state ~= nil and readable
  pending = pending or 0
  return {
    { action = "accept_file", key = m.accept_file, label = "accept file", short = "acc file", live = has },
    { action = "accept_all", key = m.accept_all, label = "accept all", short = "acc all", live = has },
    { action = "reject_file", key = m.reject_file, label = "reject file", short = "rej file", live = has },
    { action = "abort", key = "cR", label = "abort review", short = "abort", live = has },
    { action = "next", key = m.next_hunk, label = "next hunk", short = "next", live = readable and pending > 0 },
    { action = "prev", key = m.prev_hunk, label = "prev hunk", short = "prev", live = readable and pending > 0 },
    { action = "accept_hunk", key = m.accept_hunk, label = "accept hunk", short = "acc hunk", live = inside },
    { action = "reject_hunk", key = m.reject_hunk, label = "reject hunk", short = "rej hunk", live = inside },
  }
end
M.button_list = button_list

local function button_rows(defs, pick, e)
  local row = {}
  for _, d in ipairs(defs) do
    local text = " " .. d.key .. " " .. pick(d) .. " "
    row[#row + 1] = { text = text, key = d.key, action = d.action, live = d.live, dim = not d.live, key_offset = 1, key_width = vim.fn.strdisplaywidth(d.key), flash = e and ((e.armed_action == d.action) or (e.flash_until and (vim.uv or vim.loop).now() < e.flash_until and e.flash_action == d.action)) or false }
  end
  return { row }
end
local function render_layout(defs, width, pick)
  return grid.layout(button_rows(defs, pick), { layout = "flow", width = width })
end
function M.render(ctx)
  ctx = ctx or {}
  -- ONE renderer: the strip's grid and this measurement pass ask the same
  -- `button_list` with the same (possibly nil) review, so what is measured is
  -- what is painted. A nil review dims every button; it never fabricates a
  -- synthetic state that reported the file buttons live.
  local defs = button_list(ctx.state, ctx.tab, ctx.where)
  local width = math.max(20, tonumber(ctx.width) or 40)
  local lines, spans = render_layout(defs, width, function(d) return d.label end)
  local compact, cspans = render_layout(defs, width, function(d) return d.short or d.label end)
  if #compact < #lines then lines, spans = compact, cspans end
  return grid.fit(lines, spans, math.max(1, tonumber(ctx.max_height) or max_h()))
end

-- Donors are named by OWNERSHIP, never by geometry. Sharing the reviewed
-- pane's column and width is NOT evidence of belonging to its panel: a
-- sidebar stacks several panels in one column, and inferring donors from
-- shared geometry made a review in one panel steal rows from its siblings.
-- A window is this panel's iff it is `views.conv`/`views.prompt`, the review
-- anchor, or shows one of THIS panel's two buffers (an operator's own split
-- of the conversation pane). Any window displaying a yana panel buffer that
-- is not ours belongs to another panel and is never a donor.
local function owned_win(entry, w, own_bufs)
  if w == entry.anchor_win or w == views.conv(entry.panel, entry.tab) or w == views.prompt(entry.panel, entry.tab) then return true end
  local ok, buf = pcall(vim.api.nvim_win_get_buf, w)
  if not ok then return false end
  if own_bufs[buf] then return true end
  local got, mine = pcall(function() return vim.b[buf].yana_panel end)
  return got and not mine
end
local function panel_wins(entry, skip)
  local ref = entry.anchor_win and vim.fn.getwininfo(entry.anchor_win)[1]; if not ref then return {} end
  local own_bufs = {}
  for _, b in ipairs({ entry.panel.conv_buf, entry.panel.prompt_buf }) do if valid_buf(b) then own_bufs[b] = true end end
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(entry.tab)) do
    local wi = vim.fn.getwininfo(w)[1]
    if valid_win(w) and w ~= skip and wi and wi.wincol == ref.wincol and wi.width == ref.width and owned_win(entry, w, own_bufs) then
      out[#out + 1] = { win = w, height = wi.height, top = wi.winrow, min = 1 }
    end
  end
  table.sort(out, function(a, b) return a.top < b.top end); return out
end
-- Every window sharing the reviewed pane's column, donors and bystanders
-- alike. The donor SET is decided by ownership (panel_wins); this snapshot
-- exists so the bystanders' heights can be PINNED across the split. A
-- `belowright split` costs the column one row beyond the strip's own content
-- (the new window's statusline), and until that row was budgeted Neovim
-- charged it to whichever neighbour it liked -- in a stacked sidebar, another
-- panel's conversation pane.
local function column_snapshot(entry)
  local ref = entry.anchor_win and vim.fn.getwininfo(entry.anchor_win)[1]; if not ref then return {} end
  local out = {}
  for _, w in ipairs(vim.api.nvim_tabpage_list_wins(entry.tab)) do
    local wi = valid_win(w) and vim.fn.getwininfo(w)[1] or nil
    if wi and wi.wincol == ref.wincol and wi.width == ref.width then out[#out + 1] = { win = w, height = wi.height, top = wi.winrow } end
  end
  table.sort(out, function(a, b) return a.top < b.top end); return out
end
-- The strip is only ever split under a PANEL's conversation window, so an
-- entry always has a panel and the donors are always that panel's own windows.
-- The old anchor-window fallback existed for strips split under a source-file
-- review window; that anchoring is retired.
local function panes(entry, skip)
  return panel_wins(entry, skip)
end
local function weights(n)
  local raw, out = cfg().steal_ratio, {}
  for i = 1, n do out[i] = math.max(0, tonumber(type(raw) == "table" and raw[i]) or 1) end
  return out
end
function M._steal(need, heights, mins, ws)
  local takes, left = {}, need; for i = 1, #heights do takes[i] = 0 end
  while left > 0 do
    local ids, sum = {}, 0
    for i = 1, #heights do if heights[i] - takes[i] - mins[i] > 0 and (ws[i] or 0) > 0 then ids[#ids + 1] = i; sum = sum + ws[i] end end
    if #ids == 0 or sum <= 0 then break end
    local add, assigned = {}, 0
    for _, i in ipairs(ids) do add[i] = math.min(heights[i] - takes[i] - mins[i], math.floor(left * ws[i] / sum)); assigned = assigned + add[i] end
    local rem = left - assigned
    while rem > 0 do
      local progressed = false
      for _, i in ipairs(ids) do
        if rem == 0 then break end
        if heights[i] - takes[i] - mins[i] - (add[i] or 0) > 0 then
          add[i], rem, assigned = (add[i] or 0) + 1, rem - 1, assigned + 1
          progressed = true
        end
      end
      if not progressed then break end
    end
    if assigned == 0 then break end
    for _, i in ipairs(ids) do takes[i] = takes[i] + (add[i] or 0) end
    left = left - assigned
  end
  return takes, need - left
end
local function height(w) local wi = vim.fn.getwininfo(w)[1]; return wi and wi.height or vim.api.nvim_win_get_height(w) end
local function set_height(w, h) local wi = vim.fn.getwininfo(w)[1]; pcall(vim.api.nvim_win_set_height, w, math.max(1, h + ((wi and wi.winbar) or 0))) end
local function split_heights(total, weights, min_each)
  min_each = min_each or 1
  local n = #weights
  if n == 0 or total < n * min_each then
    return nil
  end
  local wsum = 0
  for _, w in ipairs(weights) do
    wsum = wsum + w
  end
  if wsum <= 0 then
    return nil
  end
  local out, used = {}, 0
  for i = 1, n - 1 do
    out[i] = math.max(min_each, math.floor(total * weights[i] / wsum))
    used = used + out[i]
  end
  out[n] = total - used
  if out[n] < min_each then
    return nil
  end
  return out
end
local function apply_heights(entries, scale)
  local live, sum, good = 0, 0, {}; for _, e in ipairs(entries or {}) do if valid_win(e.win) then good[#good + 1] = e; live, sum = live + height(e.win), sum + e.height end end
  if #good == 0 then return end; vim.o.equalalways = false
  for _ = 1, 32 do
    local target = {}; for i, e in ipairs(good) do target[i] = e.height end
    if scale and sum > 0 and sum ~= live then local used = 0; for i = 1, #good - 1 do target[i] = math.max(1, math.floor(live * good[i].height / sum + .5)); used = used + target[i] end; target[#good] = math.max(1, live - used) end
    local same = true; for i, e in ipairs(good) do if height(e.win) ~= target[i] then same = false; break end end; if same then break end
    local order = {}; for i = 1, #good do order[i] = i end
    table.sort(order, function(a, b) local da, db = target[a] - height(good[a].win), target[b] - height(good[b].win); return da == db and a < b or da < db end)
    for _, i in ipairs(order) do if height(good[i].win) ~= target[i] then set_height(good[i].win, target[i]) end end
  end
end
-- The panes' heights as they stand, remembered so the NEXT event can tell an
-- outside resize (the column's total changed; Neovim redistributed it as it
-- liked) from a drag of a divider inside the column (the total is the
-- same, only the split moved).
--
-- TWO totals, and the difference matters. `total` is the DONORS' sum and is
-- what the restore scales to. `col` adds the strip's own rows, and it is the
-- change detector: the strip's height moving is not an outside resize, it is
-- this module's own business, settled against the anchor alone. Reading
-- `total` as the detector made a by-hand drag of the strip's divider look
-- like Neovim redistributing the column, so the revert rescaled every pane
-- instead of handing the rows back to the anchor.
local function snapshot_panes(entry)
  local ps = panes(entry, entry.win)
  local rows, total = {}, 0
  for i, p in ipairs(ps) do
    rows[i] = height(p.win)
    total = total + rows[i]
  end
  local col = total + (valid_win(entry.win) and height(entry.win) or 0)
  entry.pane_state = { rows = rows, total = total, col = col }
end

-- THE AMENDMENT, verbatim: "the strip does not participate in proportional
-- redistribution; every other pane keeps its ratios across
-- resize/relayout". Kept exactly -- but the ratios restored are the ones the
-- panes had BEFORE this event, not the weights frozen at strip open. Only a
-- change in the column's TOTAL is Neovim's arbitrary redistribution to undo;
-- a total that did not move carries the operator's own split, and re-imposing
-- open-time weights on it is what discarded a dragged conversation on a bare
-- VimResized (conv 5 -> 10, prompt 9 -> 4).
local function keep_pane_ratios(entry)
  local ps = panes(entry, entry.win)
  local last = entry.pane_state
  if #ps == 0 then
    return
  end
  local live = 0
  for _, p in ipairs(ps) do
    live = live + height(p.win)
  end
  local live_col = live + (valid_win(entry.win) and height(entry.win) or 0)
  if last and last.col and last.col ~= live_col and #last.rows == #ps and last.total > 0 then
    local entries = {}
    for i, p in ipairs(ps) do
      entries[i] = { win = p.win, height = last.rows[i] }
    end
    apply_heights(entries, true)
  end
  snapshot_panes(entry)
end

-- THE COLUMN AFTER OPEN BELONGS TO THE OPERATOR. Budgeting is an OPEN-TIME
-- event and nothing else: the strip pays for itself once, out of its own
-- panel's named donors, and then NEVER re-splits the column again. When its
-- own height has to change -- the render grew or shrank, or the operator
-- dragged the strip's divider -- the delta is exchanged with the ANCHOR
-- window directly above it, the conversation window the `belowright split`
-- was cut from, and every other window in the column is pinned at the height
-- the operator left it. Re-imposing the open-time pane weights on every
-- resize event, which is what this used to do, threw away an operator's own
-- conversation/prompt split on a bare `doautocmd VimResized` (conv 5 -> 10,
-- prompt 9 -> 4) -- a resize event is not an instruction to relayout the
-- sidebar.
local function exchange_with_anchor(entry, want)
  if not (entry and valid_win(entry.win)) then
    return nil
  end
  want = math.max(1, want)
  local cur = height(entry.win)
  local anchor = (valid_win(entry.anchor_win) and entry.anchor_win ~= entry.win) and entry.anchor_win or nil
  if not anchor then
    if cur ~= want then set_height(entry.win, want) end
    return height(entry.win)
  end
  local delta = want - cur
  -- The anchor pays, above its own floor: a strip never takes a conversation
  -- below MIN_CONV rows, and never gets rows from anyone else.
  if delta > 0 then delta = math.min(delta, math.max(0, height(anchor) - MIN_CONV)) end
  if delta == 0 then
    return cur
  end
  local entries = {}
  for _, c in ipairs(column_snapshot(entry)) do
    local h = c.height
    if c.win == entry.win then
      h = cur + delta
    elseif c.win == anchor then
      h = c.height - delta
    end
    entries[#entries + 1] = { win = c.win, height = h }
  end
  apply_heights(entries, false)
  -- OURS, not the operator's: the panes' new total is recorded so the next
  -- event does not read this exchange as an outside resize to undo.
  snapshot_panes(entry)
  return height(entry.win)
end

-- MUTATION ONLY. The retired open-time-weights relayout, kept in one place so
-- `r_strip_resize_keeps_operator_split[mutation]` can put the defect back in
-- memory (`M._test.relayout_column`) and prove the row reds on it. No product
-- path calls this.
local function redistribute(entry, strip_h)
  local ps = panes(entry, entry.win)
  local n = #ps
  if n == 0 then
    return
  end
  local ws = entry.weights or {}
  while #ws < n do
    ws[#ws + 1] = 1
  end
  if #ws > n then
    local trimmed = {}
    for i = 1, n do
      trimmed[i] = ws[i]
    end
    ws = trimmed
  end
  local col_total = valid_win(entry.win) and height(entry.win) or strip_h
  for _, p in ipairs(ps) do
    col_total = col_total + height(p.win)
  end
  strip_h = math.max(1, math.min(strip_h, col_total - n))
  local targets = split_heights(col_total - strip_h, ws, 1)
  if not targets then
    return
  end
  local entries = {}
  for i, p in ipairs(ps) do
    entries[i] = { win = p.win, height = targets[i] }
  end
  entries[#entries + 1] = { win = entry.win, height = strip_h }
  apply_heights(entries, false)
end

-- THE review a strip renders: its pool's active one, read fresh every time.
-- The entry never caches a review, so park, resume and file switches need no
-- teardown -- only a refresh.
local function cur_state(e) return e and e.pool and e.pool.active or nil end
local function entry_for_win(win) for _, e in ipairs(strips) do if e.win == win then return e end end end
function M.tab_for_win(win) local e = entry_for_win(win); return e and e.tab or nil end

-- The window showing the rendered review IN THIS STRIP'S OWN TAB. A press is a
-- click in one tabpage and must never teleport the operator to another: when
-- the review is not on screen here, the cursor stays where it is and the action
-- still runs.
local function focus_review(state, tab)
  local w = review_win(state, tab)
  if valid_win(w) then pcall(vim.api.nvim_set_current_win, w) end
end
-- CONTAINMENT, the same shape as `guarded_open`. The ledger seam above stops
-- the error a poisoned review actually throws; this stops everything else --
-- a refresh runs on every CursorMoved, and an uncaught error there is a
-- traceback in the operator's face on every keystroke AND an autocmd Neovim
-- eventually disables. The strip's window and its geometry are never touched
-- on this path, so a failed refresh leaves the strip exactly as it stood.
local refresh_errors, refresh_notified = 0, false
local function contain(where, fn)
  if M._test.uncontained then return fn() end
  local ok, res = xpcall(fn, debug.traceback)
  if ok then return res end
  refresh_errors = refresh_errors + 1
  log.lifecycle_later(where == "press" and "review.strip_press_error" or "review.strip_refresh_error",
    { err = tostring(res):gsub("%s+", " "):sub(1, 400), count = refresh_errors })
  if not refresh_notified then
    refresh_notified = true
    vim.schedule(function() notify.one_line("yana: review buttons — the strip could not be refreshed (see :YanaLog review.strip_refresh_error)", vim.log.levels.ERROR) end)
  end
  return nil
end
local run_action_impl
local function run_action(e, action, key, live) return contain("press", function() return run_action_impl(e, action, key, live) end) end
function run_action_impl(e, action, key, live)
  local state = cur_state(e)
  local pending = pending_count(state, "press")
  local idx, unreadable = hunk_index(state, e.tab, "press")
  local readable = pending ~= nil and not unreadable
  if live == nil then live = not ((action == "next" or action == "prev") and (pending or 0) == 0) and not ((action == "accept_hunk" or action == "reject_hunk") and idx == nil) end
  -- An unreadable ledger is dim, whatever the caller thought.
  if not readable then live = false end
  local change = state and state.change
  -- The `hunk_index` read is INSIDE the contained seam, not bare in this
  -- argument list: it used to throw the ledger's error straight out of
  -- `run_action`, past `log.guard`, and into the operator's press.
  log.lifecycle_later("review.button_press", { button = action, key = key, live = live and true or false, change_id = change and change.id or nil, hunk_index = idx, source = "mouse" })
  if not live or not state then return end
  local inline = require("yana.inline_diff"); focus_review(state, e.tab)
  log.guard("yana.review_buttons " .. action, function()
    if action == "abort" then inline.abort_active(state.opts); return end
    if action == "next" or action == "prev" then inline._navigate_or_park_state(state, action); return end
    local op = ({ accept_file = "accept_all", reject_file = "reject_all", accept_hunk = "accept_hunk", reject_hunk = "reject_hunk", accept_all = "accept_everything" })[action]
    local fn = state._ops and state._ops[op]
    if type(fn) ~= "function" then log.write("ERROR", ("yana.review_buttons: no op %q for button %q"):format(tostring(op), tostring(action))); notify.one_line("yana: that button is not wired -- " .. tostring(action), vim.log.levels.ERROR); return end
    fn()
  end)
  vim.schedule(function() M.refresh(e.tab) end)
end
local function clear_armed(e) e.armed_action, e.armed_key, e.armed_live = nil, nil, nil end
local function stop_flash_timer(e)
  if e.flash_timer and type(e.flash_timer.stop) == "function" then pcall(e.flash_timer.stop, e.flash_timer); pcall(e.flash_timer.close, e.flash_timer) end; e.flash_timer = nil
end
local function schedule_flash_fallback(e)
  stop_flash_timer(e); e.flash_timer = vim.defer_fn(function() e.flash_timer = nil; e.flash_until, e.flash_action = nil, nil; e.grid:render() end, FLASH_MS)
end
local function press_entry(e, s)
  if not s then clear_armed(e); stop_flash_timer(e); e.flash_until, e.flash_action = nil, nil; return end
  e.armed_action, e.armed_key, e.armed_live = s.action, s.key, s.live; stop_flash_timer(e)
  e.flash_action, e.flash_until = s.live and s.action or nil, nil
end
local function release_entry(e, s)
  local action, key, live = e.armed_action, e.armed_key, e.armed_live; if not action then return end; clear_armed(e)
  if not (s and s.action == action) then stop_flash_timer(e); e.flash_until, e.flash_action = nil, nil; return end
  live = live and s.live
  if live then e.flash_action, e.flash_until = action, (vim.uv or vim.loop).now() + FLASH_MS; schedule_flash_fallback(e) else stop_flash_timer(e); e.flash_until, e.flash_action = nil, nil end
  run_action(e, action, key, live)
end
local function span_named(e, action) for _, s in ipairs(e and e.spans or {}) do if s.action == action then return s end end end
local function stop_timer(e)
  if e.timer and type(e.timer.stop) == "function" then pcall(e.timer.stop, e.timer); pcall(e.timer.close, e.timer) end; e.timer = nil; stop_flash_timer(e)
end
local bind_buf_autocmds
local refresh_entry_impl
local function refresh_entry(e) return contain("refresh", function() return refresh_entry_impl(e) end) end
function refresh_entry_impl(e)
  if not (e and valid_win(e.win) and valid_buf(e.buf)) then return end
  bind_buf_autocmds(e, true)
  keep_pane_ratios(e)
  e.grid.opts.max_height = max_h()
  local lines = select(1, M.render({ state = cur_state(e), tab = e.tab, where = "refresh", width = vim.api.nvim_win_get_width(e.win) }))
  -- WHOSE HEIGHT IS IT. Two gestures reach this line as the same
  -- WinResized/refresh and cannot be told apart from the events alone: an
  -- operator dragging the strip's own divider, and a narrower sidebar
  -- reflowing the buttons onto more rows and then back. Nothing here guesses
  -- between them any more: the RENDERED line count always wins, so a by-hand
  -- drag of the strip's divider is simply undone by the next refresh
  -- (review_buttons_geometry_durability[drag_reverts]) and a width-only
  -- reflow is undone the moment the buttons fit again
  -- (r_strip_height_follows_width). Either way the rows are exchanged with the
  -- ANCHOR alone -- the rest of the column is the operator's
  -- (r_strip_resize_keeps_operator_split).
  local rendered = math.max(min_h(), math.min(max_h(), #lines))
  e.rendered = rendered
  local want = rendered
  if M._test.honour_drag then want = math.max(min_h(), math.min(max_h(), height(e.win))) end
  if M._test.grow_only then want = math.max(want, height(e.win)) end
  if M._test.relayout_column then
    redistribute(e, want)
  elseif height(e.win) ~= want then
    exchange_with_anchor(e, want)
  end
  e.height = height(e.win)
  e.grid:render()
end
local function schedule_refresh(e) if e.timer then return end; e.timer = vim.defer_fn(function() e.timer = nil; refresh_entry(e) end, 35) end

-- CursorMoved/TextChanged follow `pool.active.bufnr`, which CHANGES under a
-- live strip (park, resume, next file). Binding once at open left the strip
-- listening to a buffer nobody is reviewing any more, so the binding is
-- re-derived on every refresh. Rebinding from inside one of these callbacks is
-- deferred so an augroup is never deleted mid-drain.
local function rebind(e, buf)
  if e.bufgroup then pcall(vim.api.nvim_del_augroup_by_id, e.bufgroup); e.bufgroup = nil end
  if not (buf and valid_win(e.win)) then return end
  e.bufgroup = vim.api.nvim_create_augroup("YanaReviewButtonsBuf" .. tostring(e.win), { clear = true })
  vim.api.nvim_create_autocmd({ "CursorMoved", "CursorMovedI" }, { group = e.bufgroup, buffer = buf, callback = function() refresh_entry(e) end })
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, { group = e.bufgroup, buffer = buf, callback = function() schedule_refresh(e) end })
end
function bind_buf_autocmds(e, defer)
  local st = cur_state(e)
  local buf = st and valid_buf(st.bufnr) and st.bufnr or nil
  if e.buf_bound == buf then return end
  e.buf_bound = buf
  if defer then vim.schedule(function() if entry_for(e.panel, e.tab) == e then rebind(e, buf) end end) else rebind(e, buf) end
end

function M.height_of(panel, tab)
  tab = tab or vim.api.nvim_get_current_tabpage()
  if not panel or not valid_win(views.conv(panel, tab)) then return 0 end; local e = entry_for(panel, tab); return e and valid_win(e.win) and height(e.win) or 0
end
function M.apply_relayout(panel, tab, conv_h, prompt_h)
  if not panel then return end; tab = tab or vim.api.nvim_get_current_tabpage(); local btn = M.height_of(panel, tab)
  local cw, pw = views.conv(panel, tab), views.prompt(panel, tab)
  if valid_win(cw) then pcall(vim.api.nvim_win_set_height, cw, math.max(MIN_CONV, conv_h)) end; if valid_win(pw) then pcall(vim.api.nvim_win_set_height, pw, prompt_h) end
  local e = entry_for(panel, tab); if e and valid_win(e.win) then pcall(vim.api.nvim_win_set_height, e.win, math.max(min_h(), btn)) end
end
function M.refresh(tab) for _, e in ipairs(tab and entries_in_tab(tab) or all_entries()) do refresh_entry(e) end end

local function close_entry(e, reason)
  if not e then return end; forget(e); stop_timer(e); if e.augroup then pcall(vim.api.nvim_del_augroup_by_id, e.augroup) end
  if e.bufgroup then pcall(vim.api.nvim_del_augroup_by_id, e.bufgroup); e.bufgroup = nil end
  log.lifecycle_later("review.strip_close", { tab = e.tab, panel_id = e.panel and e.panel.id or nil, reason = reason or "unspecified" })
  local prev_ea = vim.o.equalalways; vim.o.equalalways = false; if e.grid then e.grid:close(false) end; if valid_win(e.win) then pcall(vim.api.nvim_win_close, e.win, true) end; if valid_buf(e.buf) then pcall(vim.api.nvim_buf_delete, e.buf, { force = true }) end
  pcall(vim.cmd, "redraw"); apply_heights(e.pre, false); vim.o.equalalways = prev_ea
end
-- SIDEBAR TEARDOWN ONLY: the strip WINDOW goes, the Turn's claim on it does
-- not, so reopening the sidebar brings it straight back (M.attach).
-- `panel` scopes the teardown to ONE sidebar view: a panel closing its windows
-- (or being quit) must not take a sibling panel's strip with it.
function M.detach_windows(tab, panel)
  for _, e in ipairs(tab and entries_in_tab(tab) or all_entries()) do
    if panel == nil or e.panel == panel then close_entry(e, "sidebar_teardown") end
  end
end
-- Compat alias for existing sidebar-teardown callers.
M.close = M.detach_windows

local function open_impl(panel, pool, tab)
  local anchor = views.conv(panel, tab); if not valid_win(anchor) then return false end
  local state = pool and pool.active
  local old = entry_for(panel, tab); if old then refresh_entry(old); return true end
  local e = { tab = tab, anchor_win = anchor, panel = panel, pool = pool }; local ps = panes(e); if #ps == 0 then return false end
  local pre, hs, ms = {}, {}, {}; for i, p in ipairs(ps) do p.height = height(p.win); pre[i] = { win = p.win, height = p.height }; hs[i], ms[i] = p.height, p.min end
  local pane_weights = {}; for i, p in ipairs(pre) do pane_weights[i] = p.height end
  -- BUDGET. The strip costs its content rows PLUS the split's own overhead,
  -- and the whole bill is charged to this panel's named donors. Bystanders in
  -- the same column are snapshotted now and pinned back afterwards; if the
  -- donors cannot pay above their one-row floors the strip shrinks, and if it
  -- cannot shrink far enough it is not opened at all. A sibling never yields.
  local donor_of = {}; for _, p in ipairs(ps) do donor_of[p.win] = true end
  local others, donor_total = {}, 0
  for _, c in ipairs(column_snapshot(e)) do if not donor_of[c.win] then others[#others + 1] = { win = c.win, height = c.height } end end
  for i = 1, #ps do donor_total = donor_total + hs[i] end
  local capacity = 0; for i = 1, #ps do capacity = capacity + math.max(0, hs[i] - ms[i]) end
  -- `where = "open"`: this read is guarded_open's to report, not the refresh
  -- seam's to swallow -- see `ledger_call`.
  local lines = select(1, M.render({ state = state, tab = tab, where = "open", width = vim.api.nvim_win_get_width(anchor) }))
  local need = math.max(min_h(), math.min(max_h(), #lines))
  local takes, got = M._steal(math.min(need, capacity), hs, ms, pane_weights)
  if got < 1 then notify.one_line("yana: review buttons — no pane has room; strip not opened", vim.log.levels.WARN); return false end
  local before, freed, source = {}, 0, 1; for i, p in ipairs(ps) do if p.win == anchor then source = i end; local target_h = math.max(p.min, p.height - (takes[i] or 0)); freed = freed + p.height - target_h; before[i] = { win = p.win, height = target_h } end; before[source].height = before[source].height + freed; apply_heights(before, false)
  local prev = vim.api.nvim_get_current_win(); pcall(vim.api.nvim_set_current_win, anchor); if not pcall(vim.cmd, "belowright split") then apply_heights(pre, false); if valid_win(prev) then pcall(vim.api.nvim_set_current_win, prev) end; return false end
  e.win = vim.api.nvim_get_current_win()
  -- Window options BEFORE the overhead is measured: `belowright split`
  -- inherits the anchor's `winbar`, and a winbar is a screen row the strip
  -- would otherwise be charged for and then hand back.
  vim.wo[e.win].number, vim.wo[e.win].relativenumber, vim.wo[e.win].signcolumn, vim.wo[e.win].foldcolumn, vim.wo[e.win].wrap = false, false, "no", "0", false; vim.wo[e.win].statusline, vim.wo[e.win].winbar, vim.wo[e.win].winfixheight = " ", nil, true
  -- MEASURE the overhead rather than assuming it is one: pin the bystanders
  -- back first, then whatever the donors-plus-strip group is short of its
  -- former total IS the split's cost.
  apply_heights(others, false)
  local pinned = {}; for _, o in ipairs(others) do pinned[o.win] = true end
  local group_now = 0
  for _, c in ipairs(column_snapshot(e)) do if not pinned[c.win] then group_now = group_now + c.height end end
  local overhead = math.max(0, donor_total - group_now)
  local strip_h = math.min(need, capacity - overhead)
  M._last_open = { overhead = overhead, capacity = capacity, need = need, strip_height = strip_h, donor_total = donor_total, donors = {}, bystanders = others }
  for i, p in ipairs(ps) do M._last_open.donors[i] = { win = p.win, before = hs[i], min = ms[i] } end
  if strip_h < 1 then
    pcall(vim.api.nvim_win_close, e.win, true)
    apply_heights(pre, false); apply_heights(others, false)
    if valid_win(prev) then pcall(vim.api.nvim_set_current_win, prev) end
    notify.one_line("yana: review buttons — this panel cannot spare the rows; strip not opened", vim.log.levels.WARN)
    log.lifecycle_later("review.strip_refused", { capacity = capacity, overhead = overhead, need = need })
    return false
  end
  takes, got = M._steal(strip_h + overhead, hs, ms, pane_weights)
  e.pre, e.height = pre, 0; for _, o in ipairs(others) do e.pre[#e.pre + 1] = { win = o.win, height = o.height } end
  e.weights = pane_weights; e.buf = vim.api.nvim_create_buf(false, true); vim.api.nvim_win_set_buf(e.win, e.buf)
  vim.bo[e.buf].buftype, vim.bo[e.buf].bufhidden, vim.bo[e.buf].swapfile = "nofile", "wipe", false; vim.bo[e.buf].modifiable, vim.bo[e.buf].filetype = false, "yana-review-buttons"
  do
    local entries = {}
    for i, p in ipairs(ps) do entries[#entries + 1] = { win = p.win, height = math.max(ms[i], hs[i] - (takes[i] or 0)) } end
    for _, o in ipairs(others) do entries[#entries + 1] = { win = o.win, height = o.height } end
    entries[#entries + 1] = { win = e.win, height = strip_h }
    apply_heights(entries, false)
  end
  e.height = height(e.win); e.rendered = need; snapshot_panes(e); M._last_open.strip_height = e.height; strips[#strips + 1] = e
  e.grid = grid.new({ state = e, layout = "flow", max_height = max_h(), width = function() return vim.api.nvim_win_get_width(e.win) end, cells = function(_x) local defs = button_list(cur_state(e), e.tab, "refresh"); local width = vim.api.nvim_win_get_width(e.win); local full = select(1, render_layout(defs, width, function(d) return d.label end)); local compact = select(1, render_layout(defs, width, function(d) return d.short or d.label end)); local pick = #compact < #full and function(d) return d.short or d.label end or function(d) return d.label end; return button_rows(defs, pick, e) end, hl_groups = HL, map_desc = STRIP_MAP_DESC, global_mouse = true, release_anywhere = true, close_window = false, delete_buffer = false, on_press = function(_, s) press_entry(e, s) end, on_release = function(_, s) release_entry(e, s) end, on_hover = function(_, s) e.hover_action = s and s.live and s.action or nil end })
  e.grid:attach(e.buf, e.win)
  -- Resize NEVER closes the strip: it re-lays out and re-renders.
  e.augroup = vim.api.nvim_create_augroup("YanaReviewButtons" .. tostring(e.win), { clear = true }); vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, { group = e.augroup, callback = function() refresh_entry(e) end }); vim.api.nvim_create_autocmd("User", { group = e.augroup, pattern = "YanaReviewSettled", callback = function() refresh_entry(e) end })
  bind_buf_autocmds(e, false)
  log.lifecycle_later("review.strip_open", { tab = tab, panel_id = panel and panel.id or nil, height = e.height, anchor = "panel" })
  if valid_win(prev) then pcall(vim.api.nvim_set_current_win, prev) end; return true
end

-- THE liveness question, asked in one place: turn_bind owns the live Turn and
-- the pool it was bound to. Review pools are keyed by WORKSPACE
-- (review_context.lua `pool_for`), never by panel, and the Turn is a session
-- singleton, so "this panel's pool" is not a distinction the model can make
-- today: every sidebar view in the workspace is chrome of the same live Turn
-- and gets its own strip. When pools become per-panel this is the one function
-- that narrows.
local function live_pool_for_panel(panel)
  if not panel then return nil end
  return require("yana.turn_bind").live_pool()
end
-- WHICH view hosts the pool's one strip in `tab`: the panel that owns the
-- active review, else the sidebar's primary panel, else whoever asked, else
-- any view there -- each only if it actually has a conversation window in this
-- tab. Ownership, never geometry, and the host is re-chosen whenever the
-- previous one loses its view (`host_gone`).
local function host_panel(pool, tab, asked)
  local ok, ui = pcall(require, "yana.ui")
  if not ok then return asked end
  local st = pool and pool.active
  local owner = st and st.opts and st.opts.review_owner
  local by_owner = type(ui.panel_for_owner) == "function" and ui.panel_for_owner(owner) or nil
  local primary = type(ui.panel_for_owner) == "function" and ui.panel_for_owner(nil) or nil
  for _, p in ipairs({ by_owner, primary, asked }) do
    if p and valid_win(views.conv(p, tab)) then return p end
  end
  return nil
end
-- Every panel with a conversation window in `tab`, in panel order.
local function panel_views_in(tab)
  local ok, ui = pcall(require, "yana.ui")
  if not ok or type(ui.panel_views) ~= "function" then return {} end
  local out = {}
  for _, v in ipairs(ui.panel_views(tab) or {}) do
    if valid_win(v.conv) then out[#out + 1] = v.panel end
  end
  return out
end

-- A render failure is contained, logged every time and shown to the operator
-- once per session.
local open_errors, open_notified = 0, false
local function guarded_open(panel, pool, tab)
  -- Closure, not `xpcall(open_impl, h, ...)`: passing arguments through
  -- xpcall is a 5.2 extension, and this must hold on any 5.1 build.
  local ok, res = xpcall(function() return open_impl(panel, pool, tab) end, debug.traceback)
  if ok then return res end
  open_errors = open_errors + 1
  log.lifecycle_later("review.strip_open_error", { err = tostring(res):gsub("%s+", " "):sub(1, 400), count = open_errors })
  if not open_notified then
    open_notified = true
    notify.one_line("yana: review buttons — strip failed to open (see :YanaLog review.strip_open_error)", vim.log.levels.ERROR)
  end
  return false
end

-- Open (or refresh) `panel`'s strip in `tab`. Idempotent, and refuses unless a
-- live Turn owns the panel. Every sidebar-open path ends here.
-- `pool` is the pool the entry will RENDER (`pool.active`). It is only ever
-- the caller's own pool or the live Turn's; a nil one means "no live Turn" and
-- takes the strip down.
local function attach_pool(pool, tab, asked)
  if not pool then
    local stale = asked and entry_for(asked, tab)
    if stale then close_entry(stale, "no_live_turn") end
    return false
  end
  local e = entry_for_pool(pool, tab)
  if e then
    -- Whoever asked, the pool's one strip is already here: refresh it, never
    -- close it. It only goes when its window died or its host lost its view.
    if valid_win(e.win) and valid_win(views.conv(e.panel, tab)) then refresh_entry(e); return true end
    close_entry(e, "host_gone")
  end
  local host = host_panel(pool, tab, asked)
  if not host then return false end
  return guarded_open(host, pool, tab)
end
function M.attach(panel, tab)
  if not panel then return false end
  tab = valid_tab(tab) and tab or vim.api.nvim_get_current_tabpage()
  return attach_pool(live_pool_for_panel(panel), tab, panel)
end
-- Close every strip HOSTED by `panel`, in any tab, and answer which tabs those
-- were. The registry is the only record of that hosting, so a caller tearing a
-- panel down can neither find nor rebuild it from view records -- which prune
-- themselves away the moment the panel's buffers go.
function M.detach_panel(panel)
  local tabs = {}
  for _, e in ipairs(all_entries()) do
    if e.panel == panel then
      tabs[#tabs + 1] = e.tab
      close_entry(e, "host_quit")
    end
  end
  return tabs
end

-- The tab's own claim on the strip, host chosen by the module: used where no
-- particular panel is asking (a quit that took the host with it).
function M.attach_tab(tab)
  tab = valid_tab(tab) and tab or vim.api.nvim_get_current_tabpage()
  local panels = panel_views_in(tab)
  if #panels == 0 then return false end
  return attach_pool(require("yana.turn_bind").live_pool(), tab, panels[1])
end

-- A strip window closed by hand (`:q` inside it) is not a lifecycle event --
-- only `turn_end` removes the strip -- so the window is rebuilt on the next
-- tick. `attach` refuses on its own if the Turn ended meanwhile.
function M.on_win_closed(win)
  local e = entry_for_win(win)
  if not e then return false end
  local panel, tab = e.panel, e.tab
  close_entry(e, "window_closed")
  vim.schedule(function()
    if valid_tab(tab) then M.attach(panel, tab) end
  end)
  return true
end

-- turn_start: every tab where the owning panel is on screen gets the strip.
function M.open(pool)
  local any = false
  for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
    local panels = panel_views_in(tab)
    if #panels > 0 then
      -- The caller's pool is what the strip renders, but LIVENESS is still the
      -- Turn's answer, never the argument's: no live Turn, no strip.
      local live = require("yana.turn_bind").live_pool()
      any = attach_pool(live and (pool or live) or nil, tab, panels[1]) or any
    end
  end
  return any
end

-- turn_end: the one event that removes the strip.
function M.remove(pool)
  for _, e in ipairs(all_entries()) do
    if pool == nil or e.pool == pool then close_entry(e, "turn_end") end
  end
end

-- BUDGET RETRY (F-STRIP-BUDGET). A refusal is a deferral, not a decision: the
-- ruling's one condition is the live Turn, not the rows the donors happened to
-- have at `turn_start`. Every relayout asks again for the views that have no
-- strip, so the strip lands the moment the column can pay. Registry lookup
-- first, so the common case is one table walk.
local retrying = false
vim.api.nvim_create_autocmd({ "WinResized", "VimResized" }, {
  group = vim.api.nvim_create_augroup("YanaReviewButtonsRetry", { clear = true }),
  callback = function()
    if retrying then return end
    if not require("yana.turn_bind").live_pool() then return end
    local tab = vim.api.nvim_get_current_tabpage()
    retrying = true
    local ok, err = pcall(function()
      -- ONLY when the tab has no strip at all. A retry must never touch a
      -- strip that exists: `attach` refreshes, and a refresh re-asserts the
      -- recorded height, and an existing strip's geometry is settled by its
      -- own refresh, not by a retry.
      if #entries_in_tab(tab) == 0 then M.attach_tab(tab) end
    end)
    retrying = false
    if not ok then log.lifecycle_later("review.strip_retry_error", { err = tostring(err):sub(1, 200) }) end
  end,
})

M._test = M._test or {}
-- MUTATION SEAM. Set true to restore the pre-fix grow-only latch (the strip
-- keeps every row a reflow ever gave it). r_strip_height_follows_width's
-- mutation phase flips it and must go red; nothing in the product reads it.
M._test.grow_only = false
-- MUTATION SEAMS (nothing in the product reads them; each restores one
-- retired behaviour in memory for the row that proves it is gone):
--   grow_only          -- the strip keeps every row a reflow gave it
--                         (r_strip_height_follows_width[mutation])
--   honour_drag        -- a by-hand drag of the strip's divider is kept
--                         against its own render
--                         (review_buttons_geometry_durability[drag_reverts])
--   relayout_column    -- every resize re-imposes the open-time pane weights
--                         (r_strip_resize_keeps_operator_split[mutation])
M._test.honour_drag = false
M._test.relayout_column = false
--   uncontained        -- the ledger read and the refresh/press guards are
--                         gone (r_strip_contains_ledger_errors[mutation])
M._test.uncontained = false
function M._test.open_errors() return open_errors end
function M._test.last_open() return M._last_open end
-- A TAB-KEYED VIEW over the (panel, tab) registry, because rows index it by
-- tab. With two panels stacked in one tab it shows the focused panel's entry.
local function focused_panel()
  local ok, ui = pcall(require, "yana.ui")
  if ok and type(ui.focused_panel) == "function" then local p = ui.focused_panel(); if p then return p end end
  if ok and type(ui.panel_for_owner) == "function" then return ui.panel_for_owner(nil) end
  return nil
end
-- One strip per (pool, tab), so a tab has one entry unless two pools ever run
-- live Turns at once; the focused panel's is preferred if it ever does.
local function entry_in_tab(tab)
  local list, focused = entries_in_tab(tab), focused_panel()
  for _, e in ipairs(list) do if focused and e.panel == focused then return e end end
  return list[1]
end
function M._test.state() return entry_in_tab(vim.api.nvim_get_current_tabpage()) end
function M._test.hunk_index(state, tab) return hunk_index(state, tab) end
function M._test.ledger_errors() return ledger_errors.refresh, ledger_errors.press end
function M._test.contained_errors() return refresh_errors end
function M._test.mouse_move(action) local e = entry_in_tab(vim.api.nvim_get_current_tabpage()); if e then local s = span_named(e, action); e.grid.hover = s and s.live and s.action and s or nil; e.hover_action = s and s.live and s.action or nil; e.grid:render() end end
function M._test.mouse_press(action) local e = entry_in_tab(vim.api.nvim_get_current_tabpage()); if e then e.grid:press(span_named(e, action)) end end
function M._test.mouse_release(action) local e = entry_in_tab(vim.api.nvim_get_current_tabpage()); if e and e.grid.armed then e.grid:release(span_named(e, action)) end end
function M._test.press(action) local e = entry_in_tab(vim.api.nvim_get_current_tabpage()); local s = e and span_named(e, action); if s then run_action(e, s.action, s.key, s.live) end end
function M._test.registry()
  local out = {}
  for _, e in ipairs(strips) do out[e.tab] = out[e.tab] or entry_in_tab(e.tab) end
  return out
end
function M._test.entries() return all_entries() end
function M._test.ns() return grid._test.namespace() end
function M._test.hl_groups() return HL end
function M._test.flash_duration_ms() return FLASH_MS end
function M.hl_groups() return HL end
return M
