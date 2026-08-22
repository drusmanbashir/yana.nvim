-- yana: public API. A Cursor-style agent chat panel for Neovim powered by
-- the cursor-agent CLI.
local config = require("yana.config")
local log = require("yana.log")

local M = {}

-- Lazily require the UI so that merely `require("yana")` is cheap.
local function ui()
  return require("yana.ui")
end

-- Wraps a plain message so Neovim's own top-level uncaught-error formatter
-- (interactive :lua, init.lua sourcing, `-l` script execution -- all of
-- them route an uncaught error through it) renders a clean one-liner
-- instead of a full Lua stack traceback. Lua's debug.traceback, which that
-- formatter calls internally, only appends "stack traceback:" when the
-- thrown value IS a plain string; a non-string, non-nil value is returned
-- untouched. __tostring/__concat keep the object reading as `msg`
-- everywhere a caller -- including a plugin manager's own pcall-and-report
-- wrapper around setup() -- coerces it to text.
local function clean_error(msg)
  return setmetatable({ message = msg }, {
    __tostring = function(self)
      return self.message
    end,
    __concat = function(a, b)
      local function text(v)
        if type(v) == "table" and v.message then
          return v.message
        end
        return tostring(v)
      end
      return text(a) .. text(b)
    end,
  })
end

-- Optional. Plugin works with defaults without calling setup().
function M.setup(opts)
  local deps = require("yana.dependencies")
  if vim.fn.has("nvim-" .. deps.minimum_neovim) == 0 then
    -- Below the floor: refuse cleanly, not with a crash dump. The error()
    -- call below is the single source of truth for the documented message
    -- (tests/matrix_gate.sh's negative row greps it verbatim from this
    -- file) but is caught right here instead of left to propagate:
    -- Neovim always appends a full stack traceback to an uncaught PLAIN
    -- STRING error reaching its own top-level handler, in every calling
    -- context. Catch it, surface it once on the real error channel, then
    -- re-raise via clean_error() so nothing downstream decorates it --
    -- setup() still genuinely does not return to an unprotected caller, it
    -- just does so without the traceback. Nothing past this block runs.
    local _, raw = pcall(function()
      error("yana requires Neovim " .. deps.minimum_neovim .. "+", 0)
    end)
    local msg = tostring(raw)
    pcall(vim.api.nvim_err_writeln, msg)
    error(clean_error(msg))
  end

  config.setup(opts)

  -- Warm per-vendor model catalogues in the background so \am / :YanaModel
  -- never wait on a fresh CLI spawn after the first load. Skipped under the
  -- hermetic test env (those rows stub list_models / assert argv themselves).
  if not (vim.env.YANA_HERMETIC_ROOT and vim.env.YANA_HERMETIC_ROOT ~= "") then
    vim.schedule(function()
      pcall(function()
        require("yana.agent").prefetch_model_lists()
      end)
    end)
  end

  -- One canonical STARTUP event: the resolved configuration this session
  -- actually runs with, not what was declared. Reproduction needs the
  -- operator's exact environment (which agent binary resolve_cmd() found on
  -- THIS machine's PATH, whether the overlay sandbox is present) and that is
  -- never available after the fact, so this is the logging-guidance case
  -- where logging WINS over re-deriving it. Read-only: resolve_cmd/available
  -- are queries, not decisions, so this never changes what setup() returns.
  do
    local ok_jail, jail_available = pcall(function()
      return require("yana.shadow.jail").available()
    end)
    local ok_state, state_root = pcall(function()
      return require("yana.shadow.preview").state_root()
    end)
    local ok_bin, resolved = pcall(config.resolve_cmd)
    log.lifecycle("startup", {
      agent_bin = ok_bin and resolved and resolved.value or nil,
      mode = config.options.mode,
      enable_agentic = config.options.enable_agentic and true or false,
      capture_root = config.options.capture_root,
      write_roots = config.options.write_roots,
      state_root = ok_state and state_root or nil,
      overlay_available = ok_jail and jail_available and true or false,
    })
  end

  for _, name in ipairs({
    "YanaDiffIncoming",
    "YanaDiffDeleted",
    "YanaInlineHint",
    "YanaHlIncoming",
    "YanaHlDeleted",
    "YanaHlHint",
  }) do
    pcall(vim.api.nvim_set_hl, 0, name, { clear = true })
  end

  -- Config-driven, unlike the always-on commands in plugin/yana.lua:
  -- image_paste.enable must be able to remove the command entirely (not just
  -- no-op it), and this is the one place config.options is known to be
  -- final, so it lives here alongside global_keymaps below.
  if config.options.image_paste and config.options.image_paste.enable then
    vim.api.nvim_create_user_command("YanaPasteImage", function()
      log.guard("YanaPasteImage", function()
        M.paste_image()
      end)
    end, { desc = "Paste an image from the system clipboard into the yana prompt" })
  else
    pcall(vim.api.nvim_del_user_command, "YanaPasteImage")
  end

  local gk = config.options.global_keymaps or {}
  if gk.toggle and gk.toggle ~= "" then
    vim.keymap.set("n", gk.toggle, function()
      log.guard("yana global keymap toggle", function()
        M.toggle()
      end)
    end, { silent = true, desc = "yana: toggle panel" })
  end
  if gk.ask and gk.ask ~= "" then
    vim.keymap.set("n", gk.ask, function()
      log.guard("yana global keymap ask", function()
        M.open()
      end)
    end, { silent = true, desc = "yana: ask" })
    vim.keymap.set("x", gk.ask, function()
      log.guard("yana global keymap ask (visual)", function()
        -- Send the current visual selection.
        local l1 = vim.fn.line("v")
        local l2 = vim.fn.line(".")
        if l1 > l2 then
          l1, l2 = l2, l1
        end
        vim.cmd("normal! \27") -- leave visual mode
        M.ask_range(0, l1, l2, nil)
      end)
    end, { silent = true, desc = "yana: ask about selection" })
  end
  -- Inline edit is visual-first: the selection IS the argument, so the visual
  -- map is the primary one and the normal-mode map (current line) is opt-in
  -- under its own key. See config.global_keymaps for why they are separate.
  if gk.inline_edit and gk.inline_edit ~= "" then
    vim.keymap.set("x", gk.inline_edit, function()
      log.guard("yana global keymap inline_edit (visual)", function()
        require("yana.inline_edit").open_visual()
      end)
    end, { silent = true, desc = "yana: inline edit selection" })
  end
  if gk.inline_edit_normal and gk.inline_edit_normal ~= "" then
    vim.keymap.set("n", gk.inline_edit_normal, function()
      log.guard("yana global keymap inline_edit (line)", function()
        require("yana.inline_edit").open_line()
      end)
    end, { silent = true, desc = "yana: inline edit current line" })
  end

  -- Crash recovery runs on startup, deferred so it never delays `setup`, and
  -- guarded so a recovery failure cannot cost the user their editor. It is a
  -- read followed by a decision: the claim of every retained turn is inspected
  -- before anything is cleaned up.
  vim.schedule(function()
    log.guard("yana turn resume", function()
      M.resume_turns()
    end)
  end)

  return config.options
