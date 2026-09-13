-- Final display and first-hunk landing for an open review.
local Factory = {}

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
  local function setup()
  ledger.mark(change_ledger(change, opts), "review_profile_keymaps_ready")

  -- A mode transition is part of the decision, not optional guidance. Show it
  -- before the review becomes actionable so an immediate ca/cA cannot write a
  -- mode the operator was never shown.
  show_compound_mode(change)

  -- The closest in-process proxy for "the user can now see the review": a schedule
  -- after the render drains on the next main-loop tick, which is after the redraw the
  -- render queued.
  vim.schedule(function()
    ledger.mark(change_ledger(change, opts), "review_redraw")
  end)

  -- Synchronous end of the open path: the review exists, keymaps and watches
  -- are armed, and the user can act as soon as the next loop turn paints.
  -- Navigation to the first hunk and the compound-mode banner are display
  -- guidance, not authority, so they run on the next loop turn rather than
  -- spending the synchronous open-tail budget.
  ledger.mark(change_ledger(change, opts), "review_setup_complete")

  vim.schedule(function()
    announce_state()
    apply_review_winhl(bufnr, state)
    -- Rung 1 over the render that staged this review. It observes only, so it
    -- runs after the open-path budget closes: the diagnostic must not spend the
    -- user's review-open tail. Its inputs are the just-rendered buffer, extmarks
    -- and palette state captured above.
    render_invariant({
      site = "open",
      bufnr = bufnr,
      blocks = blocks,
      model = model,
      model_source = model_source,
      change = change,
      opts = opts,
    })
    M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "open")
    -- The first-hunk landing does NOT happen here. This callback is queued (via
    -- vim.schedule) strictly before the one below that calls focus_buf / tabnew, and
    -- vim.schedule preserves registration order -- so at this point bufnr is never yet
    -- shown in any window. The landing is issued from the next schedule below instead,
    -- right after the window that shows bufnr is attached, so win_for_buf(bufnr) is
    -- guaranteed non-nil at jump time -- an ordering fix, not a timing one.
    show_compound_mode(change)
  end)

  vim.schedule(function()
    if opts.preview then
      -- This closure outlives its caller, so it can fire AFTER a failure in
      -- the preview's own setup has already torn the session down. Opening a
      -- tab onto the dead scratch buffer then resurrects a ghost the user
      -- cannot close. Only display a session that is still the live one.
      local st = pool_for_state(state)
      if st.active ~= state then
        return
      end
      vim.cmd("tabnew")
      -- Remembered so the preview's teardown can close exactly this tab
      -- rather than leaking one tab (and one scratch buffer) per open.
      state.preview_tab = vim.api.nvim_get_current_tabpage()
      vim.api.nvim_win_set_buf(0, bufnr)
      vim.bo[bufnr].filetype = "python"
      -- tabnew+set_buf also skips WinEnter on some paths; re-apply now that
      -- a window actually shows the preview buffer.
      apply_review_winhl(bufnr, state)
      -- The window now exists (nvim_win_set_buf just attached it, above), so
      -- win_for_buf(bufnr) inside jump_to_block is guaranteed to find it.
      -- Landing here -- after the attach, in the same tick -- rather than in
      -- the earlier schedule is the fix; see the comment there.
      land_on(change.path, bufnr, initial_landing_block)
    else
      -- Same identity guard the preview branch above carries, and it was
      -- missing here: this closure fires a tick after the open, by which time
      -- the session can already be torn down.
      local st = pool_for_state(state)
      if st.active ~= state then
        return
      end
      local focused = focus_buf(change.path, bufnr)
      if not focused then
        -- focus_buf could not put the review anywhere visible (e.g. E37 from
        -- a modified current buffer with 'hidden' off). File stays a parked
        -- member of the live Turn (ledger intact); undecided hunks revert at
        -- end_turn. No cleanup / pool.active clear / queue advance (ADJUDICATED 9).
        notify_one_line(
          "yana: could not display review for `" .. (change.rel or change.path)
            .. "` — no window available; left pending",
          vim.log.levels.WARN
        )
        return
      end
      -- apply_review_winhl ran during M.open while the buffer was in no
      -- window, so wins_for_buf was empty. Opening into the current window
      -- does not fire WinEnter. Re-apply now that a window actually shows
      -- the review, or the hunks stay unmapped (PLAIN) for a single-window
      -- user.
      apply_review_winhl(bufnr, state)
      -- Same reason as apply_review_winhl above: focus_buf just attached the
      -- window that shows bufnr, so win_for_buf(bufnr) inside jump_to_block
      -- is guaranteed to find it now. This lands the cursor on the first
      -- hunk's live-authority start line (nav_start_line / live_block_range
      -- -- the same path ]x/[x use via jump_to_block), not a stale stored
      -- line -- keeping the drift-precision this call already relied on.
      land_on(change.path, bufnr, initial_landing_block)
      -- One screen line, always. Without noice, vim.notify is a plain echo: anything
      -- wider than `columns` raises a hit-enter prompt, which blocks the main loop and
      -- every queued vim.schedule behind it — the review opens and the editor then
      -- freezes until the user presses Enter. Hunk-action keys live in the sidebar
      -- button strip when it is open.
      local banner = string.format(
        "yana: review %s — %s accept · %s reject",
        change.rel,
        maps.accept_hunk,
        maps.reject_hunk
      )
      notify_one_line(banner, vim.log.levels.INFO)
    end
  end)
  end
  setfenv(setup, env)
  setup()
end

return Factory
