-- Split out of review_open.lua to meet the 500-line ceiling.
-- Keys, state table, watchers, actions, keymaps, and display tail.
local hunk_ledger = require("yana.hunk_ledger")

local Factory = {}

--- Returns `false` when there is nothing to reinstall (a preview review, or a state
--- `bind()` never finished) so the caller can fall back to the ordinary open path.
function Factory.reinstall_keys(state)
  if type(state) ~= "table" or type(state._key_defs) ~= "table" or #state._key_defs == 0 then
    return false
  end
  local bufnr = state.bufnr
  if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
    return false
  end
  for _, def in ipairs(state._key_defs) do
    vim.keymap.set(def.modes, def.key, def.handler, def.kmopts)
  end
  return true
end

function Factory.new(deps)
  local env = setmetatable({}, {
    __index = function(_, key)
      local value = deps[key]
      if value ~= nil then
        return value
      end
      return _G[key]
    end,
  })
  local function child_deps(values)
    return setmetatable(values, { __index = deps })
  end
  env.child_deps = child_deps
  local function bind()
  local maps = config.options.mappings
  local keys = {
    maps.reject_hunk,
    maps.accept_hunk,
    maps.accept_file,
    maps.accept_all,
    maps.reject_file,
    maps.next_hunk,
    maps.prev_hunk,
    -- Buffer-local for the review's lifetime only, and released with it by M.cleanup.
    -- `<C-r>` joins them because a redo that the review does not see leaves the paint
    -- describing a buffer that has moved; it must be released with them too, or the
    -- operator keeps a review-flavoured redo after the review is gone.
    "u",
    "U",
    "<C-r>",
    -- Whole-review abort (cR): same code path as `:YanaAbortReview`. Buffer-local for
    -- the review's lifetime, released by M.cleanup with the rest of `keys` on any
    -- ordinary close; `M.abort_active` itself tears every affected buffer's keys down
    -- by hand for its OWN close (its own path never reaches M.cleanup's `keys` loop).
    "cR",
    -- Turn-wide reset: hardcoded like cR, buffer-local for this review only.
    "cU",
  }

  -- Resumed-decision reconciliation: split out to
  -- review_open_bind_resume.lua to hold this file under the 500-line
  -- ceiling (S2 P-C, action 14).
  local resumed_decisions, resumed_sealed, resumed_undone = require("yana.review_open_bind_resume").reconcile(
    bufnr,
    blocks,
    parked,
    parked_undone_decisions,
    park_decision_anchor
  )

  -- LINEAGE CROSSES THE REBUILD. A resume that cannot reuse the parked state
  -- builds fresh block tables over the same buffer, and the adopted buffer
  -- history's frames name the DEAD ones. A rebuilt hunk that is the same hunk
  -- as a parked one -- which `model_index`, assigned from the immutable model
  -- mirror, is what proves -- inherits its name, so the reversal resolves by
  -- identity instead of falling back to bytes (hunk_identity.lua). A rebuilt
  -- hunk with no parked counterpart is stamped fresh by `hunk_ledger.open`
  -- below and a frame for a hunk that did not survive the rebuild resolves to
  -- nothing, which is the honest answer.
  if parked and type(parked.blocks) == "table" then
    local hunk_identity = require("yana.hunk_identity")
    local by_model_index = {}
    for _, old_block in ipairs(parked.blocks) do
      if old_block.model_index ~= nil then
        by_model_index[old_block.model_index] = old_block
      end
    end
    -- AND THE INDEXLESS ONES, THROUGH THE GENEALOGY THEY RECORDED. A split
    -- child lost its model index at `Ledger:split` and kept the parent it was
    -- carved from (`split_parent_model_index`). A slow resume re-derives the
    -- MODEL's hunks, so the parent's index comes back on one fresh block: when
    -- exactly ONE parked child of that parent survived, that block is its
    -- continuation and inherits its name, and the frames the parked history
    -- holds against the child resolve instead of refusing. Two or more children
    -- name nothing between them -- neither may hand its name on -- so ambiguity
    -- refuses, exactly as `hunk_identity.resolve_unique` does. A parked block
    -- that still HAS its index is the stronger answer and is taken above, which
    -- is why this only fills in where that found nothing.
    local sole_child_of = {}
    for _, old_block in ipairs(parked.blocks) do
      local parent = old_block.split_parent_model_index
      if parent ~= nil and old_block.lineage_id ~= nil then
        sole_child_of[parent] = (sole_child_of[parent] == nil) and old_block or false
      end
    end
    for _, block in ipairs(blocks) do
      if block.lineage_id == nil and block.model_index ~= nil then
        local ancestor = by_model_index[block.model_index]
          or sole_child_of[block.model_index] or nil
        hunk_identity.inherit(block, ancestor)
      end
    end
  end

  -- The ledger takes OWNERSHIP of the built, stamped list (A2). Verdicts ride
  -- on the hunks from here on; nothing removes an entry to record a decision.
  local L = hunk_ledger.open(blocks)
  -- A resumed file's buffer keeps the undo history the parked review recorded
  -- against, so the new ledger inherits that record rather than starting blank.
  if parked and parked.buffer_history and type(L.adopt_buffer_history) == "function" then
    L:adopt_buffer_history(parked.buffer_history)
  end

  -- `park_seq` echoes the number event 1 wrote onto
  -- `change._park_seq`/`parked.park_seq`, the join key between the two.
  -- `undone_resumed` reads `parked.undone_decisions`, a field the park never writes
  -- (observed, not changed here): it is always 0 today, which is the
  do
    log.lifecycle_info("review.resume.census", {
      rel = change.rel or change.path,
      turn_id = change.turn_id or change.turn_gen,
      park_seq = parked and parked.park_seq or nil,
      blocks_in = #blocks,
      decisions_resumed = #resumed_decisions,
      undone_resumed = (parked and parked.undone_decisions and #parked.undone_decisions) or 0,
      ledger_total_out = L:count("pending") + L:count("accepted") + L:count("rejected"),
      pending_out = L:count(),
    })
  end

  local state = {
    change = change,
    bufnr = bufnr,
    -- The one authority on this review's hunks and their verdicts.
    hunk_ledger = L,
    -- The immutable side of the render check. The ledger's pending list changes
    -- as hunks resolve; this is what the payload said, and blocks join to it by
    -- `model_index`.
    model_hunks = model,
    model_source = model_source,
    opts = opts,
    keys = keys,
    -- Bookmarks into Neovim's undo tree, and the LIFO stack of decisions this
    -- review has taken. Integers and decision records only -- no bytes are held
    -- here, so nothing here can be used as authority to restore text.
    undo_open_seq = undo_open_seq,
    latest_undo_seq = undo_seq_now,
    undo_pre_stage_seq = change.undo_pre_stage_seq,
    -- They stay one register -- each pop pushes to the shared redo stack, so `<C-r>`
    -- re-applies them as before the park. `sealed_decisions` is left empty so nothing
    -- is counted twice by the finalize/abort tallies.
    decisions = resumed_decisions,
    sealed_decisions = resumed_sealed,
    -- Kept separate from both decision tallies: an undone verdict is pending
    -- and must not let try_finalize count the same hunk as decided.
    undone_decisions = resumed_undone,
    -- What the review buffer held the last time this engine touched it. The
    -- FileChangedShellPost gate compares against this to tell "a reload put
    -- identical bytes back" (harmless) from "a reload replaced my staged
    -- hunks" (fatal). Refreshed on every hunk resolve, because rejecting a
    -- hunk writes old_lines back and the buffer stops being `after`.
    staged_text = diff.buffer_bytes_snapshot(bufnr),
    fcs_post_count = 0,
    winhl_restore = {},
    augroup = vim.api.nvim_create_augroup("YanaInlineDiff" .. change.id, { clear = true }),
    -- Starts false: nothing has happened yet.
    free_standing_edit = false,
  }

  -- `state` is an upvalue, read at fire time, so it always reflects whatever the
  -- mutation just changed (model_hunks/opts included).
  local repaint_scheduled = false
  local function repaint_now(site)
    repaint_scheduled = false
    if not state.bufnr or not vim.api.nvim_buf_is_valid(state.bufnr) then
      return
    end
    deps.render_blocks(state.bufnr, state.hunk_ledger, {
      site = site or "ledger_dirty",
      model = state.model_hunks,
      model_source = state.model_source,
      change = state.change,
      opts = state.opts,
    })
  end
  L:on_dirty(function()
    if repaint_scheduled then
      return
    end
    repaint_scheduled = true
    vim.schedule(function()
      if repaint_scheduled then
        repaint_now()
      end
    end)
  end)
  -- Every LATER signal keeps the coalescing: a decision or an on_lines edit must not
  -- paint between the ledger update and the buffer move it belongs to.
  local function flush_open_paint()
    if repaint_scheduled then
      repaint_now("ledger_open")
    end
  end

  -- `state._flush_paint` is the general form of `flush_open_paint` above: any caller
  -- holding this `state` can drain ITS OWN ledger's dirty signal synchronously.
  state._flush_paint = function(site)
    if repaint_scheduled then
      repaint_now(site or "flush_paint")
    end
  end

  local initial_landing_block
  for _, b in ipairs(blocks) do
    if b.verdict == "pending" then
      initial_landing_block = b
      break
    end
  end
  if change._retrace_land_model_index ~= nil then
    for _, b in ipairs(blocks) do
      if b.verdict == "pending" and b.model_index == change._retrace_land_model_index then
        initial_landing_block = b
        break
      end
    end
    change._retrace_land_model_index = nil
  end
  ledger.mark(change_ledger(change, opts), "review_profile_state_allocated")
  stamp_review_workspace(change, opts)
  ledger.mark(change_ledger(change, opts), "review_profile_workspace_stamped")
  -- Watch the buffer from here on: every later repaint re-derives which rows
  -- are the agent's, and this is what gives it a reason to run when the human
  -- types rather than only when a decision is taken.
  -- FAIL CLOSED. `attach_buffer_watch` is `review_watch.attach`, and it returns
  -- TRUE only when Neovim really installed the callback. Discarding that answer
  -- is how a fresh review reached the operator UNWATCHED for the third time in
  -- this lane: painted, keymapped, announced to the Turn and marked
  -- `review_profile_buffer_watched`, with nothing listening to the buffer, so
  -- no `record_buffer_change`, no absorb, no history record and no
  -- `buffer_edit` row for `u`. An open that cannot watch its buffer is not an
  -- open: unwind here, BEFORE the review becomes reachable (no keymaps, no
  -- display, no `st.active`, no Turn announcement, no
  -- `review_profile_buffer_watched` mark), and answer the ordinary
  -- `false, reason` refusal `review_open` already speaks.
  if attach_buffer_watch(state) ~= true then
    -- Nothing published this state yet; the only resources it holds are the
    -- augroup and the pending coalesced repaint, and both die here. The ledger
    -- is left to the caller's rebuild -- `hunk_ledger.open` stamped fresh
    -- lineage on blocks nobody has recorded a frame against.
    repaint_scheduled = false
    state.closed = true
    state.watch_detached = true
    pcall(vim.api.nvim_del_augroup_by_id, state.augroup)
    log.lifecycle_info("review.open.unwatched_refusal", {
      rel = change.rel or change.path,
      turn_id = change.turn_id or change.turn_gen,
      bufnr = bufnr,
    })
    return false, "review buffer could not be watched; the review was not opened"
  end
  ledger.mark(change_ledger(change, opts), "review_profile_buffer_watched")
  local st = pool_for(opts or {})
  -- A live Turn is session-wide, while review pools are workspace-scoped. A
  -- second panel can therefore add Turn files whose queue/active slots live in
  -- another pool. Resolve ownership from each change's immutable workspace
  -- stamp at End; intake stamps it when enqueueing, before End is reachable.
  local function pool_for_turn_file(file)
    local c = file and file.change
    if c and c.review_workspace then
      return pool_for({ workspace = c.review_workspace })
    end
    if file and type(file.review_opts) == "table" then
      return pool_for(file.review_opts)
    end
    return st
  end
  local state_owner = state.opts and state.opts.review_owner
  local turn_file_owner = state_owner and {
    panel_id = state_owner.panel_id,
    epoch = state_owner.epoch,
  } or nil
  local review_tabs = M._review_tabs_init_for_turn(st, change, opts or {})
  -- The button strip uses the ownership record's tab handle, not the
  -- currently focused tab. Existing operator tabs stay panel-owned; only a
  -- tab opened by Yana receives its own bottom strip.
  if review_tabs and review_tabs.owned and change.path then
    local abs = diff.abs_path(change.path)
    local owned = review_tabs.owned[abs]
    state.review_tab = owned and owned.tab_id or nil
  end
  st.active = state
  -- The pool's ONE Turn learns of this file. First sight binds the Turn, registers
  -- teardown callbacks and fires turn_start; later files just join. The v1teardown
  -- closure lets v1 pool state die with the Turn until the old doors are deleted.
	require("yana.turn_bind").observe_open(st, {
	  path = diff.abs_path(change.path),
	  ledger = state.hunk_ledger,
	  base_text = change.before or "",
	  overlay_text = state.staged_text,
    bufnr = state.bufnr,
    review_opts = state.opts,
    -- Frozen independently of the shared opts table so Turn teardown can call
    -- each panel owner once when one session-wide Turn spans several panels.
    review_owner = turn_file_owner,
    -- Turn-end status flip (RED-LEDGER matrix_s4_s8_review_open): the Turn's own End
    -- settles bytes and tears down WITHOUT the v1 finish_session_now write that retires
    -- change.status -- _poll_leave_edge reports "stay" on that branch, so
    -- review_lifecycle.lua's flip is unreachable and nothing in the Turn path writes
    -- change.status.
    change = change,
    v1_accepted_any = function()
      if state.hunk_ledger ~= nil and state.hunk_ledger:count("accepted") > 0 then
        return true
      end
      for _, list in ipairs({ state.decisions, state.sealed_decisions }) do
        for _, decision in ipairs(list or {}) do
          if decision.action == "accept" then
            return true
          end
        end
      end
      return false
    end,
  }, {
    opts_fn = function()
      return require("yana.config").options
    end,
    -- Invoked by `turn_bind.on_decision` (review_finalize.lua's `_poll_leave_edge`)
    -- only when the Turn stayed live -- the turn-wide End dialog already took the other
    -- branch. `allow_empty=true`: unlike `]x`/`[x`, this file's own ledger IS empty,
    -- that is exactly why it is being parked.
    advance = function(active_state)
      local nav = require("yana.inline_diff")
      local item = nav._ordered_target_for_state(active_state, "next")
      if item then
        nav._park_and_open_state(active_state, "next", item, nil, true)
      end
    end,
    -- E1 terminal reachability: turn_bind removes only this Turn's exact
    -- queued changes before the panel owner is released. The pool itself can
    -- contain another owner's work and must survive.
    queue_remove_change = queue_remove_change,
    queue_pool_for = pool_for_turn_file,
    tabs = {
      close_owned_tabs = function()
        pcall(M.close_owned_tabs, opts)
      end,
    },
    -- Same-name namespace ids (nvim_create_namespace is idempotent per name).
    paint_ns = vim.api.nvim_create_namespace("YanaInlineDiff"),
    authority_ns = vim.api.nvim_create_namespace("YanaInlineDiffAuthority"),
    bound_keys = (function()
      local bk = {}
      for _, k in ipairs(keys) do
        bk[#bk + 1] = { "n", k }
        bk[#bk + 1] = { "v", k }
      end
      return bk
    end)(),
    v1_teardown = function(ctx)
      -- Before either: retire each file's change.status from its own ledger verdicts
      -- (the write finish_session_now would have done on the v1 path -- see the
      -- file-entry comment in observe_open above). Guarded so a status some other door
      -- already sealed is never rewritten.
      for _, f in ipairs(ctx.turn.files) do
        local c = f.change
        if c ~= nil and c.status == "pending" then
          local accepted
          if f.v1_accepted_any ~= nil then
            accepted = f.v1_accepted_any()
          else
            accepted = f.ledger ~= nil and f.ledger:count("accepted") > 0
          end
          c.status = accepted and "accepted" or "rejected"
        end
        -- A session-wide Turn may have one active review in each workspace
        -- pool. Retire only the exact active state owned by this Turn file;
        -- another owner's active/queued work in that pool remains untouched.
        local file_pool = pool_for_turn_file(f)
        local active = file_pool and file_pool.active
        if active and active.change == c then
          pcall(M.cleanup, active)
          if file_pool.active == active then
            file_pool.active = nil
          end
        end
      end
      -- Publish the terminal view only after every ended Turn member has its
      -- final status and the active slot is gone.  An earlier notification
      -- would repaint these claims as still queued/open.
      announce_state()
    end,
  })
  -- The opening row. Recorded once the state is live, so tl_record can read the
  -- change off it, and after the buffer holds the staged content so the buffer
  -- epoch belongs to the tree the review is about to work in.
  --
  -- A reintegrated review needs no anchor of its own either way: if the operator
  -- decides it again, that decision's own predecessor in the journal is simply whatever
  -- row was already there (the file's own history did not go anywhere).
  ledger.mark(change_ledger(change, opts), "review_profile_state_ready")

  local hints = review_open_hints_factory.new(child_deps({
    state = state,
    bufnr = bufnr,
    maps = maps,
  }))
  local show_compound_mode = hints.show_compound_mode

  review_open_watchers_factory.new(child_deps({
    state = state,
    change = change,
    bufnr = bufnr,
    opts = opts,
    maps = maps,
  }))

  local actions = review_open_actions_factory.new(child_deps({
    state = state,
    change = change,
    bufnr = bufnr,
    opts = opts,
  }))
  local reject_block_at = actions.reject_block_at
  local accept_block_at = actions.accept_block_at
  local reject_hunk = actions.reject_hunk
  local accept_hunk = actions.accept_hunk
  local accept_all = actions.accept_all
  local redo_local = actions.redo_local
  -- These three report every history move to the Turn --
  -- `review_open_actions.lua` wraps them where it builds them, so the keymaps
  -- here, `state._ops` and `review_api.reset_active_review` cannot diverge.
  local redo_key = actions.redo_key
  local undo_key = actions.undo_key
  local undo_turn = actions.undo_turn
  local reject_all = actions.reject_all
  local accept_everything = actions.accept_everything

  -- The shared redo register survives park, but its callback closed over the pre-park
  -- state. Preserve stack order and point each restored row here. The register wiring
  -- that will make an in-memory register this walk's source lands in the integrator's
  -- register pass -- not yet true in this tree.

  -- `pool_for` was NOT on that list, which is exactly why cross-file `u` refused with
  -- "walk plumbing unavailable" (review_undo.lua's `pool_for_walk`) for every real
  -- review. The per-review fields below are this file's own fact; the facade's are
  -- inline_diff's and are left alone.
  local seams = M._test or {}
  M._test = seams
  for k, v in pairs({
    fault = FAULT,
    state = state,
    bufnr = bufnr,
    fcs_post_count = function()
      return state.fcs_post_count or 0
    end,
    extmark_count = function()
      return #vim.api.nvim_buf_get_extmarks(bufnr, NS, 0, -1, {})
    end,
    current_block = function()
      return current_block(state.hunk_ledger:pending(), bufnr)
    end,
    accept_hunk = accept_hunk,
    reject_hunk = reject_hunk,
    accept_block_at = accept_block_at,
    reject_block_at = reject_block_at,
    reject_all = reject_all,
    accept_all = accept_all,
    undo_turn = undo_turn,
    undo_key = undo_key,
    decisions = function()
      return state.decisions
    end,
    undo_open_seq = function()
      return state.undo_open_seq
    end,
    accept_everything = accept_everything,
    prompt_close_owned_tabs = M.prompt_close_owned_tabs,
    close_owned_tabs = M.close_owned_tabs,
    review_tabs_state_path = M.review_tabs_state_path,
  }) do
    seams[k] = v
  end

  local km = { buffer = bufnr, nowait = true, silent = true }
  ledger.mark(change_ledger(change, opts), "review_profile_test_seam_ready")
  -- Buffer-local review keymaps: split out to review_open_bind_keys.lua to
  -- hold this file under the 500-line ceiling (S2 P-C, action 14).
  require("yana.review_open_bind_keys").bind({
    state = state,
    opts = opts,
    maps = maps,
    km = km,
    log = log,
    facade = M,
    reject_hunk = reject_hunk,
    accept_hunk = accept_hunk,
    accept_all = accept_all,
    accept_everything = accept_everything,
    reject_all = reject_all,
    undo_key = undo_key,
    undo_turn = undo_turn,
    redo_key = redo_key,
  })
  require("yana.review_undo_trace").watch(state)
  review_open_display_factory.new(child_deps({
    state = state,
    change = change,
    bufnr = bufnr,
    opts = opts,
    maps = maps,
    blocks = blocks,
    model = model,
    model_source = model_source,
    initial_landing_block = initial_landing_block,
    show_compound_mode = show_compound_mode,
  }))
  -- The panel is rendered by the Turn's `review_alive` callback, never
  -- from here. This is the moment the review surface becomes reachable -- the
  -- buffer, its paint and its keymaps are all up -- so this is where the Turn
  -- is told, and the Turn decides whether that is an edge worth emitting.
  --
  -- No chrome policy rides on the review any more: the strip is sidebar
  -- chrome gated ONLY on a live Turn, and `review_tabs.sidebar_open` decides
  -- the tab MIRROR alone.
  require("yana.turn_bind").announce_review(st)
  flush_open_paint()
  return true, state
  end
  setfenv(bind, env)
  return bind()
end

return Factory
