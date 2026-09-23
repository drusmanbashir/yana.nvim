-- Panel creation and lifecycle (open/close/quit/toggle).
local config = require("yana.config")
local log = require("yana.log")
local ledger = require("yana.ledger")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local V = require("yana.panel.ui_panel_views")

local M = {}

-- Daemon data root this process points at; pcall'd: state_root() can throw before setup().
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

-- deps: parent state S, the tracked-focus owner, module M, and panel bookkeeping helpers.
function M.new(deps)
  local S = deps.state
  local focus = deps.focus
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

  -- Spend parked submits in p.yanad_submit_queue. Sole definition: session.create here and
  -- yanad_recover's session.attach both land here; queue is cleared BEFORE fire (never sent twice).
  local function fire_parked_turn(p)
    local parked = p.yanad_submit_queue
    p.yanad_submit_queue = nil
    if not (parked and #parked > 0 and panel_open(p)) then
      return
    end
    vim.schedule(function()
      -- Rest join p.queue BEFORE the first launches so a busy first inserts ahead of them; order kept.
      for i = 2, #parked do
        table.insert(p.queue, parked[i])
      end
      S.submit_panel(p, { text = parked[1], from_parked = true })
    end)
  end

  -- (Re)issue session.create against the daemon this process resolves to; stamp its state root.
  local function start_session_create(p)
    local yanad = require("yana.runtime.yanad")
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
        -- Leave p.yanad_submit_queue SET: the turns were requested and the next submit re-fires
        -- session.create; clearing would drop them silently. fire_parked_turn already emptied it.
      end
    end)
  end

  local function panel_in_tab(tab)
    return V.panel_in_tab(panels, tab)
  end

  local function create_panel(opts)
    opts = opts or {}
    -- Deferred to first panel creation: config.setup() may not have run at load. Idempotent.
    install_stop_on_key()
    local p = new_panel_state()
    p.mode = config.panel_mode(nil)
    -- Repaint claims on EVERY engine transition, not only this panel's own edges.
    p.unsubscribe_review = require("yana.inline_diff").on_state_change(function()
      refresh_all_review_claims(p)
    end)

    -- Door for (re)issuing the daemon session, installed on EVERY panel. Create is the default;
    -- a panel attaching to a KEPT session swaps in a re-attach door (yanad_recover.recover), since a
    -- second create orphans one of the ids.
    p.yanad_start_session = start_session_create
    p.yanad_fire_parked_turn = fire_parked_turn

    p.conv_buf = vim.api.nvim_create_buf(false, true)
    set_panel_buf_opts(p.conv_buf, "markdown", false)
    vim.bo[p.conv_buf].modifiable = false

    p.prompt_buf = vim.api.nvim_create_buf(false, true)
    set_panel_buf_opts(p.prompt_buf, "markdown", true)
    vim.api.nvim_buf_set_lines(p.prompt_buf, 0, -1, false, { "" })

    table.insert(panels, p)
    -- Release the review subscription when the panel dies (scheduled: at BufWipeout the buffer still
    -- reads valid). Hook BOTH buffers: panel_alive needs each; prune_panels is idempotent.
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
    focus:set_last(p)
    -- Does NOT choose the sidebar panel (sidebar_panel() owns that; claiming here left the role vacant
    -- for `\an` panels). A recovering panel attaches to the kept session; creating one would race it.
    if not opts.recovering then
      start_session_create(p)
    end
    return p
  end

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

  local function panel_count()
    prune_panels()
    return #panels
  end

  local function current_session_id()
    local p = current_panel()
    return p and p.session_id or nil
  end

  -- Focus the prompt window; never switches tabpage, builds a view in `tab` if `p` has none.
  local function focus_prompt(p, tab)
    p = p or current_panel()
    if not p then
      return
    end
    tab = tab or vim.api.nvim_get_current_tabpage()
    local view = V.get(p, tab)
    -- A stale view (windows gone) must not skip open_windows.
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
      focus:set_last(p)
      vim.cmd("startinsert")
    end
  end

  -- THE ONE PORTAL for building a side pane; nothing outside may call create_panel.
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

  -- WHICH panel the sidebar shows. TOTAL: nil only when no panel exists. The owner's
  -- primary reference is a CACHE of this answer; callers never need to know whether
  -- the role is filled.
  local function sidebar_panel()
    prune_panels() -- drops a dead primary reference
    if focus:primary() then
      return focus:primary() -- alive: prune_panels guarantees it
    end
    -- cursor's panel, else most recently used, else any open one, else newest
    local p = current_panel()
    -- Never claim nil: a vacant primary made a later reopen adopt the recent one.
    if p then
      focus:set_primary(p)
    end
    return p
  end

  local function open()
    local tab = vim.api.nvim_get_current_tabpage()
    local policy = require("yana.panel.ui_panel_layout_policy")
    local p = sidebar_panel() -- nil ONLY when no panel exists
    if p then
      local target = focus:last() or p
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
        if not panel_open_in(target, tab) then
          open_windows(target, tab)
        end
        if not target.unsubscribe_review then
          target.unsubscribe_review = require("yana.inline_diff").on_state_change(function()
            refresh_all_review_claims(target)
          end)
        end
        refresh_all_review_claims(target)
      end
      if target.yanad_session_id and not target.yanad_session_pending then
        local root = current_state_root()
        if root ~= nil and target.yanad_session_root ~= nil and root ~= target.yanad_session_root then
          target.yanad_session_id = nil
          start_session_create(target)
        end
      end
      focus_prompt(target, tab)
      return target
    end
    local created = open_new_panel()
    if created and not focus:primary() then
      focus:set_primary(created)
    end
    return created
  end

  -- Resolve the primary conversation into `tab` without moving the user (no set_current_win); a
  -- review must never mint a conversation, so no panel yields nil.
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
  close_api = require("yana.panel.ui_panel_lifecycle_close").new({
    focus = focus,
    depth = deps.depth,
    cancel_inflight = deps.cancel_inflight,
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
