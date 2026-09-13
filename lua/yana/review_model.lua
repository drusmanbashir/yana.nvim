local diff = require("yana.diff")

local M = {}

local function split_lines(text)
  if text == nil or text == "" then
    return {}
  end
  return vim.split(text, "\n", { plain = true })
end

-- The review target, in one place: an agent-created file has no trailing
-- newline of its own to reconcile, and the model must be derived from exactly
-- the same pair the blocks were built from.
function M.model_target(change)
  local target = change.after or ""
  if change.before == nil then
    target = target:gsub("\n$", "")
  end
  return target
end

-- ------------------------------------------------------------------ THE CHANGE MODEL
-- -- and why it is not built by M.build_diff_blocks
-- ------------------------------------------------------------------ This model is the
-- second opinion the rung-1 model-extent check measures decoration against. Its whole
-- value is INDEPENDENCE: it exists because comparing painted rows against the blocks'
-- own new-line count agrees with itself when the intended range is short.
--
-- The model is derived from the change's own DIFF TEXT, parsed by
-- `parse_unified_runs` below. Sources, most independent first:
--
--   payload_diff     `change.diff` from the agent payload.
--   payload_create   every line of a newly created file is new.
--   synthesized_diff a separately synthesized unified diff when no payload
--                    diff exists.
--   recomposed_diff  the same for the reload/compose path.
--
-- The payload runs and builder blocks need not be 1:1. `stamp_model_index`
-- joins them once while both still use the same coordinates and refuses to
-- guess when no unique run can be identified.

--- Parse unified diff text into maximal contiguous change runs, with each
--- run's first line in the new file. Returns nil unless parsing is complete.
function M.parse_unified_runs(diff_text)
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
      -- Skip diff preamble before the first hunk header.
      _ = line
    else
      local c = line:sub(1, 1)
      if c == "+" then
        open = open or { new_start_line = new_ln, new_count = 0, old_count = 0 }
        open.new_count = open.new_count + 1
        new_ln = new_ln + 1
      elseif c == "-" then
        open = open or { new_start_line = new_ln, new_count = 0, old_count = 0 }
        open.old_count = open.old_count + 1
      elseif c == " " or line == "" then
        close()
        new_ln = new_ln + 1
      elseif c == "\\" then
        -- "No newline at end of file" describes the previous line.
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
  for i, run in ipairs(runs) do
    run.index = i
  end
  return runs
end

--- Build a model from one payload and name its source.
function M.payload_model(change, target)
  if change and change.before == nil then
    local n = #split_lines(target or "")
    local out = {}
    if n > 0 then
      out[1] = { index = 1, old_count = 0, new_count = n, new_start_line = 1, new_end_line = n }
    end
    return out, "payload_create"
  end
  local runs = change and M.parse_unified_runs(change.diff)
  if runs then
    return runs, "payload_diff"
  end
  local ok, synth = pcall(diff.synthesize_diff, (change and change.before) or "", target or "", change and change.path)
  if ok then
    runs = M.parse_unified_runs(synth)
    if runs then
      return runs, "synthesized_diff"
    end
  end
  return nil, "model_unavailable"
end

--- Build a model for a reload/compose pair no payload describes.
function M.recomposed_model(base, composed, path)
  local ok, synth = pcall(diff.synthesize_diff, base or "", composed or "", path)
  if ok then
    local runs = M.parse_unified_runs(synth)
    if runs then
      return runs, "recomposed_diff"
    end
  end
  return nil, "model_unavailable"
end

-- Blocks are mutable bookkeeping; the model is fixed. Compute the join once
-- before block removal can shift list indexes and new-file coordinates.
function M.stamp_model_index(blocks, model)
  local by_start = {}
  if model then
    for i, run in ipairs(model) do
      if run.new_start_line then
        by_start[run.new_start_line] = i
      end
    end
  end
  for _, block in ipairs(blocks) do
    local new_count = #(block.new_lines or {})
    if model == nil then
      block.model_index, block.model_join = nil, "model_unavailable"
    elseif new_count == 0 then
      block.model_index, block.model_join = nil, "no_new_lines"
    else
      local model_index = by_start[block.new_start_line]
      if not model_index then
        block.model_index, block.model_join = nil, "no_payload_run_at_first_new_line"
      else
        -- Context can merge multiple model runs into one displayed block. Walk
        -- all runs starting inside that block, but derive the expected span
        -- only from model coordinates.
        local last = block.new_start_line + new_count - 1
        local model_last = model_index
        while
          model[model_last + 1]
          and model[model_last + 1].new_start_line
          and model[model_last + 1].new_start_line > block.new_start_line
          and model[model_last + 1].new_start_line <= last
        do
          model_last = model_last + 1
        end
        local accounted = true
        for start_line, index in pairs(by_start) do
          if start_line > block.new_start_line
            and start_line <= last
            and (index < model_index or index > model_last)
          then
            accounted = false
            break
          end
        end
        local span_end = model[model_last] and model[model_last].new_end_line
        if not accounted then
          block.model_index, block.model_join = nil, "block_spans_multiple_payload_runs"
        elseif model_last == model_index then
          block.model_index, block.model_join = model_index, "payload_run"
        elseif span_end == nil or span_end < block.new_start_line then
          block.model_index, block.model_join = nil, "payload_run_span_unbounded"
        else
          block.model_index, block.model_join = model_index, "payload_run_span"
          block.model_span_last = model_last
          block.model_span_new_count = span_end - model[model_index].new_start_line + 1
        end
      end
    end
  end
  return blocks
end

return M
