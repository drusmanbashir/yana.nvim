-- Panel creation and lifecycle (open/close/quit/toggle). Split from yana.ui_panel.
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local V = require("yana.ui_panel_views")

local M = {}

-- The daemon data root THIS process currently points at. pcall'd: state_root() can
-- throw before yana.setup() ever ran.
local function current_state_root()
  local ok, preview = pcall(require, "yana.shadow.preview")
  if not ok then
    return nil
  end
  local ok2, root = pcall(preview.state_root)
  if not ok2 then
    return nil
  end
  return root
end

local function nvim_owner_identity()
  local pid = vim.fn.getpid()
  local boot_id = ""
  local boot_file = io.open("/proc/sys/kernel/random/boot_id", "r")
  if boot_file then
    boot_id = (boot_file:read("*l") or ""):gsub("%s+$", "")
    boot_file:close()
  end

  local start_ticks = 0
  local stat_file = io.open("/proc/self/stat", "r")
  if stat_file then
    local after = (stat_file:read("*a") or ""):match("%)%s+(.*)")
    stat_file:close()
    if after then
      start_ticks = tonumber(vim.split(after, "%s+", { trimempty = true })[20]) or 0
    end
  end

  return {
    pid = pid,
    boot_id = boot_id,
    start_ticks = start_ticks,
    servername = tostring(vim.v.servername or ""),
  }
end

