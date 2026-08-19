-- Ordinary-edit capture for the timeline.
--
-- Emits `human_edit` / `buffer` rows through the pinned timeline interface
-- (`yana.timeline`.intent). Restoration authority stays Neovim's undo
-- tree: this module stores a hash and an undo sequence, never buffer bytes
-- A prior second-authority defect showed why this matters. A failure of intent cannot un-type
-- the keystroke, so a failed append is dropped rather than retried into a
-- second byte cache.
--
-- `on_lines` is FAST CONTEXT. This callback captures a bufnr and schedules;
-- it does not call vim.fn, vim.notify, or anything textlock-guarded. A
-- synchronous watcher was written for the review and reverted because
-- `on_lines` also fires inside the product's own writes (inline_diff.lua,
-- attach_buffer_watch). Same rule here.
local timeline = require("yana.timeline")

local M = {}

-- An insert-mode burst is one Neovim undo block. The block only closes on
-- InsertLeave (or an explicit undolevels break), so an idle pause WHILE STILL
-- INSERTING is not a closer: seq_cur has not advanced, and `:undo {seq}`
-- could not tell the pause from the rest of the insert. Leave insert, then
-- emit.
--
-- Normal-mode and scripted writes (nvim_buf_set_text, `r`, `x`) close their
-- undo block immediately, but fire `on_lines` per keystroke. A short idle
-- after the last such event groups the burst into one row. 200ms is longer
-- than inter-key delay and shorter than a human reading the list as lag.
local IDLE_MS = 200

local GROUP = vim.api.nvim_create_augroup("yana_timeline_edit_capture", { clear = false })
local next_epoch = 0
local watches = {}

local function break_undo_block(bufnr)
  -- Same seam as inline_diff.break_undo_block. With no pending change this
  -- creates no undo state; the NEXT edit starts a new node, so the row we
  -- just recorded is a reachable `:undo {seq}` bookmark rather than a hash
  -- glued to a still-open block.
  pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("let &undolevels = &undolevels")
  end)
end

local function emit(watch)
  if watch.detached then
    return
  end
  local bufnr = watch.bufnr
  if not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if timeline.review_open_for(watch.workspace, watch.rel) then
    -- Review owns the buffer and has its own watcher. Do not compete.
    watch.detached = true
    watches[bufnr] = nil
    pcall(vim.api.nvim_clear_autocmds, { group = GROUP, buffer = bufnr })
    return
  end
  -- Seal first. On some Neovim builds InsertLeave has fired but seq_cur has
  -- not advanced yet; observing before this boundary merges two edits into
  -- one timeline row even when the next command starts a new undo block.
  break_undo_block(bufnr)
  local record = require("yana.timeline.record")
  local obs = record.observe_buffer(bufnr)
  if not obs then
    return
  end
  if watch.last_hash == obs.expected_hash then
    watch.dirty = false
    return
  end
  -- A new hash on the same seq means the undo block is still open. Emitting
  -- would store a bookmark `:undo` cannot tell from the previous row.
  if watch.last_seq == obs.undo_seq then
    return
  end
  watch.last_hash = obs.expected_hash
  watch.last_seq = obs.undo_seq
  watch.dirty = false
  -- Call through the module table so a test (or a later store lane) can
  -- replace `intent` without this file binding the stub at load time.
  require("yana.timeline").intent({
    kind = "human_edit",
    regime = "buffer",
    rel = watch.rel,
    label = "edit " .. watch.rel,
    buffer_epoch = obs.buffer_epoch,
    undo_seq = obs.undo_seq,
    expected_hash = obs.expected_hash,
  })
end

local function close_burst(watch)
  -- Cancel any pending idle closer; this closer won.
  watch.gen = (watch.gen or 0) + 1
  local mode = vim.api.nvim_get_mode().mode
  if type(mode) == "string" and mode:find("i", 1, true) then
    -- Undo block still open. InsertLeave is the closer.
    return
  end
  emit(watch)
end

