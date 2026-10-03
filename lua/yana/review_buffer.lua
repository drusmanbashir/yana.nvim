-- Open and stage buffers for inline review without writing proposal bytes.
local diff = require("yana.diff")
local log = require("yana.log")

local M = {}

local NO_AFTER = "agent payload carried no after-content for this edit (nothing to review)"

local function snapshot_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

-- Fresh-open guard (G2): a modified buffer whose disk already holds the turn baseline
-- is stale, not refusing, when its lines are behind disk.
local function buffer_has_unsaved_beyond_disk(buf_text, disk_bytes)
  if diff.text_equal_snapshot(buf_text, disk_bytes) then
    return false
  end
  local buf_lines = snapshot_lines(buf_text)
  local disk_lines = snapshot_lines(disk_bytes)
  if #buf_lines < #disk_lines then
    return false
  end
  for i = 1, #disk_lines do
    if buf_lines[i] ~= disk_lines[i] then
      return true
    end
  end
  return #buf_lines > #disk_lines
end

function M.new(deps)
  local function open_impl(change, preview)
	local review_before = change.review_before ~= nil and change.review_before or change.before
    if preview then
      local bufnr = vim.api.nvim_create_buf(false, true)
      vim.bo[bufnr].buftype = "nofile"
      vim.bo[bufnr].bufhidden = "hide"
      vim.bo[bufnr].modifiable = true
      local lines = deps.buffer_lines(review_before or "")
      if #lines == 0 then
        lines = { "" }
      end
      vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
      pcall(vim.api.nvim_buf_set_name, bufnr, "yana://diff-theme-preview")
      change.path = change.path or "yana://diff-theme-preview"
      change.rel = "diff-theme-preview"
      return bufnr, nil
    end

    local path = diff.abs_path(change.path)
    change.path = path
    change.rel = change.rel or diff.relpath(path)
    local existing = vim.fn.bufnr(path, false)
    if existing > 0
      and vim.api.nvim_buf_is_loaded(existing)
      and type(change._parked_review) == "table"
      and type(change._parked_review.staged_text) == "string"
    then
      local current = diff.buffer_text_normalized(existing)
      if diff.text_equal_snapshot(current, change._parked_review.staged_text) then
        local dirty = vim.bo[existing].modified
        if not dirty or deps.parked_dirty_explained(change, change._parked_review) then
          change._parked_already_staged = true
          change.disk_at_open = diff.read_file_bytes(path)
          if change.undo_pre_stage_seq == nil then
            change.undo_pre_stage_seq = deps.buf_undo_seq(existing)
          end
          return existing, nil
        end
      end
    end

    -- A file whose buffer was captured at submit opens in that buffer as it stands (B1). No
    -- refusal, no disk read, no reload, and nothing is staged here: review open
    -- places each edit on B1, or stages B0 itself when the extmarks cannot be used.
    local snap = type(change.buffer_capture) == "table" and change.buffer_capture or nil
    if snap then
      if change.kind ~= "delete" and change.after == nil then
        return nil, NO_AFTER
      end
      local bufnr = snap.bufnr
      if not (bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
        bufnr = vim.fn.bufnr(path, true)
      end
      vim.fn.bufload(bufnr)
      -- Seals B1 off from what review open writes, so it stays one undo step back.
      deps.break_undo_block(bufnr)
      change.undo_pre_stage_seq = deps.buf_undo_seq(bufnr)
      return bufnr, nil
    end

    local existing_modified = existing > 0
      and vim.api.nvim_buf_is_loaded(existing)
      and vim.bo[existing].modified
    if existing_modified then
      local parked = change._parked_review
      local parked_matches = parked
        and type(parked.staged_text) == "string"
        and diff.buffer_bytes_snapshot(existing) == parked.staged_text
      if parked_matches and deps.parked_dirty_explained(change, parked) then
        existing_modified = false
      end
    end
    if existing_modified then
      local current = diff.buffer_text_normalized(existing)
      local matches_review_before = diff.text_equal_snapshot(current, review_before or "")
      log.buffer_event("guard_buffer", { change = change, bufnr = existing,
        matches_review_before = matches_review_before })
      if not matches_review_before then
        local disk_bytes = diff.read_file_bytes(path)
        local matches_before = disk_bytes and diff.text_equal_snapshot(disk_bytes, change.before or "")
        local unsaved = matches_before and buffer_has_unsaved_beyond_disk(current, disk_bytes)
        log.buffer_event("guard_disk", { change = change, bufnr = existing, disk_bytes = disk_bytes,
          matches_before = matches_before, unsaved_beyond_disk = unsaved })
        if disk_bytes
          and matches_before
          and not unsaved
        then
          existing_modified = false
        end
        -- Otherwise fall back to B0 (INTERFACE.md section 4): no refusal. The buffer
        -- is not reloaded; `stage` below puts the base in it and the unsaved text
        -- stays in its undo history.
      end
    end

    local function stage(bufnr, text)
      log.buffer_event("baseline_stage_begin", { change = change, bufnr = bufnr })
      vim.fn.bufload(bufnr)
      deps.break_undo_block(bufnr)
      change.undo_pre_stage_seq = deps.buf_undo_seq(bufnr)
      local ok, err = pcall(
        vim.api.nvim_buf_set_lines,
        bufnr,
        0,
        -1,
        false,
        deps.buffer_lines(text or "")
      )
      if not ok then
        return nil, "cannot stage review in this buffer (" .. tostring(err) .. ")"
      end
      -- Unsaved operator text stays unsaved (a modified buffer is never marked clean; review_open keeps it).
      change._dirty_kept = existing_modified and true or nil
      if change._dirty_kept then
        log.lifecycle_info("review.dirty_kept", { rel = change.rel or change.path, reason = "unsaved_before_stage" })
      else
        vim.bo[bufnr].modified = false
      end
      log.buffer_event("baseline_staged", { change = change, bufnr = bufnr })
      return bufnr, nil
    end

    if change.kind == "delete" then
      if vim.fn.filereadable(path) ~= 1 then
        change.disk_at_open = nil
        return vim.fn.bufnr(path, true), nil
      end
      -- Fall back to B0 (spec buffer_state_change SPEC "Fall back to B0", BUILD row 7):
      -- a delete whose disk no longer holds the agent's base, or cannot be read, is
      -- never refused; its buffer gets B0 and the hunk is B0 against the deletion.
      local disk_bytes = diff.read_file_bytes(path)
      local matches_before = disk_bytes ~= nil
        and (change.before == nil or diff.text_equal_snapshot(disk_bytes, change.before))
      log.buffer_event("guard_disk_final", { change = change, disk_bytes = disk_bytes,
        matches_before = matches_before, outcome = matches_before and "baseline_check" or "fall_back_b0" })
      change.disk_at_open = disk_bytes
      local bufnr = vim.fn.bufnr(path, true)
      if not existing_modified then
        log.buffer_event("reload_begin", { change = change, bufnr = bufnr })
        diff.reload_file(path, { force = true })
      end
      return stage(bufnr, review_before or "")
    end

    if change.after == nil then
      return nil, NO_AFTER
    end
    if change.before == nil then
      -- An agent-created file: open an empty buffer for the path and write nothing
      -- on disk; End's save creates the file only if it is accepted (spec
      -- buffer_state_change BUILD, disk audit; BLOCKERS end-2).
      change.disk_at_open = ""
      return stage(vim.fn.bufnr(path, true), "")
    end

    -- Fall back to B0 (spec buffer_state_change SPEC "Fall back to B0", BUILD row 7):
    -- a file with no snapshot whose disk no longer holds the agent's base (changed,
    -- missing or unreadable), open or not, is never refused. Its buffer gets B0, so
    -- its hunks are B0 against the agent's revision; the disk bytes are End's evidence only.
    local disk_bytes = vim.fn.filereadable(path) == 1 and diff.read_file_bytes(path) or nil
    local matches_before = disk_bytes ~= nil and diff.text_equal_snapshot(disk_bytes, change.before)
    log.buffer_event("guard_disk_final", { change = change, disk_bytes = disk_bytes,
      matches_before = matches_before, outcome = matches_before and "baseline_check" or "fall_back_b0" })
    change.disk_at_open = disk_bytes
    local bufnr = vim.fn.bufnr(path, true)
    if not existing_modified and disk_bytes ~= nil then
      log.buffer_event("reload_begin", { change = change, bufnr = bufnr })
      diff.reload_file(path, { force = true })
    end
    return stage(bufnr, review_before)
  end

  local function open(change, preview)
    if preview then return open_impl(change, preview) end
    log.buffer_event("review_attempt", { change = change })
    local buf, err, refusal = open_impl(change, preview)
    log.buffer_event("review_result", { change = change, bufnr = buf,
      outcome = buf and "baseline_ready" or "refused", reason = err, refusal = refusal,
      -- A refusal stops before hunk building; the study records that, never a manufactured model.
      engine = (not buf) and { not_reached = "guard refused before the hunk model was built: " .. tostring(err) } or nil })
    return buf, err, refusal
  end
  return { open = open }
end

return M