-- deps.state: parent shared state `S`. deps.M: parent module table (render_greeting).
-- deps.panels / deps.panel_open / deps.buf_valid / deps.win_valid /
-- deps.new_panel_state / deps.current_panel / deps.panel_index / deps.panel_for_buf /
-- deps.prune_panels / deps.destroy_panel / deps.install_stop_on_key: parent panel
-- bookkeeping.
function M.new(deps)
  local S = deps.state
  local ui_M = deps.M
  local panels = deps.panels
  local panel_open = deps.panel_open
  local panel_open_in = deps.panel_open_in
  local buf_valid = deps.buf_valid
  local win_valid = deps.win_valid
  local new_panel_state = deps.new_panel_state
  local current_panel = deps.current_panel
  local panel_index = deps.panel_index
  local panel_for_buf = deps.panel_for_buf
  local prune_panels = deps.prune_panels
  local destroy_panel = deps.destroy_panel
  local install_stop_on_key = deps.install_stop_on_key
  local refresh_all_review_claims = deps.refresh_all_review_claims
  local stop_spinner = deps.stop_spinner
  local apply_panel_keymaps = deps.apply_panel_keymaps
  local setup_panel_autocmds = deps.setup_panel_autocmds
  local set_panel_buf_opts = deps.set_panel_buf_opts
  local open_windows = deps.open_windows
  local relayout = deps.relayout
  local ensure_prompt_win = deps.ensure_prompt_win
  local panels_in_column = deps.panels_in_column
  local show_next_after_close = deps.show_next_after_close

  -- Spend the turn parked in `p.yanad_submit_waiting`, if any. THE ONE
  -- definition: this file's session.create callback and yana.yanad_recover's
  -- session.attach callback both land here, so the clear-BEFORE-fire invariant
  -- that stops a parked turn being sent twice exists in exactly one place.
  -- Installed on every panel as `p.yanad_fire_parked_turn` (create_panel below)
  -- because yanad_recover has no access to this cluster's `S`.
  local function fire_parked_turn(p)
    local waiting = p.yanad_submit_waiting
    p.yanad_submit_waiting = nil
    if not (waiting and panel_open(p)) then
      return
    end
    vim.schedule(function()
      -- from_parked marks the ONE submit this slot is allowed to produce.
      -- submit_panel reads only `text` off opts, so the flag changes nothing
      -- in the product; it is what lets a row count parked fires apart from
      -- the operator's own submits (ui_submit.lua M._test.on_submit_panel).
      if waiting == true then
        S.submit_panel(p, { from_parked = true })
      else
        S.submit_panel(p, { text = waiting, from_parked = true })
      end
    end)
  end

  -- (Re)issue session.create for panel `p` against whatever daemon THIS process
  -- currently resolves to, and stamp the state root it was minted for.
  local function start_session_create(p)
    local yanad = require("yana.yanad")
    local ws = vim.fn.getcwd()
    local backend = (require("yana.config").options or {}).backend or "cursor"
    local rid = "panel:" .. tostring(p.conv_buf or vim.fn.hrtime()) .. ":session.create"
    p.yanad_session_pending = true
    p.yanad_session_root = current_state_root()
    yanad.session_create({
      workspace = ws,
      backend = backend,
      kind = "nvim",
      owner = nvim_owner_identity(),
    }, rid, function(ok, res)
      p.yanad_session_pending = false
      if ok and type(res) == "table" and res.session_id then
        p.yanad_session_id = res.session_id
        p.yanad_session_err = nil
        fire_parked_turn(p)
      else
        p.yanad_session_err = tostring(res)
        -- p.yanad_submit_waiting is deliberately LEFT SET. It is the turn the
        -- user already asked for, and the next submit is what re-fires
        -- session.create (ui_submit.lua's `not pending` branch) -- clearing it
        -- here would silently drop that text with nothing on screen to show
        -- the loss. It cannot fire twice: fire_parked_turn above takes the slot
        -- out BEFORE scheduling the re-submit, so the only path that spends the
        -- slot also empties it.
      end
    end)
  end

  local function panel_in_tab(tab)
    return V.panel_in_tab(panels, tab)
  end

  local function create_panel(opts)
    opts = opts or {}
    -- Deferred to first panel creation rather than module load: at load time
    -- config.setup() may not have run yet, so config.options.mappings.stop
    -- would still read the default instead of the user's configured value.
    -- install_stop_on_key() is idempotent (stop_on_key_installed guard), so
    -- this is safe to call on every panel creation.
    install_stop_on_key()
    local p = new_panel_state()
    p.mode = config.panel_mode(nil)
    -- Repaint claims on EVERY engine transition, not only on the edges this
    -- panel drives itself. Without this, a change queued behind another keeps
    -- saying "queued" for the whole time its own review is open, and a review
    -- aborted after its claim was stamped keeps saying "open" forever.
    p.unsubscribe_review = require("yana.inline_diff").on_state_change(function()
      refresh_all_review_claims(p)
    end)
    -- No p.model seed here: model is session-scoped (config.options.model is
    -- the sole authority, read fresh by every consumer), so a new panel
    -- inherits it the same way it inherits every other session setting --
    -- there is nothing panel-local left to initialise.

    -- The panel's door onto (re)issuing its own daemon session, and the one
    -- consumer of its parked turn. Installed for EVERY panel: a recovering
    -- panel skips the initial create below, but if it has no kept session to
    -- attach to, a later submit must still be able to ask for one.
    --
    -- CREATE is the default door only. A panel that is attaching to a KEPT
    -- session replaces this with a re-attach door (yana.yanad_recover.recover):
    -- creating a second daemon session for one conversation orphans whichever
    -- id loses the race, so "create" is never the answer while a kept session
    -- exists.
    p.yanad_start_session = start_session_create
    p.yanad_fire_parked_turn = fire_parked_turn

    p.conv_buf = vim.api.nvim_create_buf(false, true)
    set_panel_buf_opts(p.conv_buf, "markdown", false)
    vim.bo[p.conv_buf].modifiable = false

    p.prompt_buf = vim.api.nvim_create_buf(false, true)
    set_panel_buf_opts(p.prompt_buf, "markdown", true)
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })

    table.insert(panels, p)
    -- Release the subscription the moment the panel actually dies, rather than whenever
    -- the user next touches yana. prune_panels only runs from entry points
    -- (current_panel/is_open/panel_count), so a panel wiped by a user who then walks
    -- away kept its observer -- and the panel table, conv_buf handle and changes list
    -- behind it -- for the rest of the session. Scheduled: at BufWipeout the buffer
    -- still reads valid, so panel_alive would say the panel is fine.
    --
    -- BOTH buffers, not just conv_buf: panel_alive requires each of them, so
    -- wiping the prompt buffer alone kills the panel just as dead while firing
    -- nothing. Buffer-local autocmds die with their buffer, so there is no
    -- double-fire to guard against and prune_panels is idempotent regardless.
    for _, buf in ipairs({ p.conv_buf, p.prompt_buf }) do
      vim.api.nvim_create_autocmd("BufWipeout", {
        buffer = buf,
        callback = function()
          vim.schedule(function()
            log.guard("yana.ui BufWipeout prune_panels", prune_panels)
          end)
        end,
      })
    end
    apply_panel_keymaps(p)
    setup_panel_autocmds(p)
    open_windows(p, vim.api.nvim_get_current_tabpage())
    ui_M.render_greeting(p)
    S.last_panel = p
    -- Deliberately does NOT decide which panel the sidebar shows. That is
    -- `sidebar_panel()`'s single job below. The version of this function that
    -- claimed the role here claimed it only for a NON-additional panel, so
    -- `\an` (open_new_panel) left the role vacant while a panel existed, and
    -- open() read vacant as "no conversation exists" and built a second pane.
    -- A constructor that also decides identity is how that stayed invisible.
    --
    -- A recovery panel attaches to the kept session; creating another daemon
    -- session here would race that attach and leave an ownerless empty session.
    if not opts.recovering then
      start_session_create(p)
    end
    return p
  end

  -- Return true if any panel currently has open windows.
  local function is_open(tab)
    prune_panels()
    if tab then
      return panel_in_tab(tab) ~= nil
    end
    for _, p in ipairs(panels) do
      if panel_open(p) then
        return true
      end
    end
    return false
  end

  -- Return the live panel count, pruning dead panels first.
  local function panel_count()
    prune_panels()
    return #panels
  end

  -- Session id of the current panel (nil for a fresh chat). Handy for
  -- statuslines and tests.
  local function current_session_id()
    local p = current_panel()
    return p and p.session_id or nil
  end

  -- Focus the panel's prompt window and enter insert mode. Never switches
  -- tabpage: `tab` defaults to the current one, and if `p` has no view there
  -- yet one is built first -- nvim_set_current_win only ever targets a
  -- window already confirmed to live in `tab`.
  local function focus_prompt(p, tab)
    p = p or current_panel()
    if not p then
      return
    end
    tab = tab or vim.api.nvim_get_current_tabpage()
    local view = V.get(p, tab)
    -- A stale view (record present, windows already gone) must not skip
    -- open_windows: that is how a stacked sibling failed to return after
    -- toggle-close of its owner handed the box over mid-teardown.
    if not view or not win_valid(view.conv) then
      if view then
        V.clear(p, tab)
      end
      open_windows(p, tab)
    end
    ensure_prompt_win(p, tab)
    local prompt_win = V.prompt(p, tab)
    if win_valid(prompt_win) and vim.api.nvim_win_get_tabpage(prompt_win) == tab then
      vim.api.nvim_set_current_win(prompt_win)
      S.last_panel = p
      vim.cmd("startinsert")
    end
  end

  -- THE ONE PORTAL for building a yana side pane. `\an` (:YanaNewPanel) calls it bare
  -- and gets an additional, independent conversation stacked below whatever is already
  -- visible; every other entry point calls it ONLY after sidebar_panel() came back nil.
  -- Nothing outside this function may call create_panel -- that is the boundary, and
  -- `grep -rn "create_panel(" lua/` is the check.
  --
  --   opts.recovering  attach a kept daemon session instead of creating one
  --   opts.focus       false leaves the cursor where it stands
  local function open_new_panel(opts)
    opts = opts or {}
    local p = create_panel({ recovering = opts.recovering })
    if opts.focus ~= false then
      focus_prompt(p)
    end
    return p
  end

  -- WHICH panel the sidebar shows. TOTAL: it answers nil only when no panel
  -- exists at all, never merely because nothing claimed the role. S.primary_panel
  -- is a CACHE of this answer, not its source -- prune_panels and quit_panel may
  -- clear it at any moment and the next call re-adopts, so no caller has to know
  -- whether the role happens to be filled right now.
  local function sidebar_panel()
    prune_panels() -- drops a dead S.primary_panel
    if S.primary_panel then
      return S.primary_panel -- alive: prune_panels guarantees it
    end
    -- cursor's panel, else most recently used, else any open one, else newest
    local p = current_panel()
    -- Never claim nil: the first open() falls through to open_new_panel, which
    -- claims below. Claiming nil here left primary vacant forever, so a later
    -- reopen adopted last_panel (flipped by close-owner BufEnter on adopt).
    if p then
      S.primary_panel = p -- the ONE claim site
    end
    return p
  end

  -- Open the sidebar: reuse the conversation it already shows, or, when there
  -- is none at all, build one through the same portal `\an` uses.
  local function open()
    local tab = vim.api.nvim_get_current_tabpage()
    local policy = require("yana.ui_panel_layout_policy")
    local p = sidebar_panel() -- nil ONLY when no panel exists
    if p then
      local focus = S.last_panel or p
      if policy.is_split() then
        for _, q in ipairs(panels) do
          if not panel_open_in(q, tab) then
            open_windows(q, tab)
          end
          ensure_prompt_win(q, tab)
          if not q.unsubscribe_review then
            q.unsubscribe_review = require("yana.inline_diff").on_state_change(function()
              refresh_all_review_claims(q)
            end)
          end
          refresh_all_review_claims(q)
        end
      else
        if not panel_open_in(focus, tab) then
          open_windows(focus, tab)
        end
        if not focus.unsubscribe_review then
          focus.unsubscribe_review = require("yana.inline_diff").on_state_change(function()
            refresh_all_review_claims(focus)
          end)
        end
        refresh_all_review_claims(focus)
      end
      if focus.yanad_session_id and not focus.yanad_session_pending then
        local root = current_state_root()
        if root ~= nil and focus.yanad_session_root ~= nil and root ~= focus.yanad_session_root then
          focus.yanad_session_id = nil
          start_session_create(focus)
        end
      end
      focus_prompt(focus, tab)
      return focus
    end
    local created = open_new_panel()
    if created and not S.primary_panel then
      S.primary_panel = created
    end
    return created
  end

  -- Resolve the sidebar's primary conversation into `tab` without moving the
  -- user: open_windows builds via nvim_win_call and nothing here calls
  -- nvim_set_current_win, so the current tabpage never changes. A review
  -- must never mint a conversation, so "no panel at all" yields nil rather
  -- than falling through to the portal.
  local function open_in_tab(tab)
    local p = sidebar_panel()
    if not p then
      return nil
    end
    if not panel_open_in(p, tab) then
      open_windows(p, tab)
    end
    return p
  end


  local show_next_holder = { fn = show_next_after_close }
  local close_api
  close_api = require("yana.ui_panel_lifecycle_close").new({
    state = S,
    panels = panels,
    win_valid = win_valid,
    buf_valid = buf_valid,
    panel_index = panel_index,
    current_panel = current_panel,
    prune_panels = prune_panels,
    destroy_panel = destroy_panel,
    stop_spinner = stop_spinner,
    ensure_prompt_win = ensure_prompt_win,
    relayout = relayout,
    panel_open_in = panel_open_in,
    get_show_next = function()
      return show_next_holder.fn
    end,
    set_show_next = function(fn)
      show_next_holder.fn = fn
    end,
    open = function()
      return open()
    end,
  })

  return {
    is_open = is_open,
    panel_count = panel_count,
    current_session_id = current_session_id,
    focus_prompt = focus_prompt,
    open = open,
    open_new_panel = open_new_panel,
    open_in_tab = open_in_tab,
    quit_current = close_api.quit_current,
    quit_all = close_api.quit_all,
    close_panel = close_api.close_panel,
    close = close_api.close,
    toggle = close_api.toggle,
  }
end

return M
