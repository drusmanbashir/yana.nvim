-- Open and stage buffers for inline review without writing proposal bytes.
local diff = require("yana.diff")
local log = require("yana.log")

local M = {}

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
        else
          return nil, "buffer has unsaved edits unrelated to this review", { reason = "dirty_buffer" }
        end
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
      vim.bo[bufnr].modified = false
      log.buffer_event("baseline_staged", { change = change, bufnr = bufnr })
      return bufnr, nil
    end

    if change.kind == "delete" then
      if vim.fn.filereadable(path) ~= 1 then
        change.disk_at_open = nil
        return vim.fn.bufnr(path, true), nil
      end
      local disk_bytes, err = diff.read_file_bytes(path)
      if disk_bytes == nil then
        return nil, err or "could not read file for review"
      end
      if change.before ~= nil and not diff.text_equal_snapshot(disk_bytes, change.before) then
        log.buffer_event("guard_disk_final", { change = change, disk_bytes = disk_bytes, matches_before = false })
        return deps.stale_refusal("file on disk changed since turn start", change.before, disk_bytes)
      end
      log.buffer_event("guard_disk_final", { change = change, disk_bytes = disk_bytes, matches_before = true })
      change.disk_at_open = disk_bytes
      local bufnr = vim.fn.bufnr(path, true)
      if not existing_modified then
        log.buffer_event("reload_begin", { change = change, bufnr = bufnr })
        diff.reload_file(path, { force = true })
      end
      return stage(bufnr, review_before or "")
    end

    if change.after == nil then
      return nil, "agent payload carried no after-content for this edit (nothing to review)"
    end
    if change.before == nil then
      -- The guard this replaces refused every existing path outright ("the
      -- agent-created file has no empty base to review against") -- after the touch
      -- that is always true, and every created-file review would refuse to open. It
      -- was, and still is, an anti-EXTERNAL-WRITER guard, so it now asks the question
      -- its own reason asks: is what is at this path yana's own empty touch (or
      -- nothing), or did somebody else write CONTENT here?
      local creation_touch = require("yana.paths.creation_touch")
      local ok_touch, terr = creation_touch.touch(path)
      if not ok_touch then
        return nil, tostring(terr), { reason = "stale_file" }
      end
      -- The BYTE baseline of a touched file is the empty string -- the touch happened
      -- at proposal time, before any decision -- so the review opens against `""`
      -- exactly as any other file opens against its own bytes.
      change.disk_at_open = ""
      local bufnr = vim.fn.bufnr(path, true)
      -- The buffer may have been created while the path was still ABSENT (the panel
      -- names a proposed file before the review opens), and Vim then carries it as a
      -- NEW file. Re-stat through a forced reload so Vim's view of the file matches the
      -- empty file that is really there.
      if not existing_modified then
        log.buffer_event("reload_begin", { change = change, bufnr = bufnr })
        diff.reload_file(path, { force = true })
      end
      return stage(bufnr, "")
    end

    if vim.fn.filereadable(path) ~= 1 then
      if vim.fn.getftype(path) ~= "" then
        return nil, "file exists but is not readable", { reason = "stale_file" }
      end
      return nil, "file missing on disk for review", { reason = "stale_file" }
    end
    local disk_bytes, err = diff.read_file_bytes(path)
    if disk_bytes == nil then
      return nil, err or "could not read file bytes from disk"
    end
    local disk_is_turn_start = diff.text_equal_snapshot(disk_bytes, change.before)
    local disk_is_accepted_save = not disk_is_turn_start
      and change._accept_composed_hash ~= nil
      and deps.base_fingerprint(disk_bytes) == change._accept_composed_hash
    log.buffer_event("guard_disk_final", { change = change, disk_bytes = disk_bytes,
      matches_before = disk_is_turn_start, outcome = disk_is_accepted_save and "accepted_save" or "baseline_check" })
    if not (disk_is_turn_start or disk_is_accepted_save) then
      return deps.stale_refusal("file on disk changed since turn start", change.before, disk_bytes)
    end
    change.disk_at_open = disk_bytes
    local bufnr = vim.fn.bufnr(path, true)
    if not existing_modified then
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
