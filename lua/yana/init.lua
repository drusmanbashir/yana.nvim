-- yana: public API. A Cursor-style agent chat panel for Neovim powered by
-- the cursor-agent CLI.
local config = require("yana.config")
local log = require("yana.log")

local M = {}

-- Lazily require the UI so that merely `require("yana")` is cheap.
local function ui()
  return require("yana.ui")
end

local SETUP_MISSING_MSG = "yana.setup() has not run — load the plugin (lazy) or call setup()"

local function require_setup()
  if config.setup_done() then
    return true
  end
  require("yana.notify").one_line(SETUP_MISSING_MSG, vim.log.levels.WARN)
  return false
end

-- Wraps a plain message so Neovim's own top-level uncaught-error formatter (interactive
-- :lua, init.lua sourcing, `-l` script execution -- all of them route an uncaught error
-- through it) renders a clean one-liner instead of a full Lua stack traceback. Lua's
-- debug.traceback, which that formatter calls internally, only appends "stack
-- traceback:" when the thrown value IS a plain string; a non-string, non-nil value is
-- returned untouched. __tostring/__concat keep the object reading as `msg` everywhere a
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

-- THE COMPOSITION ROOT. The one place that decides which build of yana this
-- session is, and the only place allowed to load a debug module.
--
-- `factory` -- the default, every user, every gate, every release -- takes the
-- early return below, so no `yana.debug_*` chunk is ever loaded into the
-- process and `package.loaded` proves it (`tests/yana_debug_profile_gate.sh`).
-- `debugger` is the SAME factory build with the modules named in
-- `config.debug_modules` attached on top; each one is `yana.debug_<name>` and
-- gets exactly one `attach(log)` call, with the factory logger handed to it so
-- its lines go into the SAME file, through the SAME append path, in event order.
--
-- Loading is separated from attaching on purpose: every module is resolved and
-- type-checked BEFORE any of them observes anything, so a misspelt name fails
-- setup with nothing half-attached behind it.
--
-- The `yana.profile` row is written LAST, and it is the first line of the log:
-- it names the profile that is actually running and the modules that actually
-- attached, never the ones that were asked for. Evidence readers refuse a log
-- whose first line is not this one (`tests/headless/xrec/record.sh`).
local function compose_profile()
  local profile = config.options.profile
  if profile ~= "debugger" then
    log.lifecycle_info("yana.profile", { profile = profile, modules = {} })
    return
  end
  local names, mods = config.options.debug_modules or {}, {}
  for _, name in ipairs(names) do
    local mod = "yana.debug_" .. name
    local ok, loaded = pcall(require, mod)
    if not ok then
      error(clean_error("yana: config.debug_modules names " .. vim.inspect(name)
        .. ", which does not load as `" .. mod .. "`: " .. tostring(loaded)))
    end
    if type(loaded) ~= "table" or type(loaded.attach) ~= "function" then
      error(clean_error("yana: " .. mod .. " is not a debug module: it must return a table with "
        .. "one `attach(log)` function"))
    end
    mods[#mods + 1] = loaded
  end
  for _, mod in ipairs(mods) do
    mod.attach(log)
  end
  log.lifecycle_info("yana.profile", { profile = profile, modules = names })
end

-- Validate Neovim version, apply config, wire keymaps/commands, log startup.
function M.setup(opts)
  local deps = require("yana.dependencies")
  if vim.fn.has("nvim-" .. deps.minimum_neovim) == 0 then
    -- Below the floor: refuse cleanly, not with a crash dump. Catch it, surface it once
    -- on the real error channel, then re-raise via clean_error() so nothing downstream
    -- decorates it -- setup() still genuinely does not return to an unprotected caller,
    -- it just does so without the traceback. Nothing past this block runs.
    local _, raw = pcall(function()
      error("yana requires Neovim " .. deps.minimum_neovim .. "+", 0)
    end)
    local msg = tostring(raw)
    pcall(vim.api.nvim_err_writeln, msg)
    error(clean_error(msg))
  end

  config.setup(opts)
  compose_profile()

  -- Hand-authored setup{} values for write_roots etc. stay; this merges only the picker
  -- keys.
  pcall(function()
    local persisted = require("yana.persisted_state")
    persisted.apply_model_selection(config.options)
    if persisted.apply_write_roots(config.options) then
      config.options.write_roots = config.normalize_write_roots(config.options.write_roots)
    end
  end)

  -- One canonical STARTUP event: the resolved configuration this session actually runs
  -- with, not what was declared. Reproduction needs the operator's exact environment
  -- (which agent binary resolve_cmd() found on THIS machine's PATH, whether the overlay
  -- sandbox is present) and that is never available after the fact, so this is the
  -- logging-guidance case where logging WINS over re-deriving it. Read-only:
  -- resolve_cmd/available are queries, not decisions, so this never changes what
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
      require("yana.recovery_entry").schedule(vim.fn.getcwd())
      log.guard("YanaPasteImage", function()
        M.paste_image()
      end)
    end, { desc = "Paste an image from the system clipboard into the yana prompt" })
  else
    pcall(vim.api.nvim_del_user_command, "YanaPasteImage")
  end

  local gk = config.options.mappings
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
  -- Visual mode only: the selection IS the argument.
  if gk.inline_edit and gk.inline_edit ~= "" then
    vim.keymap.set("x", gk.inline_edit, function()
      log.guard("yana global keymap inline_edit (visual)", function()
        require("yana.inline_edit").open_visual()
      end)
    end, { silent = true, desc = "yana: inline edit selection" })
  end

  -- Capture set empty → one-line notify naming :YanaRoots (never a window). Deferred so
  -- setup() itself stays non-blocking.
  vim.schedule(function()
    log.guard("yana capture-set empty notify", function()
      require("yana.ui_roots").maybe_notify_on_empty()
    end)
  end)

  return config.options
