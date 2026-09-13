-- yana: command and autoload registration. Loaded automatically by Neovim.
if vim.g.loaded_yana then
  return
end
vim.g.loaded_yana = true

if vim.fn.has("nvim-0.11.2") == 0 then
  vim.notify("yana requires Neovim 0.11.2+", vim.log.levels.ERROR)
  return
end

local function yana()
  return require("yana")
end

local log = require("yana.log")

-- Every command arms R-b recovery without delaying its original action. Each
-- body remains wrapped in log.guard, which logs and re-raises uncaught errors.
local raw_cmd = vim.api.nvim_create_user_command
local function cmd(name, callback, opts)
  raw_cmd(name, function(args)
    require("yana.recovery_entry").schedule(vim.fn.getcwd())
    return callback(args)
  end, opts)
end

local function parse_yana_args(raw)
  local flags = {}
  local args = raw and vim.split(raw, "%s+", { trimempty = true }) or {}
  local i = 1
  while i <= #args do
    local a = args[i]
    if a == "--file" then
      flags.file = true
    elseif a == "--workspace" then
      i = i + 1
      if not args[i] or args[i] == "" then
        error("Yana --workspace requires a directory", 0)
      end
      flags.workspace = vim.fn.fnamemodify(vim.fn.expand(args[i]), ":p"):gsub("/+$", "")
    else
      error("unknown Yana argument: " .. tostring(a), 0)
    end
    i = i + 1
  end
  return flags
end

cmd("Yana", function(opts)
  log.guard("Yana", function()
    require("yana.single_file").set_next_flags(parse_yana_args(opts.args))
    yana().toggle()
  end)
end, { nargs = "*", desc = "Toggle the yana agent panel" })

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

cmd("YanaAbortReview", function()
  log.guard("YanaAbortReview", function()
    require("yana.inline_diff").abort_active({})
  end)
end, { desc = "Abort the open review: put the file back as it was before the hunks appeared" })

cmd("YanaReset", function()
  log.guard("YanaReset", function()
    local reset = require("yana.inline_diff").reset_active_review()
    if reset == false then
      require("yana.notify").one_line(
        "yana: no open review here to reset",
        vim.log.levels.INFO
      )
    end
  end)
end, { desc = "Reset the whole turn: every file back to the state the review opened in" })

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

cmd("YanaNextPanel", function()
  log.guard("YanaNextPanel", function()
    yana().next_panel()
  end)
end, { desc = "Focus or rotate to the next yana panel" })

cmd("YanaPrevPanel", function()
  log.guard("YanaPrevPanel", function()
    yana().prev_panel()
  end)
end, { desc = "Focus or rotate to the previous yana panel" })

-- With !, attachment opens in a new panel.
cmd("YanaSessions", function(opts)
  log.guard("YanaSessions", function()
    yana().sessions({ new_panel = opts.bang })
  end)
end, { bang = true, desc = "Attach a session owned by the live yana daemon" })

cmd("YanaRecover", function(opts)
  log.guard("YanaRecover", function()
    local id = (opts.args and opts.args ~= "") and opts.args or nil
    yana().recover(id)
  end)
end, { nargs = "?", desc = "Recover a daemon-kept review after editor death" })

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
end, { desc = "Pick the yana agent model (layer 2: within the active backend)" })

-- Layer 1 alone: which binary/account/bill. The panel `model` key runs the
-- backend-then-model picker; this command picks the backend without the model step.
cmd("YanaBackend", function()
  log.guard("YanaBackend", function()
    yana().pick_backend()
  end)
end, { desc = "Pick the yana backend (layer 1: which binary/account/bill)" })

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

cmd("YanaIgnore", function(opts)
  log.guard("YanaIgnore", function()
    local ignore = require("yana.ignore")
    local pattern = vim.trim(opts.args or "")
    if pattern == "" then
      local patterns = ignore.patterns()
      local lines = {
        "yana review ignore list — gitignore syntax, matched on the workspace-relative path",
        "persisted file: " .. tostring(ignore.persisted_path()),
      }
      if #patterns == 0 then
        lines[#lines + 1] = "  (empty — every path a turn writes is offered for review)"
      else
        for i, pat in ipairs(patterns) do
          lines[#lines + 1] = string.format("  %d. %s", i, pat)
        end
      end
      vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
      return
    end
    local ok, err = ignore.add(pattern)
    if not ok then
      require("yana.notify").safe("yana: " .. tostring(err), vim.log.levels.WARN)
      return
    end
    require("yana.notify").safe(
      "yana: ignoring `" .. pattern .. "` — matching paths are written through unreviewed from the next turn",
      vim.log.levels.INFO
    )
  end)
end, { nargs = "*", desc = "List or extend the review ignore list (gitignore syntax)" })

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

-- Capture set (write_roots): dialog with no arg; direct add with a directory.
-- Spec: modules/external-roots.md §CAPTURE SET — one command, both behaviours.
cmd("YanaRoots", function(opts)
  log.guard("YanaRoots", function()
    require("yana.ui_roots").command(opts)
  end)
end, {
  nargs = "?",
  complete = "dir",
  desc = "Edit the capture set (write_roots): dialog, or add <dir> directly",
})
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

-- Logging surface (LSP-shaped: same names/verbs as :LspLog / vim.lsp.log).
-- WARN by default, same as vim.lsp.log -- these three commands are the
-- opt-in switch and viewer; they add no new logging call site of their own.
cmd("YanaLog", function()
  log.guard("YanaLog", function()
    log.open()
  end)
end, { desc = "Open the yana log file in a split (like :LspLog)" })

cmd("YanaSetLogLevel", function(opts)
  log.guard("YanaSetLogLevel", function()
    local requested = opts.args
    local ok = pcall(log.set_level, requested)
    if not ok then
      error(
        "yana: invalid log level "
          .. vim.inspect(requested)
          .. " -- valid levels: "
          .. table.concat(log.config_level_names(), ", "),
        0
      )
    end
    vim.notify("yana: log level set to " .. log.get_config_level(), vim.log.levels.INFO, { title = "Yana" })
  end)
end, {
  nargs = 1,
  complete = function()
    return log.config_level_names()
  end,
  desc = "Set the yana log level (error|warn|info|debug); prefer :YanaLogLevel",
})

cmd("YanaLogLevel", function(opts)
  log.guard("YanaLogLevel", function()
    local requested = opts.args
    if requested == nil or requested == "" then
      vim.notify("yana: log level is " .. log.get_config_level(), vim.log.levels.INFO, { title = "Yana" })
      return
    end
    local ok = pcall(log.set_level, requested)
    if not ok then
      error(
        "yana: invalid log level "
          .. vim.inspect(requested)
          .. " -- valid levels: "
          .. table.concat(log.config_level_names(), ", "),
        0
      )
    end
    vim.notify("yana: log level set to " .. log.get_config_level(), vim.log.levels.INFO, { title = "Yana" })
  end)
end, {
  nargs = "?",
  complete = function()
    return log.config_level_names()
  end,
  desc = "Print or set the yana log level (error|warn|info|debug)",
})