local function arm_idle(watch)
  watch.gen = (watch.gen or 0) + 1
  local gen = watch.gen
  vim.schedule(function()
    if watch.detached or watch.gen ~= gen then
      return
    end
    vim.defer_fn(function()
      if watch.detached or watch.gen ~= gen then
        return
      end
      close_burst(watch)
    end, IDLE_MS)
  end)
end

function M.attach(bufnr, workspace, rel)
  if type(bufnr) ~= "number" or not vim.api.nvim_buf_is_valid(bufnr) then
    return
  end
  if timeline.review_open_for(workspace, rel) then
    -- Do not attach while a review is open for this buffer. The review owns
    -- it and attach_buffer_watch is already observing on_lines there.
    return
  end
  M.detach(bufnr)
  -- INTEGRATION SEAM (wired by the integrator, 2026-08-19). This lane minted
  -- its own module-local counter epoch; the record lane, built in parallel,
  -- mints a per-buffer-lifetime STRING epoch in a b: variable and refuses any
  -- row whose epoch does not match it (break-test T06). Two epoch authorities
  -- means every human_edit row refuses on arrival — found on the first
  -- integrated read-through, which is what integrated re-runs are for. The
  -- record's epoch is the authority: it survives exactly as long as the undo
  -- tree it describes, which is the property the field exists to carry.
  next_epoch = next_epoch + 1
  local obs = require("yana.timeline.record").observe_buffer(bufnr)
  if not obs then
    return
  end
  local watch = {
    bufnr = bufnr,
    workspace = workspace,
    rel = rel,
    epoch = obs.buffer_epoch,
    last_seq = obs.undo_seq,
    last_hash = obs.expected_hash,
    gen = 0,
    detached = false,
    dirty = false,
  }
  require("yana.timeline.record").sync_buffer_head(bufnr, obs)
  watches[bufnr] = watch
  vim.api.nvim_clear_autocmds({ group = GROUP, buffer = bufnr })
  vim.api.nvim_create_autocmd("InsertLeave", {
    group = GROUP,
    buffer = bufnr,
    callback = function()
      local w = watches[bufnr]
      if w then
        close_burst(w)
      end
    end,
  })
  vim.api.nvim_create_autocmd("BufReadPost", {
    group = GROUP,
    buffer = bufnr,
    callback = function()
      M.attach(bufnr, workspace, rel)
    end,
  })
  vim.api.nvim_buf_attach(bufnr, false, {
    on_lines = function()
      -- FAST CONTEXT. Returning true detaches. Capture nothing; schedule.
      local w = watches[bufnr]
      if not w or w.detached then
        return true
      end
      w.dirty = true
      arm_idle(w)
    end,
    on_detach = function()
      local w = watches[bufnr]
      if w then
        w.detached = true
        w.gen = (w.gen or 0) + 1
        watches[bufnr] = nil
      end
    end,
  })
end

--- A product-owned history move (timeline walk) updates the watch without
--- creating a new human-edit row from its own buffer mutation.
function M.sync(bufnr)
  local watch = watches[bufnr]
  if not watch or watch.detached then
    return
  end
  local obs = require("yana.timeline.record").observe_buffer(bufnr)
  if not obs then
    return
  end
  watch.gen = (watch.gen or 0) + 1
  watch.dirty = false
  watch.epoch = obs.buffer_epoch
  watch.last_seq = obs.undo_seq
  watch.last_hash = obs.expected_hash
  require("yana.timeline.record").sync_buffer_head(bufnr, obs)
end

function M.detach(bufnr)
  local watch = watches[bufnr]
  if not watch then
    return
  end
  watch.gen = (watch.gen or 0) + 1
  if watch.dirty and not watch.detached then
    -- Buffer is leaving observation; flush a pending normal-mode burst so
    -- the last edit is not silently dropped. Insert-mode is still open only
    -- if detach raced InsertLeave; emit() is then a no-op on seq/hash repeat.
    local mode = vim.api.nvim_get_mode().mode
    if not (type(mode) == "string" and mode:find("i", 1, true)) then
      emit(watch)
    end
  end
  watch.detached = true
  watches[bufnr] = nil
  pcall(vim.api.nvim_clear_autocmds, { group = GROUP, buffer = bufnr })
end

return M
