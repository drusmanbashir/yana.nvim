-- Bulk-accept disclosure, emitted before any queued file is written.
local M = {}

function M.emit(state, drained, log, notify_one_line)
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

  -- Durable too, since INFO never reaches disk (log.lua) and this is the half a live
  -- run is read back for.
  local parked_covered = 0
  for _, item in ipairs(drained) do
    if item.change and item.change._parked_review then
      parked_covered = parked_covered + 1
    end
  end
  if parked_covered > 0 then
    local parked_msg = string.format(
      "yana: accept-all covers %d parked change(s) -- parking is navigation, not a decision",
      parked_covered
    )
    log.write("WARN", parked_msg)
    notify_one_line(parked_msg, vim.log.levels.INFO)
  end
end

return M
