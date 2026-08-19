-- yana: `:YanaDump` — the diagnostic bundle logging.md promises.
--
-- One timestamped file under `stdpath("log")` holding, for the whole editor
-- session: every retained turn ledger rendered as a flow report, the review
-- pool state, the decoration snapshot (extmarks with details for both inline
-- namespaces, per-window `winhl`, resolved definitions of the Yana
-- highlight groups), and the applier diary's own introspection.
--
-- Everything here is a PURE READ. The dump never rerenders, never repairs,
-- never resolves a review, and never touches the real tree. Its only write is
-- the report file itself, which is why it is a command and not a hot path.
local M = {}

local ledger = require("yana.ledger")
local flow_report = require("yana.flow_report")

local function esc(s)
  s = tostring(s == nil and "-" or s)
  s = s:gsub("\n", " ")
  s = s:gsub("|", "\\|")
  return s
end

local function nn(v)
  if v == nil then
    return "-"
  end
  return tostring(v)
end

local function attrs_str(attrs)
  if type(attrs) ~= "table" or next(attrs) == nil then
    return "(empty — cleared or undefined)"
  end
  local keys = {}
  for k in pairs(attrs) do
    keys[#keys + 1] = k
  end
  table.sort(keys)
  local parts = {}
  for _, k in ipairs(keys) do
    local v = attrs[k]
    if k == "fg" or k == "bg" or k == "sp" then
      v = type(v) == "number" and string.format("#%06x", v) or tostring(v)
    end
    parts[#parts + 1] = k .. "=" .. tostring(v)
  end
  return table.concat(parts, " ")
end

local function section_pools(out)
  out[#out + 1] = "## Review pools and decoration state"
  out[#out + 1] = ""
  local ok, inline = pcall(require, "yana.inline_diff")
  if not ok then
    out[#out + 1] = "_inline_diff not loadable: " .. esc(inline) .. "_"
    out[#out + 1] = ""
    return
  end
  local ok_snap, snap = pcall(inline.introspect)
  if not ok_snap then
    out[#out + 1] = "_pool introspection failed: " .. esc(snap) .. "_"
    out[#out + 1] = ""
    return
  end
  out[#out + 1] = string.format("Namespaces: inline=%s hint=%s", nn(snap.ns), nn(snap.hint_ns))
  out[#out + 1] = ""
  if #snap.pools == 0 then
    out[#out + 1] = "_no review pool exists in this session_"
    out[#out + 1] = ""
    return
  end
  for _, pool in ipairs(snap.pools) do
    out[#out + 1] = string.format("### Pool `%s`", esc(pool.workspace))
    out[#out + 1] = ""
    out[#out + 1] = string.format(
      "- queued: %d · batched: %d · active: %s",
      pool.queued,
      #pool.batched,
      pool.active and esc(pool.active.rel) or "none"
    )
    for _, item in ipairs(pool.queue) do
      out[#out + 1] = string.format(
        "  - queued `%s` (status %s%s)",
        esc(item.rel),
        esc(item.status),
        item.review_error and (", refused: " .. esc(item.review_error)) or ""
      )
    end
    for _, path in ipairs(pool.batched) do
      out[#out + 1] = string.format("  - batched `%s`", esc(path))
    end
    out[#out + 1] = ""
    local active = pool.active
    if active then
      out[#out + 1] = string.format(
        "Active review: `%s` buffer %s · model source %s · hint line %s",
        esc(active.rel),
        nn(active.bufnr),
        esc(active.model_source),
        nn(active.hint_line)
      )
      if active.review_error then
        out[#out + 1] = string.format("Review error: %s", esc(active.review_error))
      end
      out[#out + 1] = ""
      out[#out + 1] = "| block | model # | rows | old → new | incoming id | deleted id |"
      out[#out + 1] = "|---|---|---|---|---|---|"
      for _, b in ipairs(active.blocks) do
        out[#out + 1] = string.format(
          "| %d | %s | %s–%s | %d → %d | %s | %s |",
          b.index,
          nn(b.model_index),
          nn(b.new_start_line),
          nn(b.new_end_line),
          b.old_count,
          b.new_count,
          nn(b.incoming_extmark_id),
          nn(b.delete_extmark_id)
        )
      end
      out[#out + 1] = ""
      local dec = active.decorations or {}
      out[#out + 1] = string.format(
        "Extmarks: %d in the inline namespace, %s in the hint namespace; buffer has %s lines, shown in %s window(s).",
        #(dec.marks or {}),
        nn(dec.hint_mark_count),
        nn(dec.line_count),
        nn(dec.window_count)
      )
      out[#out + 1] = ""
      if #(dec.marks or {}) > 0 then
        out[#out + 1] = "| id | row | end_row | end_col | hl group | prio | hl_eol | virt_lines | invalid |"
        out[#out + 1] = "|---|---|---|---|---|---|---|---|---|"
        for _, m in ipairs(dec.marks) do
          out[#out + 1] = string.format(
            "| %s | %s | %s | %s | %s | %s | %s | %s | %s |",
            nn(m.id),
            nn(m.row),
            nn(m.end_row),
            nn(m.end_col),
            esc(m.hl_group),
            nn(m.priority),
            nn(m.hl_eol),
            nn(m.virt_lines_count),
            nn(m.invalid)
          )
        end
        out[#out + 1] = ""
      end
      if #(dec.windows or {}) > 0 then
        out[#out + 1] = "| window | Yana winhl mapping intact | winhl |"
        out[#out + 1] = "|---|---|---|"
        for _, w in ipairs(dec.windows) do
          out[#out + 1] = string.format("| %s | %s | %s |", nn(w.win), w.mapped and "yes" or "**NO**", esc(w.winhl))
        end
        out[#out + 1] = ""
      end
      local names = {}
      for name in pairs(dec.groups or {}) do
        names[#names + 1] = name
      end
      table.sort(names)
      if #names > 0 then
        out[#out + 1] = "| highlight group | required | resolved attributes |"
        out[#out + 1] = "|---|---|---|"
        for _, name in ipairs(names) do
          local g = dec.groups[name]
          out[#out + 1] = string.format("| %s | %s | %s |", esc(name), g.required and "yes" or "no", esc(attrs_str(g.attrs)))
        end
        out[#out + 1] = ""
      end
      if dec.normal then
        out[#out + 1] = string.format("Normal resolves to: %s", esc(attrs_str(dec.normal)))
        out[#out + 1] = ""
      end
    end
  end
end

local function section_diary(out)
  out[#out + 1] = "## Applier diary"
  out[#out + 1] = ""
  local ok_ui, ui = pcall(require, "yana.ui")
  local session = nil
  if ok_ui and type(ui.dump_diary_session) == "function" then
    session = ui.dump_diary_session()
  end
  if not session then
    out[#out + 1] = "_no applier pass is open in this session_"
    out[#out + 1] = ""
    return
  end
  local ok, diary = pcall(require, "yana.safety.diary")
  if not ok then
    out[#out + 1] = "_diary not loadable: " .. esc(diary) .. "_"
    out[#out + 1] = ""
    return
  end
  local ok_sum, summary = pcall(diary.status_summary, session)
  if ok_sum and type(summary) == "table" then
    out[#out + 1] = string.format(
      "- operations: %s total · %s done · %s pending · %s refused%s",
      nn(summary.total),
      nn(summary.done),
      nn(summary.pending),
      nn(summary.refused),
      summary.error and (" · error: " .. esc(summary.error)) or ""
    )
    out[#out + 1] = ""
    local ids = {}
    for op_id in pairs(summary.states or {}) do
      ids[#ids + 1] = op_id
    end
    table.sort(ids)
    if #ids > 0 then
      out[#out + 1] = "| op id | file | state |"
      out[#out + 1] = "|---|---|---|"
      for _, op_id in ipairs(ids) do
        local info = summary.states[op_id]
        out[#out + 1] = string.format("| %s | %s | %s |", esc(op_id), esc(info.rel), esc(info.state))
      end
      out[#out + 1] = ""
    end
  else
    out[#out + 1] = "_status summary unavailable_"
    out[#out + 1] = ""
  end
  local ok_rows, rows = pcall(diary.journal_rows, session)
  if ok_rows and type(rows) == "table" then
    out[#out + 1] = string.format("- journal rows: %d", #rows)
    out[#out + 1] = ""
  end
  local ok_disp, displaced = pcall(diary.list_displaced, session)
  if ok_disp and type(displaced) == "table" and #displaced > 0 then
    out[#out + 1] = string.format("- displaced copies retained: %d", #displaced)
    out[#out + 1] = ""
  end
end

--- The whole bundle as markdown lines. Exposed separately from `M.write` so a
--- test can assert on the content without touching the filesystem.
function M.lines()
  local out = {
    "# Yana diagnostic dump",
    "",
    string.format("Generated %s · Neovim %s", ledger.wall_stamp(), tostring(vim.version and vim.version() or "?")),
    "",
  }
  local ok_cfg, config = pcall(require, "yana.config")
  if ok_cfg then
    out[#out + 1] = string.format(
      "Config: mode=%s · debug_record=%s · cmd=%s",
      tostring(config.options.mode),
      tostring(config.options.debug_record),
      tostring(config.options.cmd)
    )
    out[#out + 1] = ""
  end
  local ok_log, log = pcall(require, "yana.log")
  if ok_log then
    out[#out + 1] = string.format("Log file: `%s`", log.path)
    out[#out + 1] = ""
  end
  vim.list_extend(out, flow_report.report_lines())
  section_pools(out)
  section_diary(out)
  return out
end

--- Write the bundle to a timestamped file under `stdpath("log")`.
--- Returns the path, or nil plus a reason.
function M.write()
  local dir = vim.fn.stdpath("log")
  vim.fn.mkdir(dir, "p")
  local path = string.format("%s/yana-dump-%s.md", dir, os.date("%Y%m%d-%H%M%S"))
  local lines = M.lines()
  local f = io.open(path, "w")
  if not f then
    return nil, "could not open " .. path .. " for writing"
  end
  f:write(table.concat(lines, "\n"))
  f:write("\n")
  f:close()
  return path
end

return M