end

function M.open()
  ui().open()
end

function M.close()
  ui().close()
end

function M.toggle()
  ui().toggle()
end

function M.new_chat()
  ui().new_chat()
end

-- Open an additional, independent panel (parallel session).
function M.new_panel()
  ui().open_new_panel()
end

-- Permanently stop and remove the panel containing the current buffer.
function M.quit_current()
  return ui().quit_current()
end

-- Permanently stop and remove every panel.
function M.quit_all()
  return ui().quit_all()
end

-- Pick a previous session to view/resume. opts.new_panel opens it in a
-- fresh panel so several sessions can run side by side.
function M.sessions(opts)
  ui().pick_session(opts)
end

-- Resume the most recent session for this cwd (or a specific session id).
function M.resume(id, opts)
  ui().resume_last(id, opts)
end

-- Recover the turns a crash left behind.
--
-- This is the PRODUCTION resume path, not a simulation of one: it runs on the
-- shipping startup path, and the ordering it returns is the ordering that
-- really ran. Every retained turn's claim is INSPECTED first; cleanup only
-- touches what the inspection reported as released, so a review that was open
-- when the editor died still has its claim and its state when it comes back.
function M.resume_turns(opts)
  return require("yana.turn_lifecycle").resume_turn(opts)
end

function M.toggle_mode()
  ui().toggle_mode()
end

function M.pick_model()
  ui().pick_model()
end

function M.pick_backend()
  ui().pick_backend()
end