end

-- Open the yana panel, creating it if none exists.
function M.open()
  ui().open()
end

-- Close every open yana panel.
function M.close()
  ui().close()
end

-- Toggle the yana panel open or closed.
function M.toggle()
  ui().toggle()
end

-- Start a new chat in the current panel, cancelling any in-flight turn.
function M.new_chat()
  ui().new_chat()
end

-- Open an additional, independent panel (parallel session).
function M.new_panel()
  ui().open_new_panel()
end

function M.next_panel()
  ui().next_panel()
end

function M.prev_panel()
  ui().prev_panel()
end

-- Permanently stop and remove the associated panel (cursor panel, else MRU/open).
function M.quit_current()
  return ui().quit_current()
end

-- Permanently stop and remove every panel.
function M.quit_all()
  return ui().quit_all()
end

-- List attachable sessions owned by the live daemon.
function M.sessions(opts)
  return ui().list_live_sessions(opts)
end

-- Recover one daemon-kept review, or reopen the recovery picker with no id.
function M.recover(id)
  return ui().recover(id)
end

-- Cycle the panel's mode, renewing the session if it's locked.
function M.toggle_mode()
  ui().toggle_mode()
end

-- Open a picker to choose the model for the current backend.
function M.pick_model()
  ui().pick_model()
end

-- Open a picker to switch backend for this Neovim session.
function M.pick_backend()
  ui().pick_backend()
end

--- Convenience cascade: vendor picker, then model picker for that vendor.
--- Does not replace pick_backend / pick_model (those stay separate).
function M.pick_vendor_then_model()
  ui().pick_vendor_then_model()
end

-- Show this session's file changes as a side-by-side diff.
function M.show_changes()
  ui().show_changes()
end

-- Pick a pending change and open its inline review.
function M.review_changes()
  ui().review_changes()
end

-- Pick a pending change and accept it.
function M.accept_changes()
  ui().accept_changes()
end

-- Pick a pending change and reject it.
function M.reject_changes()
  ui().reject_changes()
end

-- Cancel the in-flight agent turn, or report there's nothing to stop.
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

-- Open the live playground for inline diff-highlight themes.
function M.diff_themes()
  require("yana.diff_preview").open()
end

-- Ask about an explicit line range in a buffer.
-- buf 0 means current buffer. question may be nil (just attach context).
function M.ask_range(buf, l1, l2, question)
  if not require_setup() then
    return
  end
  local context = require("yana.context")
  if buf == 0 then
    buf = vim.api.nvim_get_current_buf()
  end
  local selection = context.selection_from_range(buf, l1, l2)
  ui().ask(selection, question)
end

-- Ask with no explicit selection (uses current file as context).
function M.ask(question)
  if not require_setup() then
    return
  end
  ui().ask(nil, question)
end

-- Inline edit ("Ctrl-K") over an explicit line range. buf 0 means current
-- buffer. instruction may be nil, in which case the instruction float opens.
function M.edit_range(buf, l1, l2, instruction)
  if not require_setup() then
    return
  end
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
