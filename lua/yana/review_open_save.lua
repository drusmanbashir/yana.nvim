-- Split out of review_open_actions.lua to meet the 500-line ceiling.
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
    -- BufWriteCmd on the review buffer. `:w!` is IDENTICAL to `:w` -- withholding is
    -- not a refusal, so `!` has nothing to force. Product saves use `noautocmd write!`
    -- (diff.save_buffer) and bypass this handler entirely; keep it that way.
    --
    -- The representation relied on is `state.hunk_ledger:pending()`. Either way this
    -- loop iterates exactly the undecided hunks.
    --
    -- THE WRITE MECHANISM, and why it is neither of the two obvious ones.
    -- `diff.save_buffer` writes the buffer VERBATIM (diff.lua:494-499) and so cannot
    -- write a composition at all.
    --
    -- What is NOT recovered by construction: Neovim's recorded file info for this
    -- buffer, because the bytes did not travel through `buf_write`. Neovim exposes no
    -- way to re-stamp it that does not RELOAD the buffer, and a reload would replace
    -- the review composition. * a `:checktime` in between lands on the
    -- FileChangedShellPost handler's tier-1 branch, which is exactly why `disk_at_open`
    -- advances to the bytes written and `state.staged_text` stays the BUFFER snapshot
    vim.api.nvim_create_autocmd({ "BufWriteCmd", "FileWriteCmd", "FileAppendCmd" }, {
      buffer = bufnr,
      group = state.augroup,
      callback = function(ev)
       log.guard("yana.inline_diff " .. ev.event, function()
        -- <amatch> is the write's actual target (the argument to `:w`, or the buffer's
        -- own name for a bare `:w`).
        local target = vim.fn.expand("<amatch>")
        local own = diff.abs_path(change.path)
        if target ~= "" then
          target = diff.abs_path(target)
        end
        local to_own = (target == "" or target == own)

        -- Clip to the buffer's current extent defensively.
        local total = vim.api.nvim_buf_line_count(bufnr)
        local q1 = math.max(1, vim.fn.line("'["))
        local q2 = math.min(total, math.max(q1, vim.fn.line("']")))
        local is_full_range = (q1 <= 1 and q2 >= total)
        local is_append = (ev.event == "FileAppendCmd")

        -- Binary is already safe: buffer_bytes_snapshot refuses a binary
        -- buffer or one holding NUL bytes (diff.lua:563-570), and this bails
        -- with the named reason rather than composing bytes it cannot encode.
        -- The snapshot is also what `state.staged_text` is set from below.
        local snap, snap_err = diff.buffer_bytes_snapshot(bufnr)
        if snap == nil then
          notify_one_line(
            "yana: could not save " .. (change.rel or change.path) .. ": " .. tostring(snap_err),
            vim.log.levels.ERROR
          )
          return
        end

        local composed, withheld, skip_reason, skipped =
          M._compose_buffer_owned_lines(bufnr, state.hunk_ledger:pending(), { q1, q2 })
        if skip_reason then
          -- One screen line, aggregated: several separate notifies would wedge
          -- a `--clean` editor on the hit-enter prompt (issue-log row 81).
          local skip_msg = string.format(
            "yana: save left %d hunk(s) in the file -- %s",
            skipped,
            tostring(skip_reason)
          )
          notify_one_line(skip_msg, vim.log.levels.WARN)
          if to_own and is_full_range and not is_append then
            notify_one_line("yana: not written — pending hunks could not be mapped safely", vim.log.levels.WARN)
            return
          end
        end
        local bytes = M._encode_buffer_lines(bufnr, composed)
        local withheld_msg =
          string.format("yana: wrote buffer-owned lines only — %d hunks withheld", withheld)
        local authority_lost = 0
        for _, b in ipairs(state.hunk_ledger:pending()) do
          if b.authority_lost then
            authority_lost = authority_lost + 1
          end
        end

        -- Only a FULL-BUFFER write of the review's OWN identity, that does not append,
        -- is "the ordinary save" the bookkeeping below is about.
        if not (to_own and is_full_range and not is_append) then
          -- The target directory must already exist. `diff.write_file` would
          -- `mkdir -p` it, and this is the one branch whose path is arbitrary
          -- text the human just typed: a mistyped `:w /tpm/x` must refuse the
          -- way Vim refuses it, not silently create `/tpm`.
          local dir = vim.fn.fnamemodify(target, ":h")
          if target == "" or dir == "" or vim.fn.isdirectory(dir) ~= 1 then
            notify_one_line(
              "yana: could not write to " .. target .. ": no such directory " .. tostring(dir),
              vim.log.levels.WARN
            )
            return
          end
          local out_bytes = bytes
          if is_append then
            -- Vim's own `:w >>file` refuses (E212) when `file` does not
            -- already exist rather than creating it; once this event is
            -- registered Vim's default handling never runs, so that refusal
            -- has to be reproduced here.
            local existing = diff.read_file_bytes(target)
            if existing == nil then
              notify_one_line(
                "yana: could not append to " .. target .. ": no such file or directory",
                vim.log.levels.WARN
              )
              return
            end
            out_bytes = existing .. out_bytes
          end
          local ok, err = diff.write_file(target, out_bytes)
          if not ok then
            notify_one_line(
              "yana: could not write to " .. target .. ": " .. tostring(err),
              vim.log.levels.WARN
            )
            return
          end
          -- A count of zero is not a withholding notice: nothing was
          -- withheld, so saying so would be noise that a row asserting the
          -- notice fires only when it should would (correctly) red on.
          if withheld > 0 then
            notify_one_line(withheld_msg, vim.log.levels.WARN)
          end
          return
        end
        if authority_lost > 0 then
          notify_one_line(
            string.format(
              "yana: not written — %d pending hunk(s) no longer match the buffer",
              authority_lost
            ),
            vim.log.levels.WARN
          )
          return
        end

        -- Refusing instead would now be the only route by which a created file's
        -- accepted bytes could never reach disk at all. Writing nothing keeps the file
        -- exactly as disk has it — and, unlike composing, cannot truncate it if that
        -- single hunk's extmark is invalidated.
        if change.kind == "delete" or change.after == nil then
          notify_one_line(
            "yana: not written — the file stays until you decide the pending deletion",
            vim.log.levels.WARN
          )
          return
        end

        -- Writing bytes disk already holds would restamp the file for nothing:
        -- it bumps mtime under every external watcher and hands this buffer's
        -- recorded file info a staleness it did not have to have.
        local disk_before = diff.read_file_bytes(change.path)
        if disk_before ~= bytes then
          local ok, err = diff.write_file(change.path, bytes)
          if not ok then
            notify_one_line(
              "yana: could not save " .. (change.rel or change.path) .. ": " .. tostring(err),
              vim.log.levels.ERROR
            )
            return
          end
        end

        -- ANCHORS ADVANCE ONLY AFTER A SUCCESSFUL WRITE, and against bytes
        -- read back from disk rather than the string handed to the writer —
        -- an anchor may only ever claim bytes that are provably there. The
        -- reverse order is silently wrong: `disk_at_open` naming bytes that
        -- are not on disk sends a later reload into tier-2 composition against
        -- a base that never existed.
        local on_disk, read_err = diff.read_file_bytes(change.path)
        if on_disk == nil then
          notify_one_line(
            "yana: saved " .. (change.rel or change.path) .. " but could not re-read it: " .. tostring(read_err),
            vim.log.levels.WARN
          )
          return
        end
        change.disk_at_open = on_disk
        -- THE ACCEPT-TIME CAS. `shadow/apply.lua:824-829` hands `base_hash` to
        -- the diary and `safety/diary.lua`'s `state_matches` compares hash AND
        -- state AND mode one syscall before the rename. Advancing only
        -- `disk_at_open` is what the reload path's own comment records as
        -- having "left every tier-2 accept refused as human drift"; here it
        -- would brick the review after the first save.
        local rehash = base_fingerprint(on_disk)
        if rehash then
          change.base_hash = rehash
          change.base_state = "file"
          local st_now = (vim.uv or vim.loop).fs_lstat(change.path)
          if st_now and st_now.mode then
            change.base_mode = st_now.mode
          end
        end
        -- `change.before` moves WITH the fingerprint, and must: they are read as a
        -- pair. `shadow/apply.lua`'s `scope_revert` writes `change.before` under a
        -- `change.base_hash` CAS, and `revert_to_turn_start` writes it outright —
        -- leaving `before` at turn-start while `base_hash` names the saved file gives
        -- both a licence to write a pre-save snapshot over bytes the human has already
        -- durably saved.
        change.before = on_disk
        -- THE BUFFER SNAPSHOT, never the bytes written. The reload handler's tier 1
        -- restores `staged_text` into the buffer; the composition there would overwrite
        -- the review with its own hunk-less text and destroy every pending hunk on
        -- screen, silently. It would also permanently falsify
        -- `staged_snapshot_unchanged`, so every delete-accept would refuse "buffer
        -- holds edits that accepting this deletion would discard".
        state.staged_text = snap
        state.latest_undo_seq = buf_undo_seq(bufnr)
        -- Pending hunks never move it in either direction.
        vim.bo[bufnr].modified = false
        if withheld > 0 then
          notify_one_line(withheld_msg, vim.log.levels.INFO)
        end
        return
      end)
      end,
    })
  end
  setfenv(setup, env)
  setup()
end

return Factory
