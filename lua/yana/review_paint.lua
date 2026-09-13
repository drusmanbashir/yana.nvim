-- Extmark paint for inline-review hunks.
--
-- `render(bufnr, membership)` is the ONLY entry point -- membership comes from
-- `HunkLedger:paint_membership()` and names exactly what to draw: one extmark per
-- pending hunk over its own span, plus its deleted-lines virt_lines block. No content
-- matching, no row ownership guessing, no captured "prior" state: identical membership
-- always produces identical marks.
local M = {}

function M.new(deps)
  -- `keep` is a rec-plant aim, not product geometry: {first_row, last_row} (0-indexed,
  -- inclusive) that the wholesale clear must step around so the `sticky_paint = {block
  -- = k}` plant can stage "the hunk I just decided is still painted".
  local function render(bufnr, membership, keep)
    if deps.fault.sticky_paint == true then
      -- Unaimed plant: skip the wholesale clear entirely.
    elseif keep then
      vim.api.nvim_buf_clear_namespace(bufnr, deps.ns, 0, keep[1])
      vim.api.nvim_buf_clear_namespace(bufnr, deps.ns, keep[2] + 1, -1)
    else
      vim.api.nvim_buf_clear_namespace(bufnr, deps.ns, 0, -1)
    end
    vim.api.nvim_buf_clear_namespace(bufnr, deps.authority_ns, 0, -1)
    local max_col = vim.o.columns
    local line_count = vim.api.nvim_buf_line_count(bufnr)

    -- F-OWN-GAP: one pending hunk can arrive as SEVERAL membership entries, one
    -- per painted run, all sharing the same `block` table. The per-block state
    -- (cleared fields, the single delete + authority mark) is written once, on
    -- the FIRST entry for the block; every entry adds its own incoming mark, and
    -- the ids accumulate onto `block.incoming_extmark_ids`.
    local block_seen = {}
    local block_ordinal = 0
    for _, entry in ipairs(membership) do
      local block = entry.block
      local start_line = entry.start_row
      local end_line = entry.end_row
      local new_lines = entry.new_lines or {}
      local old_lines = entry.old_lines or {}

      local first_for_block = not block_seen[block]
      if first_for_block then
        block_seen[block] = true
        block_ordinal = block_ordinal + 1
        block.incoming_extmark_id = nil
        block.incoming_extmark_ids = nil
        block.delete_extmark_id = nil
        block.authority_extmark_id = nil
        block.authority_lost = nil

        local deleted_virt = vim
          .iter(old_lines)
          :map(function(line)
            return { { line .. string.rep(" ", math.max(0, max_col - #line)), deps.ext_hl.deleted } }
          end)
          :totable()
        local deleted_above = #new_lines > 0 or start_line == 1
        local deleted_row = deleted_above and (start_line - 1) or (end_line - 1)
        local clamped = math.min(math.max(deleted_row, 0), line_count - 1)
        block.delete_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, deps.ns, clamped, 0, {
          virt_lines = deleted_virt,
          virt_lines_above = deleted_above,
          hl_eol = true,
          hl_mode = "combine",
          end_row = clamped,
          right_gravity = false,
          end_right_gravity = true,
        })

        -- Authority spans the block's WHOLE stored extent (all runs), so
        -- live_block_range still reads the hunk's full live range.
        local auth_start = math.min(math.max((block.new_start_line or start_line) - 1, 0), line_count - 1)
        local auth_end = math.min(
          math.max((block.new_end_line or end_line) - 1, auth_start),
          line_count - 1
        )
        block.authority_extmark_id = vim.api.nvim_buf_set_extmark(bufnr, deps.authority_ns, auth_start, 0, {
          end_row = auth_end,
          end_col = 0,
          right_gravity = false,
          end_right_gravity = true,
        })
      end

      local end_row = end_line - 1
      local shift = (deps.fault.shift_incoming_rows
        and deps.fault.shift_incoming_rows.block == block_ordinal
        and deps.fault.shift_incoming_rows.delta)
        or 0
      local id
      if #new_lines == 0 then
        local row = math.min(math.max(start_line - 1 + shift, 0), line_count - 1)
        id = vim.api.nvim_buf_set_extmark(bufnr, deps.ns, row, 0, {
          hl_group = deps.ext_hl.incoming,
          hl_eol = true,
          hl_mode = "combine",
          priority = deps.incoming_priority,
          end_row = row,
          right_gravity = false,
          end_right_gravity = true,
        })
        block.incoming_extmark_id = block.incoming_extmark_id or id
      else
        local row = math.min(math.max(start_line - 1 + shift, 0), line_count - 1)
        id = vim.api.nvim_buf_set_extmark(bufnr, deps.ns, row, 0, {
          hl_group = deps.ext_hl.incoming,
          hl_eol = true,
          hl_mode = "combine",
          priority = deps.incoming_priority,
          end_row = math.min(math.max(end_line + shift, 0), line_count),
          end_col = 0,
          right_gravity = true,
          end_right_gravity = false,
        })
        block.incoming_extmark_ids = block.incoming_extmark_ids or {}
        block.incoming_extmark_ids[#block.incoming_extmark_ids + 1] = id
        -- `incoming_extmark_id` stays the FIRST painted mark (navigation head).
        block.incoming_extmark_id = block.incoming_extmark_id or id
      end
    end
  end

  return {
    render = render,
  }
end

return M
