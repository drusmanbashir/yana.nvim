-- Timeline surface — the list the operator reads (`:YanaTimeline` is
-- registered by the integrator in plugin/yana.lua; it wires to `M.open`).
--
-- WHY THIS SURFACE IS SHAPED THE WAY IT IS. A step that rewrites a file on
-- disk looks identical in the fingers to one that just moves a buffer. The
-- visual distinction between a DURABLE row and a BUFFER row, and the words on
-- every durable row saying that walking there rewrites a file on disk, are the
-- entire mitigation for that property — they are not decoration
-- (the timeline design contract).
--
-- WHAT THIS MODULE HOLDS. Ids, integers, labels and window handles. Never
-- bytes: restoration goes through Neovim's own tree by sequence number or
-- through the journaled applier, both behind the pinned interfaces in
-- timeline/init.lua and timeline/walk.lua. Holding a byte snapshot as
-- restoration authority was a prior defect and is not reintroduced here.
--
-- THE THREE RULES FROM THE DESIGN THAT THIS FILE ENFORCES:
--   * a row blocked by per-path LIFO renders BLOCKED and names the row that
--     must go first — a blocked row is never offered to a walk that will
--     refuse, and selecting it refuses by name without attempting;
--   * the plan (n buffer steps, n durable steps) is shown BEFORE any confirm,
--     and a walk containing any durable step confirms ONCE for the whole walk,
--     never per step;
--   * while a review is open for the file the surface is READ-ONLY and says
--     why: the operator's tools are then u, U, <C-r> and :YanaAbortReview.

local M = {}

local NS_NAME = "YanaTimelineUi"

local READ_ONLY_WHY = "while a review is open the operator's tools are u, U, <C-r> and :YanaAbortReview"

local function ensure_highlights()
  -- Durable rows must be visually distinct; the link targets are defaults so
  -- a colourscheme (or the operator) may restyle without losing the groups.
  vim.api.nvim_set_hl(0, "YanaTimelineDurable", { link = "DiffDelete", default = true })
  vim.api.nvim_set_hl(0, "YanaTimelineBlocked", { link = "Comment", default = true })
  vim.api.nvim_set_hl(0, "YanaTimelineBuffer", { link = "Normal", default = true })
  vim.api.nvim_set_hl(0, "YanaTimelineBanner", { link = "WarningMsg", default = true })
end

