-- Split out of review_open_actions.lua to meet the 500-line ceiling.
local turn_bind = require("yana.turn.turn_bind")
local turn_settle = require("yana.turn.turn_settle")

local Factory = {}
local saves_in_flight = setmetatable({}, { __mode = "k" })

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
    -- Ordinary own-file writes delegate to the Turn's one journaled save owner.
    -- Range, append and other-target writes remain explicit human export commands;
    -- their current original-side byte behaviour is preserved below.
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
        -- BufWriteCmd is the buffer's own whole-file write. The '[ and ']
        -- marks belong only to FileWriteCmd/FileAppendCmd and may still name
        -- an older operator range when a later bare :w reaches this callback.
        local is_full_range = ev.event == "BufWriteCmd" or (q1 <= 1 and q2 >= total)
        local is_append = (ev.event == "FileAppendCmd")

        if to_own and is_full_range and not is_append then
          local pool = pool_for(state.opts or {})
          local turn = pool and turn_bind.get(pool) or nil
          local file = turn and turn:file(own) or nil
          if file == nil then
            notify_one_line(
              "yana: could not save " .. (change.rel or change.path) .. ": no retained Turn file",
              vim.log.levels.ERROR
            )
            return
          end
          if saves_in_flight[file] ~= nil then
            notify_one_line(
              "yana: save already waiting for " .. (change.rel or change.path),
              vim.log.levels.WARN
            )
            return
          end
          local token = { state = state, cancelled = false }
          saves_in_flight[file] = token
          local completed = false
          local function done(ok, reason)
            if completed then
              return
            end
            completed = true
            if saves_in_flight[file] ~= token then
              return
            end
            saves_in_flight[file] = nil
            if token.cancelled then
              return
            end
            if ok ~= true then
              notify_one_line(
                "yana: could not save " .. (change.rel or change.path) .. ": " .. tostring(reason),
                vim.log.levels.ERROR
              )
              return
            end
            if vim.api.nvim_buf_is_valid(bufnr) then
              vim.bo[bufnr].modified = false
            end
          end
          local called, result = pcall(turn_settle.save, file, {
            bufnr = bufnr,
            state = state,
            changedtick = vim.api.nvim_buf_get_changedtick(bufnr),
          }, done)
          if not called and not completed then
            done(false, result)
          elseif result == "pending" then
            -- A write command is synchronous from the operator's point of view.
            -- The one write owner first wins its asynchronous file claim, so
            -- keep this command open while Neovim delivers that callback.
            -- yanad bounds cold start plus request time below this ceiling.
            if not vim.wait(30000, function() return completed end, 10) then
              token.cancelled = true
              notify_one_line(
                "yana: save of " .. (change.rel or change.path) .. " timed out waiting for its file claim",
                vim.log.levels.ERROR
              )
            end
          end
          return
        end

        local _, snap_err = diff.buffer_bytes_snapshot(bufnr)
        if snap_err ~= nil then
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

        -- The target directory must already exist. `diff.write_file` would
        -- create it, unlike Vim's human-command refusal.
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
        if withheld > 0 then
          notify_one_line(withheld_msg, vim.log.levels.WARN)
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
