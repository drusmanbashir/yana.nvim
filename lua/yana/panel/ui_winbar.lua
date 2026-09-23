-- Winbar / chip rendering for the panel conversation and prompt windows. Segments shrink in a fixed drop order
-- when the window is too narrow (fit_winbar); the prompt window gets its own compact line.
local config = require("yana.config")
local diff = require("yana.diff")
local model_hierarchy = require("yana.agent.model_hierarchy")
local views = require("yana.panel.ui_panel_views")

local M = {}

-- deps.panels: shared registry list; panel_index: 1-based slot (used only when >1 panel); win_valid: guard before vim.wo.
function M.new(deps)
  local panels = deps.panels
  local panel_index = deps.panel_index
  local win_valid = deps.win_valid
  local liveness_text = deps.liveness_text
  local reconcile_pending = deps.reconcile_pending

  local function display_mode(mode)
    return ({ ask = "Ask", inline = "Inline", agentic = "Agent" })[mode] or "Inline"
  end

  -- UTF8-safe truncation by display cells, never bytes (a byte :sub can cut mid-character); shared by every
  -- shortening winbar field.
  local WINBAR_ELLIPSIS = "…"

  local function trunc_display(text, max_cells)
    if max_cells <= 0 then
      return ""
    end
    if vim.fn.strdisplaywidth(text) <= max_cells then
      return text
    end
    local ell_w = vim.fn.strdisplaywidth(WINBAR_ELLIPSIS)
    local budget = math.max(0, max_cells - ell_w)
    local nchars = vim.fn.strchars(text)
    local lo, hi = 0, nchars
    while lo < hi do
      local mid = math.floor((lo + hi + 1) / 2)
      if vim.fn.strdisplaywidth(vim.fn.strcharpart(text, 0, mid)) <= budget then
        lo = mid
      else
        hi = mid - 1
      end
    end
    return vim.fn.strcharpart(text, 0, lo) .. WINBAR_ELLIPSIS
  end

  -- cap: max display cells for the model label (default 24); the last-resort core shrink passes a smaller one.
  local function model_chip(p, cap)
    -- Sole owner: model_hierarchy.display_identity. Confirmed -> model HL, else Comment (dim). Truncation must
    -- size/paint the same plain string; never swap HL under shrink.
    local id = model_hierarchy.display_identity(p)
    local limit = cap or 24
    local text = trunc_display(id.text, limit)
    local hl = id.confirmed and config.model_hl_group or "Comment"
    return string.format("model: %%#%s#%s%%*", hl, text:gsub("%%", "%%%%"))
  end

  -- no_lock: the last-resort shrink drops "(locked)" before touching the model label.
  local function mode_chip(p, no_lock)
    local mode = config.resolve_mode(p.mode)
    local label = display_mode(mode)
    local locked = ""
    local text = label .. locked
    local hl = config.mode_hl_groups[mode]
    if hl then
      return string.format("%%#%s#%s%%*", hl, text:gsub("%%", "%%%%"))
    end
    return text
  end

  -- Spinner/state word, shared by winbar_text and core_text so the prefix has one copy.
  local function state_word(p)
    local o = config.options
    local left
    if p.applying then
      -- The gated ACTION: CORE's Async principle lets an accept hold the loop briefly while durable evidence is written.
      local frame = o.ui.spinner[p.spinner.idx] or ""
      left = frame .. " Applying"
    elseif p.busy then
      local frame = o.ui.spinner[p.spinner.idx] or ""
      left = frame .. " Thinking"
    elseif p.awaiting_exit then
      left = p.pending_redirect and "Redirecting" or "Stopping"
    else
      left = ""
    end
    return left
  end

  -- THE panel's name in one place: brand_chip paints it, prompt_winbar_text budgets width against the same plain text.
  local function brand_label(p)
    local label = "YANA"
    if #panels > 1 then
      label = label .. " [" .. panel_index(p) .. "]"
    end
    return label
  end

  local function brand_chip(p)
    return "%#Title#" .. brand_label(p) .. "%*"
  end

  local function activity_segment(p)
    local state = state_word(p)
    return state ~= "" and (" · " .. state) or ""
  end

  -- ESCAPE THE PERCENTS: 'winbar' is statusline syntax, so a bare "%" in p.title raises E539 ("%{" E540); an
  -- update_winbar throw in on_done (before maybe_drain_queue) would stop queue draining and session persistence.
  local function session_segment(p)
    local sess
    if p.title and p.title ~= "" then
      sess = trunc_display(p.title, 24)
      sess = sess:gsub("%%", "%%%%")
    else
      sess = p.session_id and "session" or "new"
    end
    return sess
  end

  local function pending_segment(p)
    local pending = #diff.pending(p.changes)
    reconcile_pending(p, pending)
    return pending > 0 and (" · " .. pending .. " pending") or ""
  end

  local function queued_segment(p)
    local qn = #p.queue
    local promoted = p.steer_pending and " · 1 promoted" or ""
    return qn > 0 and (" · " .. qn .. " queued" .. promoted) or promoted
  end

  local function shell_fail_segment(p)
    if not p.busy and not p.awaiting_exit and (p.shell_steps_failed or 0) > 0 then
      return string.format(
        " · %d command failed (exit %s)",
        p.shell_steps_failed,
        tostring(p.first_failed_shell_exit or "?")
      )
    end
    return ""
  end

  -- `overlay` names the confinement layer; `review`/`confined` say what happens inside it.
  local function confinement_segment()
    -- Mode names already carry this distinction.
    return ""
  end

  -- The untouchable prefix (state, liveness, mode, model); cap/no_lock let fit_winbar shrink the model label or
  -- drop "(locked)" but never omit the field.
  local function core_text(p, cap, no_lock)
    return string.format(
      "%s · %s%s%s · %s",
      brand_chip(p),
      mode_chip(p, no_lock),
      activity_segment(p),
      liveness_text(p),
      model_chip(p, cap)
    )
  end

  local function winbar_text(p)
    local pend = pending_segment(p)
    local queued = queued_segment(p)
    local shell_fail = shell_fail_segment(p)
    local confinement = confinement_segment()
    local sess = session_segment(p)
    -- Liveness sits right after the state word: the most volatile segment. update_winbar computes the fit itself
    -- (fit_winbar) rather than trusting Neovim's draw-time clip, whose ">" is a real painted character.
    return string.format(
      "%s · %s%s%s · %s%s%s%s%s%%<  · %s",
      brand_chip(p),
      mode_chip(p),
      activity_segment(p),
      liveness_text(p),
      model_chip(p),
      pend,
      queued,
      shell_fail,
      confinement,
      sess
    )
  end

  -- PROMPT-OWNER: a stacked column has ONE prompt for every conversation in it, so the box must name whose
  -- conversation it submits to. Same chip/panel_index as the conversation winbar (one fact, not two labels);
  -- it leads and is never dropped; hint/mode/model split what remains within the width budget.
  local function prompt_winbar_text(p, win)
    win = win or views.prompt(p)
    local width = win_valid(win) and vim.api.nvim_win_get_width(win) or 0
    local owner = brand_label(p)
    local budget = width > 0 and (width - vim.fn.strdisplaywidth(owner) - 5) or 0
    local left = width > 0 and budget < 24 and "Prompt" or "Send follow-up…"
    if width > 0 and budget < 36 then
      return string.format("  %%#Title#%s%%*%%#Comment# · %s %%*", owner, left)
    end
    local mode = display_mode(config.resolve_mode(p.mode))
    local id = model_hierarchy.display_identity(p)
    -- Same string trunc_display paints; HL from confirmed alone (never let truncation flip dim/normal).
    local text = trunc_display(id.text, 16)
    local model = text:gsub("%%", "%%%%")
    local model_hl = id.confirmed and config.model_hl_group or "Comment"
    return string.format(
      "  %%#Title#%s%%*%%#Comment# · %s %%*%%=%%#Comment# %s · %%#%s#%s  %%*",
      owner,
      left,
      mode,
      model_hl,
      model
    )
  end

  -- Display-cell width nvim_eval_statusline would paint (multibyte-safe, ignores %#hl# bytes; never count bytes).
  -- A huge maxwidth asks for the unclipped natural width so the caller compares it to the window itself.
  local function natural_width(str, winid)
    local ok, res = pcall(vim.api.nvim_eval_statusline, str, {
      winid = winid,
      use_winbar = true,
      maxwidth = 100000,
    })
    if not ok or type(res) ~= "table" or type(res.width) ~= "number" then
      return nil
    end
    return res.width
  end

  -- A winbar that does not fit must SAY it was shortened (one trailing "…") and drop whole SEGMENTS from the right,
  -- never cut a word. Confinement is dropped LAST among droppables (it is the one safety fact).
  -- nvim_eval_statusline is the fit oracle throughout.
  local WINBAR_DROP_ORDER = { "session", "pending", "queued", "shell_fail", "confinement" }

  local function fit_winbar(p, winid)
    local full = winbar_text(p)
    local width = win_valid(winid) and vim.api.nvim_win_get_width(winid) or nil
    if width == nil or width <= 0 then
      return full
    end
    local full_w = natural_width(full, winid)
    if full_w == nil or full_w <= width then
      -- Fits, or unmeasurable (fail OPEN to the full text).
      return full
    end

    local pieces = {
      pending = pending_segment(p),
      queued = queued_segment(p),
      shell_fail = shell_fail_segment(p),
      confinement = confinement_segment(),
      session = " · " .. session_segment(p),
    }
    local core = core_text(p)

    local function assemble(keep, shortened)
      local buf = { core }
      for _, name in ipairs({ "pending", "queued", "shell_fail", "confinement", "session" }) do
        if keep[name] then
          buf[#buf + 1] = pieces[name]
        end
      end
      local out = table.concat(buf)
      if shortened then
        out = out .. " " .. WINBAR_ELLIPSIS
      end
      return out
    end

    local keep = { pending = true, queued = true, shell_fail = true, confinement = true, session = true }
    for _, name in ipairs(WINBAR_DROP_ORDER) do
      keep[name] = nil
      local cand = assemble(keep, true)
      local cw = natural_width(cand, winid)
      if cw ~= nil and cw <= width then
        return cand
      end
    end

    -- Untouchable core still does not fit: drop "(locked)" first, then shrink the model label per character,
    -- keeping its vendor prefix; never drop the field.
    local core_bare = core_text(p, nil, true) .. " " .. WINBAR_ELLIPSIS
    local bare_w = natural_width(core_bare, winid)
    if bare_w ~= nil and bare_w <= width then
      return core_bare
    end

    -- Same source as model_chip (display_identity); only a loop bound.
    local id = model_hierarchy.display_identity(p)
    local max_chars = vim.fn.strchars(id.text)
    for cap = max_chars - 1, 0, -1 do
      local cand = core_text(p, cap, true) .. " " .. WINBAR_ELLIPSIS
      local cw = natural_width(cand, winid)
      if cw ~= nil and cw <= width then
        return cand
      end
    end

    -- Pathologically narrow: state word and bare mode name, never cut mid-word.
    return core_text(p, 0, true) .. " " .. WINBAR_ELLIPSIS
  end

  local function update_winbar(p)
    views.each(p, function(view)
      if win_valid(view.conv) then
        -- Cosmetic chrome must never abort its caller (escaping removes the known trigger; this the whole class).
        pcall(function()
          vim.wo[view.conv].winbar = fit_winbar(p, view.conv)
        end)
      end
      if win_valid(view.prompt) then
        pcall(function()
          vim.wo[view.prompt].winbar = prompt_winbar_text(p, view.prompt)
        end)
      end
    end)
  end


  return {
    update_winbar = update_winbar,
    winbar_text = winbar_text,
    prompt_winbar_text = prompt_winbar_text,
    fit_winbar = fit_winbar,
    mode_chip = mode_chip,
    model_chip = model_chip,
    trunc_display = trunc_display,
  }
end

return M