--- Operator messages go through one seam so the view keeps a transcript the
--- probe (and a debugging operator) can read back; the transcript records what
--- was SAID, never file content.
local function say(view, msg, level)
  view.messages[#view.messages + 1] = msg
  vim.notify(msg, level or vim.log.levels.INFO)
end

local function default_confirm(prompt)
  return vim.fn.confirm(prompt, "&Yes\n&No", 2) == 1
end

local function durable_words(rel)
  return "walking here REWRITES " .. rel .. " ON DISK"
end

--- One rendered row. `blocker` is the entry that must go first, when the row
--- is blocked by per-path LIFO.
local function row_line(view, e, ok, blocked_by, blocker)
  local head = (e.regime == "durable") and "[DURABLE]" or "[buffer ]"
  local line = string.format("%s %-8s %s", head, tostring(e.state or "?"), e.label or e.kind or e.id)
  if e.regime == "durable" then
    line = line .. " -- " .. durable_words(view.rel)
  end
  if not ok then
    local bname
    if blocker then
      bname = string.format("%q (%s)", blocker.label or blocker.kind or blocker.id, blocker.id)
    elseif blocked_by then
      bname = "(" .. tostring(blocked_by) .. ")"
    else
      bname = "a later row on this path"
    end
    line = line .. "  [BLOCKED: revert " .. bname .. " first -- per-path LIFO, newest-first]"
  end
  return line
end

local function render(view)
  local timeline = view.timeline
  local entries = timeline.entries(view.workspace, view.rel) or {}
  local by_id = {}
  for _, e in ipairs(entries) do
    by_id[e.id] = e
  end

  local lines, rows, groups = {}, {}, {}
  lines[#lines + 1] = "timeline -- " .. view.rel .. " (newest first)"
  groups[#lines] = "YanaTimelineBanner"
  if view.read_only then
    lines[#lines + 1] = "READ-ONLY: a review is open for " .. view.rel .. "; the timeline is disabled."
    groups[#lines] = "YanaTimelineBanner"
    lines[#lines + 1] = "Why: " .. READ_ONLY_WHY .. "."
    groups[#lines] = "YanaTimelineBanner"
  else
    lines[#lines + 1] = "<CR> walk to a row (one confirm per walk when any step is durable) - r refresh - q close"
  end

  -- Newest first: entries() returns oldest first, so walk it backwards.
  for i = #entries, 1, -1 do
    local e = entries[i]
    local ok, blocked_by = true, nil
    if not view.read_only then
      ok, blocked_by = timeline.reachable(view.workspace, view.rel, e.id)
    end
    lines[#lines + 1] = row_line(view, e, ok, blocked_by, blocked_by and by_id[blocked_by] or nil)
    rows[#lines] = e
    if not ok then
      groups[#lines] = "YanaTimelineBlocked"
    elseif e.regime == "durable" then
      groups[#lines] = "YanaTimelineDurable"
    else
      groups[#lines] = "YanaTimelineBuffer"
    end
  end
  if #entries == 0 then
    lines[#lines + 1] = "(no timeline rows for this file yet -- the timeline shows what it witnessed)"
  end

  local ns = vim.api.nvim_create_namespace(NS_NAME)
  vim.bo[view.buf].modifiable = true
  vim.api.nvim_buf_set_lines(view.buf, 0, -1, false, lines)
  vim.bo[view.buf].modifiable = false
  vim.api.nvim_buf_clear_namespace(view.buf, ns, 0, -1)
  for lnum, group in pairs(groups) do
    vim.api.nvim_buf_set_extmark(view.buf, ns, lnum - 1, 0, { line_hl_group = group })
  end

  view.rows = rows
  if view.win and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_set_height(view.win, math.min(math.max(#lines, 3), 14))
  end
end

--- <CR> on a row. Rechecks reachability LIVE before planning, so a row that
--- became blocked since the last render is refused by name, never attempted.
local function select_row(view)
  if not (view.win and vim.api.nvim_win_is_valid(view.win)) then
    return
  end
  local lnum = vim.api.nvim_win_get_cursor(view.win)[1]
  local e = view.rows[lnum]
  if not e then
    return
  end
  if view.read_only then
    say(view, "timeline is READ-ONLY: a review is open for " .. view.rel .. "; " .. READ_ONLY_WHY .. ".",
      vim.log.levels.WARN)
    return
  end

  local ok, blocked_by = view.timeline.reachable(view.workspace, view.rel, e.id)
  if not ok then
    local blocker
    for _, other in ipairs(view.timeline.entries(view.workspace, view.rel) or {}) do
      if other.id == blocked_by then
        blocker = other
      end
    end
    local bname = blocker and string.format("%q (%s)", blocker.label or blocker.kind or blocker.id, blocker.id)
      or (blocked_by and ("(" .. tostring(blocked_by) .. ")") or "a later row on this path")
    say(view, string.format(
      "row %q is BLOCKED: revert %s first -- durable revert is per-path LIFO, newest-first. Nothing was attempted.",
      e.label or e.id, bname), vim.log.levels.WARN)
    render(view)
    return
  end

  local plan = view.walk.plan(view.workspace, view.rel, e.id)
  if type(plan) ~= "table" then
    say(view, "timeline: walk.plan returned nothing for this row; nothing was done.", vim.log.levels.ERROR)
    return
  end
  if plan.blocked then
    say(view, string.format(
      "walk refused before starting: %q must be reverted first -- per-path LIFO. Nothing was attempted.",
      plan.blocked.label or plan.blocked.id or "?"), vim.log.levels.WARN)
    render(view)
    return
  end

  local buffer_n = plan.buffer_count or 0
  local durable_n = plan.durable_count or 0
  local total = plan.steps and #plan.steps or (buffer_n + durable_n)
  -- The plan is shown BEFORE any confirm, always.
  local shape = string.format("plan: walk back %d step(s) to %q -- %d buffer, %d durable",
    total, e.label or e.id, buffer_n, durable_n)
  say(view, shape)

  if durable_n > 0 then
    -- ONE confirm for the whole walk, never per step. The prompt repeats the
    -- shape and says in words that the walk rewrites the file on disk.
    local prompt = string.format("%s. This walk REWRITES %s ON DISK (%d durable step(s)). Walk now?",
      shape, view.rel, durable_n)
    if not view.confirm(prompt) then
      say(view, "walk not confirmed -- nothing was done.")
      return
    end
  end

  local result = view.walk.execute(view.workspace, view.rel, e.id, {}) or {}
  local committed = result.committed or {}
  if result.stopped_at then
    -- A walk is not atomic and is never described as one.
    say(view, string.format(
      "walk stopped after %d of %d step(s): %q refused%s. Committed steps stand; the cursor is at the true position and the buffer was reconciled against disk.",
      #committed, total, result.stopped_at.label or result.stopped_at.id or "?",
      result.reason and (" -- " .. result.reason) or ""), vim.log.levels.WARN)
  else
    say(view, string.format("walk complete: %d step(s) committed (%d buffer, %d durable).",
      #committed, buffer_n, durable_n))
  end
  render(view)
end

function M.close(view)
  if view and view.win and vim.api.nvim_win_is_valid(view.win) then
    vim.api.nvim_win_close(view.win, true)
  end
end

--- Workspace and file this surface targets. Explicit opts win; otherwise the
--- canonical workspace of the cwd and the current buffer's path within it.
local function derive_target(opts)
  local workspace = opts.workspace
  if not workspace then
    local ok, ci = pcall(require, "yana.claim_identity")
    workspace = (ok and ci.canonical_workspace(vim.fn.getcwd())) or vim.fn.getcwd()
  end
  local rel = opts.rel
  if not rel then
    local name = vim.api.nvim_buf_get_name(0)
    if name ~= "" then
      local abs = vim.fn.fnamemodify(name, ":p")
      local prefix = vim.fn.fnamemodify(workspace, ":p"):gsub("/+$", "") .. "/"
      if abs:sub(1, #prefix) == prefix then
        rel = abs:sub(#prefix + 1)
      else
        rel = abs
      end
    end
  end
  return workspace, rel
end

--- Open the timeline surface. The integrator wires `:YanaTimeline` to
--- this in plugin/yana.lua.
--- @param opts table|nil
---   workspace string|nil  workspace root (default: canonical workspace of cwd)
---   rel       string|nil  file the timeline is for (default: current buffer)
---   height    number|nil  initial split height
---   timeline  table|nil   injection seam for tests: the timeline interface
---   walk      table|nil   injection seam for tests: the walk interface
---   confirm   fun(prompt:string):boolean|nil  injection seam for the ONE
---             per-walk confirmation (default: vim.fn.confirm Yes/No)
--- @return table|nil view  { buf, win, workspace, rel, read_only, rows, messages }
function M.open(opts)
  opts = opts or {}
  local timeline = opts.timeline or require("yana.timeline")
  local walk = opts.walk or require("yana.timeline.walk")
  local workspace, rel = derive_target(opts)
  if not rel or rel == "" then
    vim.notify("yana timeline: no file target -- open a file or pass { rel = ... }", vim.log.levels.ERROR)
    return nil
  end

  ensure_highlights()
  local view = {
    workspace = workspace,
    rel = rel,
    timeline = timeline,
    walk = walk,
    confirm = opts.confirm or default_confirm,
    messages = {},
  }
  view.read_only = timeline.review_open_for(workspace, rel) and true or false

  view.buf = vim.api.nvim_create_buf(false, true)
  vim.bo[view.buf].buftype = "nofile"
  vim.bo[view.buf].bufhidden = "wipe"
  vim.bo[view.buf].swapfile = false
  vim.bo[view.buf].filetype = "yana_timeline"
  pcall(vim.api.nvim_buf_set_name, view.buf, "yana://timeline/" .. rel)

  view.win = vim.api.nvim_open_win(view.buf, true, { split = "below", height = opts.height or 12 })
  vim.wo[view.win].wrap = false
  vim.wo[view.win].number = false
  vim.wo[view.win].relativenumber = false
  vim.wo[view.win].signcolumn = "no"

  render(view)
  if view.read_only then
    say(view, "timeline opened READ-ONLY: a review is open for " .. rel .. "; " .. READ_ONLY_WHY .. ".",
      vim.log.levels.WARN)
  end

  local function map(lhs, fn, desc)
    vim.keymap.set("n", lhs, fn, { buffer = view.buf, nowait = true, silent = true, desc = desc })
  end
  map("<CR>", function()
    select_row(view)
  end, "yana timeline: walk to this row")
  map("r", function()
    view.read_only = timeline.review_open_for(view.workspace, view.rel) and true or false
    render(view)
  end, "yana timeline: refresh")
  map("q", function()
    M.close(view)
  end, "yana timeline: close")

  return view
end

return M
