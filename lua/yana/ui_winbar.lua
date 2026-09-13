-- Winbar / chip rendering for the panel conversation and prompt windows,
-- split out of yana.ui. Builds the "YANA [n] · mode · model · activity ·
-- pending · queued" string (row 65's fit algorithm shrinks segments in a
-- fixed drop order when the window is too narrow) and the prompt window's
-- own compact line.
local config = require("yana.config")
local diff = require("yana.diff")
local model_hierarchy = require("yana.model_hierarchy")
local views = require("yana.ui_panel_views")

local M = {}

-- deps.panels: parent's shared panel-registry list (same table reference).
-- deps.panel_index: parent's `panel_index(p)` -- this panel's 1-based slot, used only
-- when more than one panel is open (brand_chip's "[n]"). deps.win_valid: parent's
-- `win_valid(win)` guard before touching `vim.wo`.
function M.new(deps)
  local panels = deps.panels
  local panel_index = deps.panel_index
  local win_valid = deps.win_valid
  local liveness_text = deps.liveness_text
  local reconcile_pending = deps.reconcile_pending
  local single_file_banner = deps.single_file_banner

  local function display_mode(mode)
    return ({ ask = "Ask", inline = "Inline", agentic = "Agent" })[mode] or "Inline"
  end

  -- Row 65 / row 68: a single-character ellipsis, and a UTF8-safe (display-cell,
  -- never byte) way to cut a plain-text field down to a cell budget. Byte
  -- `:sub` truncation on a UTF8 string can land mid-character -- row 68's
  -- lesson -- and this is now shared by every field in the winbar that ever
  -- shortens itself (the model label, the echoed session title, and row 65's
  -- own last-resort core shrink).
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

  -- cap: max display cells for the "backend:model" label (default 24, as
  -- before). Row 65's last-resort core shrink calls this with a shrinking cap
  -- when even the untouchable core does not fit a genuinely narrow window.
  local function model_chip(p, cap)
    -- Sole owner: model_hierarchy.display_identity. Confirmed → normal model HL;
    -- unconfirmed → Comment (dim). Truncation must size/paint the same plain string —
    -- never swap HL under shrink.
    local id = model_hierarchy.display_identity(p)
    local limit = cap or 24
    local text = trunc_display(id.text, limit)
    local hl = id.confirmed and config.model_hl_group or "Comment"
    return string.format("model: %%#%s#%s%%*", hl, text:gsub("%%", "%%%%"))
  end

  -- no_lock: row 65's last-resort core shrink drops the "(locked)" annotation
  -- before it ever touches the model label -- cheaper information to lose,
  -- and the mode name itself still tells the operator what mode they are in.
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

  -- The spinner/state word. Factored out of winbar_text so row 65's fit
  -- computation (core_text, below) can build the identical untouchable prefix
  -- without a second, drifting copy of the spinner-state branches.
  local function state_word(p)
    local o = config.options
    local left
    if p.applying then
      -- THE GATED ACTION. CORE's Async principle licenses an accept to hold the
      -- operator's loop while its durable evidence is written, and names exactly one
      -- remedy: "Gate the ACTION briefly when its bundle is not yet published (spinner
      -- on accept)". This is that spinner.
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

  -- THE panel's name, in one place. brand_chip paints it for a conversation
  -- winbar; prompt_winbar_text needs the same letters as PLAIN text to budget
  -- the box's width against, and a second copy of "YANA" .. panel_index would
  -- be exactly the drift the prompt label exists to prevent.
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

  -- ESCAPE THE PERCENTS. p.title is the raw first line of the user's prompt, and
  -- 'winbar' is a statusline-syntax option: a bare "%" raises E539 and "%{" raises
  -- E540. So a first prompt like "cut tokens by 50%" made every update_winbar throw --
  -- including the one in on_done, which sits BEFORE maybe_drain_queue, so queued
  -- prompts stopped draining and the session stopped persisting for the rest of the
  -- session.
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

  -- `overlay` is the surviving word for the confinement layer itself;
  -- `review`/`confined` say what happens inside it.
  local function confinement_segment()
    -- Mode names already carry this distinction. Repeating implementation
    -- vocabulary here made the header noisier without adding an action.
    return ""
  end

  -- The untouchable prefix: state word, liveness, mode chip, model chip.
  -- Row 65's priority order keeps these three always present; nothing else on
  -- the bar may cause them to be dropped. cap/no_lock let the last-resort
  -- shrink in fit_winbar ask for a smaller model label or a de-locked mode
  -- chip -- still never a mid-word cut, and never the field omitted outright.
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
    -- The liveness segment sits immediately after the spinner/state word and
    -- BEFORE the mode and model chips: it is the most volatile thing on the bar
    -- and the only thing that changes while the operator is waiting. Everything
    -- to its right keeps the exact position and text it had before, so an
    -- ordinary turn looks as it always did apart from these few characters.
    --
    -- What changed is where the SHORTENING happens: `update_winbar` now computes the
    -- fit itself (see `fit_winbar` below) and installs a string that already fits,
    -- rather than trusting Neovim's own draw-time clip. That `>` is what the operator's
    -- 17:18 recording actually showed as "over>": a real character Neovim itself paints
    -- for that fallback, not an OCR-misread `<`.
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

  -- PROMPT-OWNER (F-PANEL-STACK). A stacked column keeps ONE prompt for every
  -- conversation in it, so the box must say WHOSE conversation it will submit
  -- to. That was the operator's 2026-09-08 question in full -- "theres only
  -- ONE dialog and TWO agents? how do i send messages to either agent?" --
  -- asked of a bar that named the mode and the model but never the panel.
  --
  -- The name is the SAME chip off the SAME panel_index as the conversation
  -- winbar directly above it: "YANA [2]" over the box and "YANA [2]" over the
  -- conversation are one fact, not two labels that can drift. It leads the
  -- bar and is never dropped -- with two panels open an unlabelled box IS the
  -- defect -- so the hint/mode/model split what the name leaves behind, which
  -- is what the width budget below measures.
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
    -- Same string trunc_display paints; HL from confirmed alone (F1: never
    -- let truncation flip dim↔normal).
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

  -- Returns the DISPLAY-CELL width nvim_eval_statusline would actually paint
  -- for `str` in `winid` -- Neovim's own ruler, multibyte-safe, and immune to
  -- the difference between `%#hl#...%*` highlight bytes and visible columns
  -- (row 68: never count bytes). A huge maxwidth asks for the NATURAL width,
  -- unclipped, so the caller can compare it against the real window width
  -- itself rather than trust Neovim's clipper to have done that already.
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

  -- Row 65: THE FIX. A winbar that does not fit the window must SAY it was shortened
  -- (one trailing "…", never a bare Neovim draw-time clip) and must drop whole SEGMENTS
  -- from the right rather than cut a word. Confinement is dropped LAST among the
  -- droppables because it is the one safety fact among them -- whether the agent is
  -- writing confined or direct -- so it survives longer than a bare count.
  --
  -- `nvim_eval_statusline` is the fit oracle throughout, exactly as the row
  -- specifies: never a byte count, always Neovim's own display-cell ruler.
  local WINBAR_DROP_ORDER = { "session", "pending", "queued", "shell_fail", "confinement" }

  local function fit_winbar(p, winid)
    local full = winbar_text(p)
    local width = win_valid(winid) and vim.api.nvim_win_get_width(winid) or nil
    if width == nil or width <= 0 then
      return full
    end
    local full_w = natural_width(full, winid)
    if full_w == nil or full_w <= width then
      -- Fits, or unmeasurable (fail OPEN to the full text rather than guess).
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

    -- Every droppable segment is gone and the untouchable core (state,
    -- liveness, mode, model) still does not fit. Keep shrinking, cheapest
    -- information first: the "(locked)" annotation (the mode name itself
    -- still shows), then the model label one character at a time -- always
    -- keeping its vendor prefix, since that is exactly the fact row 58
    -- exists to protect -- never dropping the field outright.
    local core_bare = core_text(p, nil, true) .. " " .. WINBAR_ELLIPSIS
    local bare_w = natural_width(core_bare, winid)
    if bare_w ~= nil and bare_w <= width then
      return core_bare
    end

    -- Same source as model_chip itself (display_identity) — this is only a
    -- loop bound, but a mismatched source could size the shrink search for
    -- the wrong label.
    local id = model_hierarchy.display_identity(p)
    local max_chars = vim.fn.strchars(id.text)
    for cap = max_chars - 1, 0, -1 do
      local cand = core_text(p, cap, true) .. " " .. WINBAR_ELLIPSIS
      local cw = natural_width(cand, winid)
      if cw ~= nil and cw <= width then
        return cand
      end
    end

    -- A pathologically narrow window: state word and a bare mode name are all
    -- that is left to show, but they are still never cut mid-word.
    return core_text(p, 0, true) .. " " .. WINBAR_ELLIPSIS
  end

  local function update_winbar(p)
    views.each(p, function(view)
      if win_valid(view.conv) then
        -- Cosmetic chrome must never be able to abort its caller. Escaping (above)
        -- removes the known trigger; this removes the whole class of consequence.
        pcall(function()
          vim.wo[view.conv].winbar = fit_winbar(p, view.conv)
        end)
      end
      if win_valid(view.prompt) then
        pcall(function()
          vim.wo[view.prompt].winbar = single_file_banner(p) or prompt_winbar_text(p, view.prompt)
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
