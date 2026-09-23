-- Prompt paste + panel stop-on-key (split from yana.ui).
local config = require("yana.config")
local clipboard = require("yana.input.clipboard")
local log = require("yana.log")
local notify = require("yana.notify")
local notify_one_line = notify.one_line
local views = require("yana.panel.ui_panel_views")

local M = {}

function M.new(deps)
  local S = deps.state
  local focus = deps.focus
  local M_parent = deps.M
  local buf_valid = deps.buf_valid
  local win_valid = deps.win_valid
  local current_panel = deps.current_panel

  local function focused_panel()
    return focus:focused()
  end
  -- Insert `text` into `bufnr` at the cursor position in `winid`, splitting on embedded
  -- newlines first. The single deliberate interface widening this feature adds:
  -- mentions.lua callbacks (@file, @buffers, @quickfix) need to insert text into the
  -- prompt buffer without duplicating cursor/window handling, which is subtle. Do not
  -- copy this function elsewhere — call M.insert_at_cursor.
  local function insert_at_cursor(bufnr, winid, text)
    if not buf_valid(bufnr) or type(text) ~= "string" or text == "" then
      return
    end
    local ok_pos, pos = pcall(vim.api.nvim_win_get_cursor, winid)
    if not ok_pos then
      return
    end
    local row, col = pos[1], pos[2]
    local cur_line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
    local before = cur_line:sub(1, col)
    local after = cur_line:sub(col + 1)

    local pieces = vim.split(text, "\n", { plain = true })
    pieces[1] = before .. pieces[1]
    pieces[#pieces] = pieces[#pieces] .. after

    vim.api.nvim_buf_set_lines(bufnr, row - 1, row, false, pieces)

    local new_row = row - 1 + #pieces
    local new_col = math.max(#pieces[#pieces] - #after, 0)
    pcall(vim.api.nvim_win_set_cursor, winid, { new_row, new_col })
  end

  local function attach_image(p, path, mime)
    p.image_attachments = p.image_attachments or {}
    p.next_image_id = p.next_image_id or 1
    local id = p.next_image_id
    p.next_image_id = id + 1
    table.insert(p.image_attachments, { id = id, path = path, mime = mime })
    local token = "[Image#" .. tostring(id) .. "]"
    insert_at_cursor(p.prompt_buf, views.prompt(p), token)
    return token
  end

  local function expand_attachments(p, text, opts)
    if type(text) ~= "string" or type(p) ~= "table" then
      return text, {}
    end
    local attachments = {}
    for _, attachment in ipairs(p.image_attachments or {}) do
      local token = "[Image#" .. tostring(attachment.id) .. "]"
      local start = text:find(token, 1, true)
      if start then
        local replacement = token .. " (attached image: " .. attachment.path .. ")"
        if not opts or opts.expand_paths ~= false then
          text = text:sub(1, start - 1) .. replacement .. text:sub(start + #token)
        end
        table.insert(attachments, attachment)
      end
    end
    return text, attachments
  end
  -- Shared implementation for the prompt buffer's image_paste.key mapping and
  -- the :YanaPasteImage command.
  -- opts.force_image: only ever do the image branch (the command's contract);
  -- clipboard text/none is reported as a WARN rather than falling back to a
  -- normal text paste.
  local function paste_into_panel(p, opts)
    opts = opts or {}
    local pwin = p and views.prompt(p) or nil
    if not p or not buf_valid(p.prompt_buf) or not win_valid(pwin) then
      return
    end

    local info = clipboard.detect()

    if info.kind == "image" then
      local path, err = clipboard.save_image({ mime = info.mime, keep = config.options.image_paste.keep })
      if not path then
        notify_one_line("yana: could not paste image: " .. tostring(err), vim.log.levels.WARN)
        return
      end
      local token = attach_image(p, path, info.mime)
      notify_one_line("yana: attached image " .. token, vim.log.levels.INFO)
      return
    end

    if info.kind == "file" then
      -- A file manager copy of an existing image file: use it verbatim, no copy.
      local token = attach_image(p, info.path, info.mime)
      notify_one_line("yana: attached image " .. token, vim.log.levels.INFO)
      return
    end

    if info.kind == "text" and not opts.force_image then
      local text, err = clipboard.read_text(info.mime)
      if not text or text == "" then
        notify_one_line("yana: could not read clipboard text: " .. tostring(err or "empty"), vim.log.levels.WARN)
        return
      end
      insert_at_cursor(p.prompt_buf, pwin, text)
      return
    end

    local reason = info.error
      or (opts.force_image and "clipboard does not hold an image" or "clipboard is empty or unsupported")
    notify_one_line("yana: nothing to paste (" .. reason .. ")", vim.log.levels.WARN)
  end

  -- :YanaPasteImage — the image branch unconditionally, so it can be
  -- bound by the user even with image_paste.key unset/disabled.
  local function paste_image()
    paste_into_panel(current_panel(), { force_image = true })
  end
  local stop_on_key_ns = vim.api.nvim_create_namespace("yana_stop_c")
  local stop_on_key_installed = false
  -- The on_key callback proper is only the key filter plus a pcall; all real
  -- work lives here so a throw can be caught.
  local function stop_on_key_body()
    local probe = M_parent._stop_key_probe
    probe.seen = probe.seen + 1
    probe.error = nil
    probe.scheduled = false

    -- The user's only use for <C-c> is copying (terminal/tmux passthrough); it must
    -- never do anything else in yana. Never in terminal mode (a live terminal buffer,
    -- e.g. inside :terminal, owns <C-c> for its own job).
    --
    -- mode() == "t" is terminal-insert/job mode; mode() == "nt" is
    -- terminal-NORMAL mode (:help mode()). Both belong to a live terminal
    -- buffer's own <C-c>, not yana's — bailing on "t" alone let a
    -- <C-c> pressed in a terminal buffer's normal mode slip through and
    -- stop the panel. (The YanaFocusTrack buftype=="terminal" clearing
    -- above is the primary fix for that; this is defense in depth.)
    local mode_now = vim.fn.mode()
    probe.mode = mode_now
    if mode_now == "t" or mode_now == "nt" then
      return
    end
    local p = focus:focused()
    probe.had_panel = p ~= nil
    probe.had_job = p ~= nil and p.job ~= nil
    if not p or not p.job then
      return
    end
    -- Defer so normal-mode <C-c> on the prompt map can run first and avoid a
    -- duplicate stopped note when both handlers see the same key.
    probe.scheduled = true
    vim.schedule(function()
      log.guard("yana.ui stop-on-key", function()
        if S.cancel_inflight(p) then
          S.render_note(p, "⏹ stopped")
        end
      end)
    end)
  end

  local function install_stop_on_key()
    if stop_on_key_installed then
      return
    end
    local stop = config.options.mappings.stop
    if not stop or stop == "" or (stop ~= "<C-c>" and stop ~= "<C-C>") then
      return
    end
    stop_on_key_installed = true
    vim.on_key(function(key)
      if key ~= "\003" and key ~= "<C-c>" and key ~= "<C-C>" then
        return
      end
      -- HARD REQUIREMENT: this callback must never throw. `:help vim.on_key` —
      -- "{fn} will be removed on error" — so ONE throw silently unbinds stop for
      -- the whole nvim session, and the stop_on_key_installed latch above then
      -- stops any later panel from re-arming it. Nothing surfaces to the user;
      -- only restarting nvim recovers. So the body is pcall'd and any throw is
      -- logged, rather than trusted not to happen.
      local ok, err = pcall(stop_on_key_body)
      if not ok then
        M_parent._stop_key_probe.error = tostring(err)
        log.write("ERROR", "yana: <C-c> stop hook threw (hook stays armed): " .. tostring(err))
      end
    end, stop_on_key_ns)
  end

  return {
    focused_panel = focused_panel,
    insert_at_cursor = insert_at_cursor,
    expand_attachments = expand_attachments,
    paste_into_panel = paste_into_panel,
    paste_image = paste_image,
    install_stop_on_key = install_stop_on_key,
  }
end

return M
