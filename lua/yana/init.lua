-- yana: public API for the Neovim agent chat panel.
local config = require("yana.config")
local log = require("yana.log")

local M = {}

-- Lazy so that `require("yana")` stays cheap.
local function ui()
  return require("yana.panel.ui")
end

local SETUP_MISSING_MSG = "yana.setup() has not run — load the plugin (lazy) or call setup()"

local function require_setup()
  if config.setup_done() then
    return true
  end
  require("yana.notify").one_line(SETUP_MISSING_MSG, vim.log.levels.WARN)
  return false
end

-- Wrap a message as a non-string error so Neovim's top-level formatter prints a clean
-- one-liner without a Lua traceback; __tostring/__concat keep it reading as `msg`.
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

-- THE COMPOSITION ROOT: the only place allowed to load a debug module.
-- `factory` (default) returns early so no `yana.debug_*` chunk is ever loaded
-- (`tests/yana_debug_profile_gate.sh`). `debugger` attaches `config.debug_modules`,
-- each getting one `attach(log)` with the factory logger. Every module is resolved and
-- type-checked BEFORE any attaches, so a bad name leaves nothing half-attached. The
-- `yana.profile` row is written last and names what actually attached; evidence
-- readers refuse a log whose first line is not this one.
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
  local deps = require("yana.runtime.dependencies")
  if vim.fn.has("nvim-" .. deps.minimum_neovim) == 0 then
    -- Below the floor: surface once on the error channel, re-raise via clean_error()
    -- so nothing downstream decorates it. Nothing past this block runs.
    local _, raw = pcall(function()
      error("yana requires Neovim " .. deps.minimum_neovim .. "+", 0)
    end)
    local msg = tostring(raw)
    pcall(vim.api.nvim_err_writeln, msg)
    error(clean_error(msg))
  end

  config.setup(opts)
  compose_profile()

  -- Hand-authored setup{} values stay; this merges only the picker keys.
  pcall(function()
    local persisted = require("yana.runtime.persisted_state")
    persisted.apply_model_selection(config.options)
    if persisted.apply_write_roots(config.options) then
      config.options.write_roots = config.normalize_write_roots(config.options.write_roots)
    end
  end)

  -- One canonical STARTUP event: the resolved configuration (agent binary on THIS
  -- PATH, overlay availability) is not recoverable after the fact. Read-only queries.
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

  -- Config-driven: image_paste.enable must remove the command entirely, and this is
  -- where config.options is final.
  if config.options.image_paste and config.options.image_paste.enable then
    vim.api.nvim_create_user_command("YanaPasteImage", function()
      require("yana.runtime.recovery_entry").schedule(vim.fn.getcwd())
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
        require("yana.input.inline_edit").open_visual()
      end)
    end, { silent = true, desc = "yana: inline edit selection" })
  end

  -- Empty capture set: one-line notify naming :YanaRoots; deferred so setup() stays non-blocking.
  vim.schedule(function()
    log.guard("yana capture-set empty notify", function()
      require("yana.panel.ui_roots").maybe_notify_on_empty()
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

--- Vendor picker, then model picker for that vendor.
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

-- Paste an image from the system clipboard into the current prompt.
function M.paste_image()
  ui().paste_image()
end

-- Open the live playground for inline diff-highlight themes.
function M.diff_themes()
  require("yana.diff_preview").open()
end

-- Ask about a line range; buf 0 = current, question may be nil.
function M.ask_range(buf, l1, l2, question)
  if not require_setup() then
    return
  end
  local context = require("yana.input.context")
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

-- Inline edit over a line range; instruction nil opens the float.
function M.edit_range(buf, l1, l2, instruction)
  if not require_setup() then
    return
  end
  require("yana.input.inline_edit").open(buf, l1, l2, instruction)
end


-- Write the diagnostic bundle and echo its path. Read-only apart from the report file.
function M.dump()
  local path, err = require("yana.dump").write()
  if not path then
    require("yana.notify").one_line("yana: dump failed: " .. tostring(err), vim.log.levels.WARN)
    return nil
  end
  vim.api.nvim_echo({ { "yana: wrote " .. path } }, true, {})
  return path
end

-- Write the per-turn flow report and echo its path; `opts.open` splits it open.
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

-- Run the render reconciliation on every open review. Reports at WARN at worst so
-- the diagnostic never changes behaviour.
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
