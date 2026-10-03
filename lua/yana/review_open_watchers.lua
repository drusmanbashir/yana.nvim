-- Buffer and reload watchers installed while an inline review is open.
local hunk_ledger = require("yana.hunk_ledger")

local Factory = {}

local function retired_single_file_reload_refusal(change)
  if not (change and change.single_file) then
    return nil
  end
  local name = vim.fn.fnamemodify(change.single_file.real_path or change.path or "file", ":t")
  return "retired single-file review cannot be reloaded for " .. name .. "; close it and rerun Yana on the real file"
end

--- A reload during review falls back to B0 against the agent's revision. `lines` are B0;
-- each pending hunk's lines go at the B0 rows it was built on (`b0_span`, stamped
-- at open), so no text is compared to find where a hunk belongs. Returns the
-- composed lines, the first row each hunk's lines now start at, and the B0 lines
-- each hunk replaces; or nil and a reason.
local function compose_on_b0(lines, pending)
  local order, rank = {}, {}
  for i, block in ipairs(pending) do
    if type(block.b0_span) ~= "table" then
      return nil, "a pending hunk carries no B0 rows"
    end
    order[i], rank[block] = block, i
  end
  table.sort(order, function(a, b)
    if a.b0_span.start_line ~= b.b0_span.start_line then
      return a.b0_span.start_line < b.b0_span.start_line
    end
    return rank[a] < rank[b]
  end)
  local out, relocated, olds, cursor = {}, {}, {}, 1
  for _, block in ipairs(order) do
    local s, e = block.b0_span.start_line, block.b0_span.end_line
    if s < cursor then
      return nil, "two pending hunks share B0 rows"
    end
    for i = cursor, s - 1 do
      out[#out + 1] = lines[i]
    end
    relocated[block] = #out + 1
    olds[block] = e >= s and vim.list_slice(lines, s, e) or {}
    for _, line in ipairs(block.new_lines or {}) do
      out[#out + 1] = line
    end
    cursor = e + 1
  end
  for i = cursor, #lines do
    out[#out + 1] = lines[i]
  end
  return out, relocated, olds
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
        if not require("yana.review_context").is_live_attachment(st, state) then
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
        -- A reload leaves no row Yana can trust for any hunk, and hunks are no
        -- longer moved by comparing texts: the file falls back to B0 against the
        -- agent's revision. The disk plays no part. Sealed either side, like every
        -- other product-initiated edit to this buffer; what the reload brought in
        -- stays in the undo history. THE RELOAD BARRIER: the rewrite's bytes move
        -- no membership; the composition's relocation does.
        local snap = type(change.buffer_capture) == "table" and change.buffer_capture or nil
        local b0 = snap and (change.buf_org or snap.b0) or change.review_before or change.before or ""
        local composed_lines, relocated, olds = compose_on_b0(buffer_lines(b0), state.hunk_ledger:pending())
        if not composed_lines then
          return tear_down("the file was reloaded and its review cannot fall back to B0: " .. tostring(relocated))
        end
        break_undo_block(bufnr)
        state.reload_barrier = true
        local set_ok, set_err = pcall(vim.api.nvim_buf_set_lines, bufnr, 0, -1, false, composed_lines)
        state.reload_barrier = nil
        if not set_ok then error(set_err) end
        state.hunk_ledger:relocate_membership(relocated)
        -- Reject now restores the B0 lines each hunk stands on.
        for block, old in pairs(olds) do
          state.hunk_ledger:set_old_lines(block, old)
        end
        state._ownership_dirty_rows = {}
        break_undo_block(bufnr)
        local composed = diff.buffer_bytes_snapshot(bufnr)
        state.staged_text = composed
        state.latest_undo_seq = buf_undo_seq(bufnr)
        -- The model is re-derived from the pair the review now stands on.
        local recomposed, recomposed_source = recomposed_model(b0, composed, change.path)
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
      local ready, reason = require("yana.review_watch").finalize(bufnr, state)
      if not ready then
        error("review reload refused: pending edit could not finish: " .. tostring(reason), 0)
      end
      -- FIRST ACT: 'syntax', `b:current_syntax` and 'filetype' are still whole
      -- at handler entry (they survive `buf_freeall`); the treesitter
      -- highlighter is not. Merge what is still visible into the maintained
      -- profile before doing anything that could disturb it.
      pcall(require("yana.review_reread_highlight").note_visible, bufnr)
      -- Every exit below returns from `read_review_buffer`, never from the
      -- callback, so the re-highlight cannot be skipped by an early return.
      local ok_read, err_read = pcall(function()
      local st = pool_for_state(state)
      if not require("yana.review_context").is_live_attachment(st, state) or change.kind == "delete" then
        return
      end
      local disk_now = diff.read_file_bytes(change.path)
      local base = change.disk_at_open or ""
      -- A captured buffer's review never consults the disk (buffer drift stage 1,
      -- INTERFACE.md section 1): its read is always swallowed and the review
      -- restored below; `disk_now` is used only if that restore fails.
      local captured = type(change.buffer_capture) == "table"
      -- Disk holding the review buffer's own text is the operator's `:w` of it,
      -- not a change on disk: the review is restored as for unchanged disk
      -- (CORE "Saving is Neovim's", LEDGER N51).
      local expected = state.reload_unload_text or state.staged_text
      local disk_moved = disk_now ~= base and disk_now ~= expected
      if (not captured and disk_moved) or type(state.staged_text) ~= "string" then
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
          if not require("yana.review_context").is_live_attachment(pool_for_state(state), state) then
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
          if require("yana.review_context").is_live_attachment(st, state) then
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
            local sfm_refusal = retired_single_file_reload_refusal(state.change)
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
  vim.api.nvim_create_autocmd({ "InsertEnter" }, {
    buffer = bufnr,
    group = state.augroup,
    callback = function()
      local enter = state.on_insert_enter_ownership
      if type(enter) == "function" then enter() end
    end,
  })

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
