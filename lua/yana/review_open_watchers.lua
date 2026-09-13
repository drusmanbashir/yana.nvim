-- Buffer and reload watchers installed while an inline review is open.
local hunk_ledger = require("yana.hunk_ledger")

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
  -- The autocmds die with the buffer, so this is the last moment anything can notice.
  -- Scheduled because teardown must not run inside the wipe itself.
  --
  -- But tearing down on the BARE EVENT is just as wrong in the other direction,
  -- and that is the user-reported bug: anything that re-stamps the file without
  -- changing its bytes (a formatter that reformats to the same text, a `cp`, a
  -- checkout, the agent rewriting an identical result) killed a review that was
  -- perfectly intact. G1: content is the authority, stat is only a prefilter.
  --
  -- The obvious gate -- read `v:fcs_reason` and ignore "time" (G2) -- does NOT work
  -- here, and measuring that is what saved this fix from being a no-op. 'autoread'
  -- defaults ON and the staged buffer is deliberately unmodified, so
  -- `buf_check_timestamp` takes the autoread branch and reloads BEFORE it ever computes
  -- a reason or fires FileChangedShell. Probed on this build: identical-byte touch +
  -- checktime -> shell_fired=0 post_fired=1 reason="" So no reason is available on the
  vim.api.nvim_create_autocmd({ "FileChangedShellPost" }, {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      state.fcs_post_count = (state.fcs_post_count or 0) + 1
      local buf_now = diff.buffer_bytes_snapshot(bufnr)
      local did_reload = buf_now ~= nil and state.staged_text ~= nil and buf_now ~= state.staged_text
      local reload_unload_token = nil
      if did_reload then
        state.reload_restaging = true
        state.watch_suspended = true
        reload_unload_token = (state.reload_unload_token or 0) + 1
        state.reload_unload_token = reload_unload_token
        state.ignore_next_reload_unload = reload_unload_token
        vim.defer_fn(function()
          if state.ignore_next_reload_unload == reload_unload_token then
            state.ignore_next_reload_unload = nil
          end
        end, 100)
      else
        state.ignore_next_reload_unload = nil
      end
      vim.schedule(function()
        log.guard("yana.inline_diff FileChangedShellPost", function()
        local function release_reload_restaging()
          vim.schedule(function()
            state.reload_restaging = false
            state.watch_suspended = false
          end)
        end
        local st = pool_for_state(state)
        if st.active ~= state then
          state.reload_restaging = false
          state.watch_suspended = false
          return
        end
        if not did_reload then
          state.reload_restaging = false
          state.watch_suspended = false
          return
        end
        -- Watchers stay attached; outside-hunk reload content keeps the Turn alive. A
        -- third-party edit's only consequence is a per-file loud settle refusal at
        -- end_turn (turn_settle.lua); delete-kind takes the no-write veto shape (no
        -- recreate, decided verdicts log-only). This handler's remaining job is the
        -- loud log line, nothing more.
        local function tear_down(reason, fp)
          release_reload_restaging()
          state.change.review_error = reason
          -- Every refusal from this handler is the reloaded-file refusal
          -- class. The conflict branch below adds the fingerprint pair; the
          -- branches that never got to read disk have none to add, and a
          -- missing field is honest where a fabricated one would not be.
          local L = change_ledger(state.change, state.opts)
          ledger.record_decision(L, {
            action = "review_refused",
            actor = "system",
            reason = "reloaded_file",
            detail = reason,
            change_id = state.change.id,
            rel = state.change.rel or state.change.path,
            expected_fp = fp and fp.expected_fp or nil,
            actual_fp = fp and fp.actual_fp or nil,
          })
        end
        -- A deletion review holds no on-disk `after` to compare against, so
        -- there is nothing to re-validate: keep the conservative teardown.
        if change.kind == "delete" then
          return tear_down("the file changed on disk and was reloaded; the staged hunks are gone")
        end
        local disk_now, disk_err = diff.read_file_bytes(change.path)
        if disk_now == nil then
          return tear_down(disk_err or "the file changed on disk and was reloaded; the staged hunks are gone")
        end
        local base = change.disk_at_open or ""
        local was_identical = disk_now == base
        -- Never trust a surviving extmark across a reload: a displaced
        -- `authority_extmark_id` still reads as valid. The composition says where
        -- every pending block's rows went (`relocated`), and nothing else does.
        local composed, compose_err, _, relocated = apply_review_blocks_to_reloaded_disk(base, disk_now, state.hunk_ledger:pending())
        if not composed then
          -- The one branch here that HAS both sides of the disagreement:
          -- record the fingerprint pair (truncated hashes, never contents) so
          -- "which of the three versions did the check actually see" is
          -- answerable after the fact.
          return tear_down(
            compose_err or "conflict: file changed on disk inside a reviewed hunk",
            { expected_fp = fingerprint(base), actual_fp = fingerprint(disk_now) }
          )
        end
        -- Outside-hunk disk edits (or none at all) are kept. The file's base
        -- evidence is advanced before accept, otherwise the later CAS would
        -- refuse a merge that this handler has already validated and staged.
        -- Sealed either side, like every other product-initiated edit to this
        -- buffer: the re-stage is one undo block of its own, so it neither
        -- swallows the human's last keystroke nor merges into the next
        -- decision. THE RELOAD BARRIER: the rewrite's
        -- bytes move no membership; the composition's relocation does.
        break_undo_block(bufnr)
        state.reload_barrier = true
        local set_ok, set_err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, buffer_lines(composed))
        state.reload_barrier = nil
        if not set_ok then error(set_err) end
        state.hunk_ledger:relocate_membership(relocated)
        state._ownership_dirty_rows = {}
        break_undo_block(bufnr)
        vim.bo[bufnr].modified = false
        change.disk_at_open = disk_now
        -- The CAS the applier runs immediately before the write compares
        -- `change.base_hash`, NOT `disk_at_open`: shadow/apply.lua:302-320 hands that
        -- fingerprint to the diary and the diary re-reads the file one step before the
        -- rename. Advance the fingerprint pair with the bytes, and nothing else: the
        -- read that authorises the write still happens at the applier, one step before
        -- it.
        local rehash = base_fingerprint(disk_now)
        if rehash then
          change.base_hash = rehash
          change.base_state = "file"
          local st_now = (vim.uv or vim.loop).fs_lstat(change.path)
          if st_now and st_now.mode then
            change.base_mode = st_now.mode
          end
        end
        -- `before` is the bytes a reject restores. The review now stands on
        -- the reloaded composition, so leaving it at the pre-reload base would
        -- make a reject wipe the human's outside-hunk edit out of the buffer.
        change.before = disk_now
        state.staged_text = composed
        state.latest_undo_seq = buf_undo_seq(bufnr)
        local recomposed, recomposed_source = recomposed_model(disk_now, composed, change.path)
        -- The payload the review now stands on is the reloaded composition, so the
        -- model is re-derived from that pair. Comparing the new render against the
        -- ORIGINAL model would report a violation for a legitimate rebuild, and a check
        -- that cries wolf gets ignored.
        state.model_hunks = recomposed
        state.model_source = recomposed_source
        -- This site asks for the ONE coalesced repaint instead of calling the painter
        -- itself.
        state.hunk_ledger:request_paint()
        M._emit_review_settled(bufnr, change.turn_id or change.turn_gen, "reload")
        release_reload_restaging()
        end)
      end)
    end,
  })

  -- `:edit!` clears the buffer before BufReadPost, and after that callback the
  -- old undo branch is gone. BufReadCmd is the last point where Neovim can
  -- still jump back to the exact live review state. Intercept the read there:
  -- identical disk restores that sequence, preserving human edits and every
  -- decision boundary; changed disk is loaded and the queued BufUnload handler
  -- closes the review rather than guessing a merge.
  -- Maintain this buffer's highlighting profile for the life of the review. The
  -- operator's own reads (`<C-^>` under `nohidden`, `:e`, `:e!`) arrive at the
  -- BufReadCmd below with no yana call site to have captured them.
  pcall(require("yana.review_reread_highlight").track, bufnr, state.augroup)

  vim.api.nvim_create_autocmd("BufReadCmd", {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      -- FIRST ACT: 'syntax', `b:current_syntax` and 'filetype' are still whole
      -- at handler entry (they survive `buf_freeall`); the treesitter
      -- highlighter is not. Merge what is still visible into the maintained
      -- profile before doing anything that could disturb it.
      pcall(require("yana.review_reread_highlight").note_visible, bufnr)
      -- Every exit below returns from `read_review_buffer`, never from the
      -- callback, so the re-highlight cannot be skipped by an early return.
      local ok_read, err_read = pcall(function()
      local st = pool_for_state(state)
      if st.active ~= state or change.kind == "delete" then
        return
      end
      local disk_now = diff.read_file_bytes(change.path)
      local base = change.disk_at_open or ""
      if disk_now ~= base or type(state.staged_text) ~= "string" then
        local disk_text = disk_now or ""
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(disk_text))
        local has_eol = disk_text:match("\n$") ~= nil
        vim.bo[bufnr].fixendofline = has_eol
        vim.bo[bufnr].endofline = has_eol
        vim.bo[bufnr].modified = false
        return
      end
      local token = (state.reload_unload_token or 0) + 1
      state.reload_unload_token = token
      state.ignore_next_reload_unload = token
      local expected = state.reload_unload_text or state.staged_text
      state.reload_unload_text = nil
      state.restoring_reload = true
      local restored = pcall(vim.api.nvim_buf_call, bufnr, function()
        vim.cmd("silent undo")
      end)
      state.restoring_reload = false
      local snap = restored and diff.buffer_bytes_snapshot(bufnr) or nil
      if snap ~= expected then
        state.ignore_next_reload_unload = nil
        state.reload_restore_error = "reload cleared the review's undo history; review closed without accepting anything"
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(disk_now or ""))
        vim.bo[bufnr].modified = false
        return
      end
      -- FAIL CLOSED, AND BEFORE THE RESTAGE IS BLESSED. `attach_buffer_watch`
      -- is `review_watch.attach` and answers TRUE only when Neovim really
      -- installed the callback; a reload that restored the review's bytes but
      -- could not re-watch the buffer leaves a live, painted, keymapped review
      -- that hears nothing the human types -- the same unwatched-review class
      -- the open path fails closed on. Treat it exactly like the failed-undo
      -- branch above: no restage bookkeeping, disk content in the buffer, and
      -- the review closed without accepting anything.
      if attach_buffer_watch(state) ~= true then
        state.ignore_next_reload_unload = nil
        state.reload_redo_guard = nil
        state.reload_restore_seq = nil
        state.reload_restore_error =
          "reload could not re-watch the review buffer; review closed without accepting anything"
        vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, buffer_lines(disk_now or ""))
        vim.bo[bufnr].modified = false
        return
      end
      state.staged_text = expected
      state.latest_undo_seq = buf_undo_seq(bufnr)
      state.reload_restore_seq = state.latest_undo_seq
      state.reload_redo_guard = true
      vim.bo[bufnr].modified = false
      vim.schedule(function()
        log.guard("yana.inline_diff direct reload", function()
          if pool_for_state(state).active ~= state then
            return
          end
          if not vim.api.nvim_buf_is_valid(bufnr) then
            return
          end
          -- A2: one scrub, owned by the ledger module. It also nils
          -- `nav_fallback_stated`, which this copy kept: that latch says "the
          -- warning for THIS block's marks has been given once", and the marks
          -- it referred to are being dropped on this very line.
          for _, block in ipairs(state.hunk_ledger:pending()) do
            hunk_ledger.scrub_paint(block)
          end
          -- This site asks for the ONE coalesced repaint instead of calling the painter
          -- itself.
          state.hunk_ledger:request_paint()
        end)
      end)
      end)
      -- The read this handler swallowed is the read that would have
      -- re-highlighted the buffer; `diff.reload_file` captured what was painting
      -- it just before issuing that read. See review_reread_highlight.lua.
      pcall(require("yana.review_reread_highlight").restore, bufnr)
      if not ok_read then
        error(err_read)
      end
    end,
  })

  vim.api.nvim_create_autocmd({ "BufWipeout", "BufDelete", "BufUnload" }, {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      state.reload_unload_text = diff.buffer_bytes_snapshot(bufnr)
      vim.schedule(function()
        log.guard("yana.inline_diff BufWipeout", function()
          if state.ignore_next_reload_unload then
            state.ignore_next_reload_unload = nil
            return
          end
          local st = pool_for_state(state)
          if st.active == state then
            local exiting = false
            pcall(function()
              local v = vim.v.exiting
              exiting = (v ~= nil and v ~= vim.NIL and tostring(v) ~= "" and tostring(v) ~= "0")
            end)
            if exiting then
              -- No settle, no dialog, no disk write at process death -- keep at most
              -- the do-not-reopen-while-exiting guard (this return).
              -- Behaviour-preserving: the dropped path was a pure in-memory scrub
              -- today.
              return
            end
            local sfm_refusal = require("yana.shadow.apply").single_file_accept_refusal(state.change, bufnr)
            if sfm_refusal then
              state.reload_restore_error = nil
              M._record_shadow_accept_refusal(state, sfm_refusal)
              return
            end
            -- Buffer listeners die with the buffer; the ledger record stays Turn-owned
            -- and position-frozen; a reopen reattaches the listener group and repaints
            -- from STORED MEMBERSHIP (never re-derived); undecided hunks settle
            -- normally at end_turn.
          end
        end)
      end)
    end,
  })

  vim.api.nvim_create_autocmd({ "WinEnter" }, {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      log.guard("yana.inline_diff WinEnter", apply_review_winhl, bufnr, state)
    end,
  })

  -- F-OWN-TRIGGER: authoritative ownership settle on InsertLeave. Absorbs
  -- owned insert-touched rows into the parent; splits only at human boundaries.
  -- Torn down with state.augroup — does not touch attach/generation lifecycle.
  vim.api.nvim_create_autocmd({ "InsertLeave" }, {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      local settle = state.on_insert_leave_ownership
      if type(settle) == "function" then
        log.guard("yana.inline_diff InsertLeave ownership", settle)
      end
    end,
  })

  --- Park a DECISION ANCHOR over the range this hunk occupied when it was
  --- decided, in the namespace no repaint clears. This is what an un-decide
  --- resurrects the hunk from.
  ---
  --- WHY NOT JUST KEEP THE AUTHORITY MARK. Because the very next repaint takes it:
  --- highlight_blocks clears AUTH_NS wholesale and rebuilds marks only for the blocks
  --- still in the list, so a resolved hunk's authority mark cannot survive the render
  --- that follows its own decision. A separate namespace is the same idea made
  --- repaint-proof, and it also sidesteps the freed-id reuse hazard clear_extmarks
  --- documents below: this id is never freed while the decision stands, so it cannot be
  ledger.mark(change_ledger(change, opts), "review_profile_watchers_ready")
  end
  setfenv(setup, env)
  setup()
end

return Factory
