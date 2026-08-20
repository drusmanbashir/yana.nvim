-- yana: command and autoload registration. Loaded automatically by Neovim.
if vim.g.loaded_yana then
  return
end
vim.g.loaded_yana = true

if vim.fn.has("nvim-0.10.4") == 0 then
  vim.notify("yana requires Neovim 0.10.4+", vim.log.levels.ERROR)
  return
end

local function yana()
  return require("yana")
end

local log = require("yana.log")

-- Resume ordinary-edit capture when a file with an existing Yana timeline is
-- opened in a later editor session. Files without timeline rows are untouched.
local timeline_group = vim.api.nvim_create_augroup("YanaTimelineCapture", { clear = true })
vim.api.nvim_create_autocmd("BufReadPost", {
  group = timeline_group,
  callback = function(args)
    log.guard("Yana timeline BufReadPost", function()
      local path = vim.api.nvim_buf_get_name(args.buf)
      local workspace = require("yana.diff").abs_path(vim.fn.getcwd())
      local abs = require("yana.diff").abs_path(path)
      if not abs or abs:sub(1, #workspace + 1) ~= workspace .. "/" then
        return
      end
      local rel = abs:sub(#workspace + 2)
      local rows = require("yana.timeline").entries(workspace, rel)
      if type(rows) == "table" and #rows > 0 then
        require("yana.timeline.edit_capture").attach(args.buf, workspace, rel)
      end
    end)
  end,
})

-- Every command handler body is wrapped in log.guard so an uncaught error
-- (e.g. the E976 content-hash crash in ui.submit_panel) is written to the
-- log file before it surfaces to the user exactly as before -- guard()
-- re-raises, so :messages/E5108 behaviour on error is unchanged.
local cmd = vim.api.nvim_create_user_command

cmd("Yana", function()
  log.guard("Yana", function()
    yana().toggle()
  end)
end, { desc = "Toggle the yana agent panel" })

cmd("YanaOpen", function()
  log.guard("YanaOpen", function()
    yana().open()
  end)
end, { desc = "Open the yana agent panel" })

cmd("YanaClose", function()
  log.guard("YanaClose", function()
    yana().close()
  end)
end, { desc = "Close the yana agent panel" })

cmd("YanaTimeline", function()
  log.guard("YanaTimeline", function()
    require("yana.timeline.ui").open({})
  end)
end, { desc = "Show the timeline of review decisions and edits for this file" })

cmd("YanaAbortReview", function()
  log.guard("YanaAbortReview", function()
    require("yana.inline_diff").abort_active({})
  end)
end, { desc = "Abort the open review: put the file back as it was before the hunks appeared" })

cmd("YanaToggle", function()
  log.guard("YanaToggle", function()
    yana().toggle()
  end)
end, { desc = "Toggle the yana agent panel" })

cmd("YanaNew", function()
  log.guard("YanaNew", function()
    yana().open()
    yana().new_chat()
  end)
end, { desc = "Start a new yana chat" })

cmd("YanaNewPanel", function()
  log.guard("YanaNewPanel", function()
    yana().new_panel()
  end)
end, { desc = "Open an additional yana panel (parallel session)" })

-- With !, the picked session opens in a new panel instead of reusing the
-- current one — handy for running several sessions at once.
cmd("YanaSessions", function(opts)
  log.guard("YanaSessions", function()
    yana().sessions({ new_panel = opts.bang })
  end)
end, { bang = true, desc = "Pick a previous session to view/resume" })

cmd("YanaResume", function(opts)
  log.guard("YanaResume", function()
    local id = (opts.args and opts.args ~= "") and opts.args or nil
    yana().resume(id, { new_panel = opts.bang })
  end)
end, { nargs = "?", bang = true, desc = "Resume the latest (or a specific) yana session" })

cmd("YanaMode", function()
  log.guard("YanaMode", function()
    yana().open()
    yana().toggle_mode()
  end)
end, { desc = "Cycle the yana agent mode" })

cmd("YanaModel", function()
  log.guard("YanaModel", function()
    yana().pick_model()
  end)
end, { desc = "Pick the yana agent model" })

cmd("YanaDiff", function()
  log.guard("YanaDiff", function()
    yana().show_changes()
  end)
end, { desc = "View agent file changes as a diff (read-only)" })

cmd("YanaRefusals", function()
  log.guard("YanaRefusals", function()
    require("yana.ui").show_refusals()
  end)
end, { desc = "List system-refused operations for the current Yana panel" })

cmd("YanaReview", function()
  log.guard("YanaReview", function()
    yana().review_changes()
  end)
end, { desc = "Review a pending agent change (accept or reject)" })

cmd("YanaAccept", function()
  log.guard("YanaAccept", function()
    yana().accept_changes()
  end)
end, { desc = "Accept a pending agent file change" })

cmd("YanaReject", function()
  log.guard("YanaReject", function()
    yana().reject_changes()
  end)
end, { desc = "Reject a pending agent file change (revert)" })

cmd("YanaStop", function()
  log.guard("YanaStop", function()
    yana().stop()
  end)
end, { desc = "Stop the in-flight yana response" })

cmd("YanaSteer", function()
  log.guard("YanaSteer", function()
    yana().steer()
  end)
end, { desc = "Interrupt the in-flight response and resend the prompt buffer as a new turn" })

cmd("YanaQueue", function()
  log.guard("YanaQueue", function()
    yana().queue()
  end)
end, { desc = "View/edit/delete/reorder queued follow-up prompts" })

-- Range-aware: in visual mode (or with an explicit range) the selected lines
-- are attached as context. Any trailing text becomes the question and is sent
-- immediately; otherwise the panel just opens with the selection attached.
cmd("YanaAsk", function(opts)
  log.guard("YanaAsk", function()
    local question = (opts.args and opts.args ~= "") and opts.args or nil
    if opts.range and opts.range > 0 then
      yana().ask_range(0, opts.line1, opts.line2, question)
    else
      yana().ask(question)
    end
  end)
end, { nargs = "*", range = true, desc = "Ask yana about the current line/selection" })

-- Inline edit ("Ctrl-K"). Range-aware like YanaAsk, but the range is the
-- edit target rather than context, and the turn always runs in agent mode.
-- Trailing text is the instruction and skips the float; with no text the
-- instruction float opens over the selection. With no range, the current line
-- is the target — an inline edit is always about specific lines.
cmd("YanaEdit", function(opts)
  log.guard("YanaEdit", function()
    local instruction = (opts.args and opts.args ~= "") and opts.args or nil
    if opts.range and opts.range > 0 then
      yana().edit_range(0, opts.line1, opts.line2, instruction)
    else
      local l = vim.fn.line(".")
      yana().edit_range(0, l, l, instruction)
    end
  end)
end, { nargs = "*", range = true, desc = "Inline edit the current line/selection (agent mode)" })
-- Diagnostics. All three are pure reads plus one report file; none of them
-- resolves a review, rerenders, or touches the real tree.
cmd("YanaDump", function()
  log.guard("YanaDump", function()
    yana().dump()
  end)
end, { desc = "Write a yana diagnostic dump (turn ledgers, review pools, decorations, diary)" })

cmd("YanaFlowReport", function(opts)
  log.guard("YanaFlowReport", function()
    yana().flow_report({ open = opts.bang })
  end)
end, { bang = true, desc = "Write the per-turn yana flow report (! also opens it)" })

cmd("YanaRenderCheck", function()
  log.guard("YanaRenderCheck", function()
    yana().render_check()
  end)
end, { desc = "Reconcile every open inline review's decoration against its change model" })

cmd("YanaDiffThemes", function()
  log.guard("YanaDiffThemes", function()
    require("yana.diff_preview").open()
  end)
end, { desc = "Live preview yana inline diff color themes" })