--- Convenience cascade: vendor picker, then model picker for that vendor.
--- Does not replace pick_backend / pick_model (those stay separate).
function M.pick_vendor_then_model()
  ui().pick_vendor_then_model()
end

function M.show_changes()
  ui().show_changes()
end

function M.review_changes()
  ui().review_changes()
end

function M.accept_changes()
  ui().accept_changes()
end

function M.reject_changes()
  ui().reject_changes()
end

function M.stop()
  ui().stop()
end

-- Resubmit the last prompt. opts.where = "here" | "new" | "agent".
function M.resend(opts)
  ui().resend(opts)
end

-- Interrupt the in-flight turn and immediately resend the prompt buffer's
-- text as a new turn (session context preserved).
function M.steer()
  ui().steer()
end

-- View/edit/delete/reorder queued follow-ups.
function M.queue()
  ui().pick_queue()
end

-- Paste an image from the system clipboard into the current panel's prompt
-- (the image branch unconditionally; see :YanaPasteImage).
function M.paste_image()
  ui().paste_image()
end

function M.diff_themes()
  require("yana.diff_preview").open()
end

-- Ask about an explicit line range in a buffer.
-- buf 0 means current buffer. question may be nil (just attach context).
function M.ask_range(buf, l1, l2, question)
  local context = require("yana.context")
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local selection = context.selection_from_range(buf, l1, l2)
  ui().ask(selection, question)
end

-- Ask with no explicit selection (uses current file as context).
function M.ask(question)
  ui().ask(nil, question)
end

-- Inline edit ("Ctrl-K") over an explicit line range. buf 0 means current
-- buffer. instruction may be nil, in which case the instruction float opens.
function M.edit_range(buf, l1, l2, instruction)
  require("yana.inline_edit").open(buf, l1, l2, instruction)
end

----------------------------------------------------------------------
-- diagnostics
----------------------------------------------------------------------

-- Write the diagnostic bundle (every turn ledger as a flow report, review pool
-- state, decoration snapshot, diary introspection) and echo its path. Pure
-- reads plus the one report file; safe to run at any time, including with a
-- review open.
function M.dump()
  local path, err = require("yana.dump").write()
  if not path then
    require("yana.notify").one_line("yana: dump failed: " .. tostring(err), vim.log.levels.WARN)
    return nil
  end
  vim.api.nvim_echo({ { "yana: wrote " .. path } }, true, {})
  return path
end

-- Write the per-turn flow report (the shape the screencast ground truth uses)
-- and echo its path. `opts.open` splits it open afterwards.
function M.flow_report(opts)
  opts = opts or {}
  local lines = require("yana.flow_report").report_lines()
  local dir = vim.fn.stdpath("log")
  vim.fn.mkdir(dir, "p")
  local path = string.format("%s/yana-flow-%s.md", dir, os.date("%Y%m%d-%H%M%S"))
  local f = io.open(path, "w")
  if not f then
    require("yana.notify").one_line("yana: could not write " .. path, vim.log.levels.WARN)
    return nil
  end
  f:write(table.concat(lines, "\n"))
  f:write("\n")
  f:close()
  vim.api.nvim_echo({ { "yana: wrote " .. path } }, true, {})
  if opts.open then
    vim.cmd("split " .. vim.fn.fnameescape(path))
    vim.bo.filetype = "markdown"
  end
  return path
end

-- Run the rung-1 render reconciliation on every open review and report it.
-- Identical to the invariant capture that runs after each render, so what this
-- prints is what production recorded. Reports at WARN at worst: a diagnostic
-- that raises an error notification is a diagnostic that changes behaviour.
function M.render_check()
  local results = require("yana.inline_diff").render_check()
  local notify = require("yana.notify")
  if #results == 0 then
    notify.one_line("yana: no review is open — nothing to check", vim.log.levels.INFO)
    return results
  end
  local render_check = require("yana.render_check")
  local bad = 0
  local lines = {}
  for _, res in ipairs(results) do
    if not res.ok then
      bad = bad + 1
    end
    lines[#lines + 1] = { render_check.summarize(res) .. "\n" }
  end
  vim.api.nvim_echo(lines, true, {})
  if bad > 0 then
    notify.one_line(
      string.format("yana: render check found %d review(s) with violations — :YanaDump for state", bad),
      vim.log.levels.WARN
    )
  end
  return results
end

return M
