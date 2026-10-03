-- Where a rejected hunk's original side goes back into the buffer: the ONE rule
-- the per-hunk (`review_decisions`) and bulk (`review_lifecycle`) reject doors
-- share.
local M = {}

--- `last, delta` for writing `restored` over a hunk's live band `[first, last]`
--- (`last < first` is a pure deletion's empty band): the band's last row to
--- replace, and the change in row count.
---
--- A review whose proposal has no lines (a whole-file deletion, or a file the
--- agent emptied) shows that absence as ONE blank row, which Neovim cannot do
--- without: it is no line of the file. Restoring into such a buffer replaces that
--- row, so the buffer is the original text the moment the reject lands, not one
--- trailing blank line longer (CORE "Saving is Neovim's", LEDGER N51).
function M.span(bufnr, change, first, last, restored)
  local no_lines = change.kind == "delete" or change.after == nil or change.after == ""
  if no_lines and last < first and first == 1 and #restored > 0
    and vim.api.nvim_buf_line_count(bufnr) == 1
    and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""
  then
    last = 1
  end
  return last, #restored - ((last >= first) and (last - first + 1) or 0)
end

return M
