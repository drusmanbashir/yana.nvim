-- yana: parsing cursor-agent tool_call events, presenting file changes,
-- and accept/reject review (revert to captured "before" on reject).
local M = {}

local log = require("yana.log")
local flush = require("yana.safety.flush")
local uv = vim.uv or vim.loop
local _write_seq = 0

-- Module-local fs seam for oracle IR-09 injection; production calls through M._fs only.
M._fs = {
  open = uv.fs_open,
  write = uv.fs_write,
  -- Deliberately NOT `uv.fs_fsync`. The flush runs on the libuv threadpool and
  -- is awaited off the event loop (`safety/flush.lua`): the same descriptor,
  -- the same flush, at the same point in the same sequence — the editor is
  -- simply not stopped for the disk. The seam is unchanged in kind: replacing
  -- this entry still injects, and still gets called with one `fd`.
  fsync = function(fd)
    return flush.fsync(fd)
  end,
  close = uv.fs_close,
  rename = uv.fs_rename,
  unlink = uv.fs_unlink,
  stat = uv.fs_stat,
  fchmod = uv.fs_fchmod,
  fchown = uv.fs_fchown,
  fstat = uv.fs_fstat,
}

local _review_seq = 0

function M.relpath(p)
  if not p or p == "" then
    return "?"
  end
  local rel = vim.fn.fnamemodify(p, ":.")
  return rel ~= "" and rel or p
end

function M.abs_path(path)
  if not path or path == "" then
    return path
  end
  local norm = vim.fs.normalize(path)
  if norm:sub(1, 1) ~= "/" then
    local abs = vim.fn.fnamemodify(path, ":p")
    if abs ~= "" then
      norm = vim.fs.normalize(abs)
    else
      norm = vim.fs.normalize(vim.fn.getcwd() .. "/" .. path)
    end
  end
  -- Resolve symlinks so Mac /var/folders and /private/var/folders compare equal
  -- (BufWriteCmd <amatch> vs bufname; selection_scope paths_match). Existing path
  -- components resolve; a missing final segment stays on the resolved parent.
  local resolved = vim.fn.resolve(norm)
  if resolved ~= "" then
    return vim.fs.normalize(resolved)
  end
  return norm
end

--- Absolute path without following a symlink at the final component.
--- Used when matching journaled paths after the tree may have changed type.
function M.abs_path_literal(path)
  if not path or path == "" then
    return path
  end
  local norm = vim.fn.fnamemodify(path, ":p")
  if norm == "" then
    norm = vim.fn.getcwd() .. "/" .. path
  end
  return vim.fs.normalize(norm)
end

function M.parse_tool(obj)
  local tc = obj.tool_call
  if type(tc) ~= "table" then
    return nil
  end
  for k, v in pairs(tc) do
    if type(k) == "string" and k:match("ToolCall$") and type(v) == "table" then
      return k, v
    end
  end
  return nil
end

function M.short_name(name)
  return (name or "tool"):gsub("ToolCall$", "")
end

function M.synthesize_diff(before, after, path)
  local old = before or ""
  local new = after or ""
  if old == new then
    return ""
  end
  local body = vim.diff(old, new, { result_type = "unified", ctxlen = 3 })
  if not body or body == "" then
    return ""
  end
  local rel = M.relpath(path)
  return string.format("--- a/%s\n+++ b/%s\n%s", rel, rel, body)
end

function M.count_stats(diffstr)
  local added, removed = 0, 0
  for _, l in ipairs(vim.split(diffstr or "", "\n", { plain = true })) do
    if l:match("^%+") and not l:match("^%+%+%+") then
      added = added + 1
    elseif l:match("^%-") and not l:match("^%-%-%-") then
      removed = removed + 1
    end
  end
  return added, removed
end

-- Deletions are NOT inferred from a missing `after`. cursor-agent emits them
-- as their own tool (deleteToolCall, handled explicitly in
-- change_from_payload); the only way an EDIT payload arrives with
-- before ~= nil, after == nil is a truncated/malformed result — and calling
-- that a deletion made the panel say "the agent deleted your file" for what
-- is a payload problem, then refuse the review with a stale-disk message.
-- Malformed modifies stay "modify" and are caught by the after == nil branch
-- in open_review_buffer, which now says what actually happened.
function M.classify_kind(before, after)
  if before == nil and after ~= nil then
    return "create"
  end
  return "modify"
end

function M.change_from_payload(name, payload)
  local res = payload and payload.result
  local success = res and res.success
  if type(success) ~= "table" then
    return nil
  end
  -- Real deletions arrive as a DIFFERENT tool with a different payload shape:
  --   deleteToolCall.result.success = { path, deletedFile, fileSize, prevContent }
  -- No diffString, no afterFullFileContent — so the gate below dropped every
  -- one of them silently: no review, no panel row, the file just gone. The
  -- whole deletion resolve path (S4) was unreachable in real use because of
  -- it. Keyed off the tool name and `deletedFile`, never off a bare
  -- `prevContent`: parse_tool accepts ANY key matching ToolCall$, so a
  -- present-or-future tool that happens to carry prevContent would be
  -- classified as a deletion whose accept path unlinks the file.
  if name == "deleteToolCall" or success.deletedFile ~= nil then
    local dpath = M.abs_path(success.path or success.deletedFile or (payload.args and payload.args.path))
    local prev = success.prevContent
    _review_seq = _review_seq + 1
    local ddiff = prev ~= nil and M.synthesize_diff(prev, "", dpath) or nil
    local da, dr = 0, 0
    if ddiff and ddiff ~= "" then
      da, dr = M.count_stats(ddiff)
    end
    return {
      id = _review_seq,
      status = "pending",
      kind = "delete",
      tool = M.short_name(name),
      path = dpath,
      rel = M.relpath(dpath),
      diff = ddiff,
      before = prev,
      after = nil,
      added = da,
      removed = dr,
    }
  end
  if not (success.diffString or success.afterFullFileContent) then
    return nil
  end
  local path = M.abs_path(success.path or (payload.args and payload.args.path))
  _review_seq = _review_seq + 1
  local diffstr = success.diffString
  local before = success.beforeFullFileContent
  local after = success.afterFullFileContent
  local kind = M.classify_kind(before, after)
  if (not diffstr or diffstr == "") and before ~= nil then
    diffstr = M.synthesize_diff(before, after or "", path)
  end
  local added = success.linesAdded
  local removed = success.linesRemoved
  if (not added or not removed) and diffstr and diffstr ~= "" then
    local a, r = M.count_stats(diffstr)
    added = added or a
    removed = removed or r
  end
  return {
    id = _review_seq,
    status = "pending",
    kind = kind,
    tool = M.short_name(name),
    path = path,
    rel = M.relpath(path),
    diff = diffstr,
    before = before,
    after = after,
    added = added,
    removed = removed,
  }
end

-- One-line panel note. nvim_buf_set_lines rejects "\\n" inside an entry, so
-- multi-line shell/query args must be flattened before render_tool_note.
local function one_line(s, max)
  s = tostring(s):gsub("%s+", " "):match("^%s*(.-)%s*$") or ""
  max = max or 120
  if vim.fn.strchars(s) > max then
    return vim.fn.strcharpart(s, 0, max - 1) .. "…"
  end
  return s
end

function M.tool_summary(name, payload)
  local short = M.short_name(name)
  local args = (payload and payload.args) or {}
  if args.path then
    return short .. " " .. M.relpath(args.path)
  end
  if args.command then
    return short .. ": " .. one_line(args.command)
  end
  if args.query then
    return short .. ": " .. one_line(args.query)
  end
  if args.target_file then
    return short .. " " .. M.relpath(args.target_file)
  end
  return short
end

function M.diff_hunks(diffstr)
  local out = {}
  for _, l in ipairs(vim.split(diffstr or "", "\n", { plain = true })) do
    if not (l:match("^%-%-%- ") or l:match("^%+%+%+ ")) then
      table.insert(out, l)
    end
  end
  return out
end

function M.status_icon(change)
  if change.status == "accepted" then
    return "✓"
  elseif change.status == "kept_unreviewed" then
    return "⚠"
  elseif change.status == "rejected" then
    return "✗"
  elseif change.status == "superseded" then
    return "⤵"
  elseif change.status == "system_refused" then
    return "⛔"
  elseif change.review_error then
    -- Was ⏳ like everything else, so a refused row and a queued row looked
    -- identical in the header — the operator-visible reason this bug class
    -- read as "nothing is happening" rather than "everything is refusing".
    return "⛔"
  end
  return "⏳"
end

function M.status_label(change)
  if change.status == "accepted" then
    return "accepted"
  elseif change.status == "kept_unreviewed" then
    return "kept_unreviewed"
  elseif change.status == "rejected" then
    return "rejected"
  elseif change.status == "superseded" then
    return "superseded"
  elseif change.status == "system_refused" then
    return "system_refused"
  end
  return "pending"
end

-- Human word for the block header. Was hardcoded "edited", so creates and
-- deletes both printed "edited `path`".
function M.kind_verb(change)
  if change.kind == "create" then
    return "created"
  elseif change.kind == "delete" then
    return "deleted"
  end
  return "edited"
end

function M.pending(changes)
  local out = {}
  for _, c in ipairs(changes or {}) do
    if c.status == "pending" then
      table.insert(out, c)
    end
  end
  return out
end

-- Atomic write: temp in target dir (O_EXCL), fchmod to preserve mode past umask,
-- short-write loop, fsync, close-checked rename.
-- CHANGED BEHAVIOUR vs the old truncating io.open writer, which preserved the
-- inode: rename installs a NEW inode. Consequences, all deliberate:
--   * hardlinks to the old inode stop tracking this file (measured);
--   * ownership follows the writing process, so a cross-owner write is REFUSED
--     rather than silently re-owned;
--   * inode-keyed watchers see a replacement.
-- Directory fsync is out of scope (needs a dir fd; no-op/error on Windows).
function M.write_file(path, content, opts)
  opts = opts or {}
  if not path or path == "" then
    return false, "no path"
  end
  path = M.abs_path(path)
  content = content or ""

  local dir = vim.fn.fnamemodify(path, ":h")
  if dir ~= "" and dir ~= "." then
    local mkok = pcall(vim.fn.mkdir, dir, "p")
    if not mkok or vim.fn.isdirectory(dir) ~= 1 then
      return false, "could not create directory " .. dir
    end
  end

  local st = M._fs.stat(path)

  local install_mode
  if opts.target_mode then
    install_mode = opts.target_mode % 0x1000
  elseif st then
    install_mode = st.mode % 0x1000
  else
    install_mode = tonumber("666", 8)
  end

  if vim.fn.filewritable(dir) ~= 2 then
    return false, "EACCES: directory not writable: " .. dir
  end
  if st and vim.fn.isdirectory(path) ~= 1 and vim.fn.filewritable(path) ~= 1 then
    return false, "EACCES: permission denied: " .. path
  end

  local open_mode = install_mode

  local fd, tmp, err
  for attempt = 1, 8 do
    _write_seq = _write_seq + 1
    tmp = string.format("%s/.yana-%d-%d-%d.tmp", dir, uv.os_getpid(), _write_seq, attempt)
    fd, err = M._fs.open(tmp, "wx", open_mode)
    if fd then
      if opts.on_temp_created then
        local cb_ok, cb_err = opts.on_temp_created(tmp)
        if cb_ok == false then
          M._fs.close(fd)
          pcall(M._fs.unlink, tmp)
          return false, cb_err or "on_temp_created refused"
        end
      end
      break
    end
    if not tostring(err):match("EEXIST") then
      return false, tostring(err)
    end
  end
  if not fd then
    return false, "could not create a unique temp file in " .. dir
  end

  local function fail(e)
    pcall(M._fs.close, fd)
    pcall(M._fs.unlink, tmp)
    return false, tostring(e)
  end

  if st then
    local mode = install_mode
    local ok_own, err_own = M._fs.fchown(fd, st.uid, st.gid)
    if not ok_own then
      return fail("could not preserve ownership: " .. tostring(err_own))
    end
    local now = M._fs.fstat(fd)
    if not now then
      return fail("fstat after fchown failed")
    end
    if now.uid ~= st.uid or now.gid ~= st.gid then
      return fail(string.format(
        "refusing to write %s: ownership mismatch after fchown %d:%d vs %d:%d",
        path, now.uid, now.gid, st.uid, st.gid))
    end

    local ok_mod, err_mod = M._fs.fchmod(fd, mode)
    if not ok_mod then
      return fail("could not preserve mode: " .. tostring(err_mod))
    end
    now = M._fs.fstat(fd)
    if not now then
      return fail("fstat after fchmod failed")
    end
    if (now.mode % 0x1000) ~= mode or now.uid ~= st.uid or now.gid ~= st.gid then
      return fail(string.format(
        "refusing to write %s: mode/ownership mismatch after fchmod (mode %o vs %o)",
        path, now.mode % 0x1000, mode))
    end
  end

  local written = 0
  while written < #content do
    local n, werr = M._fs.write(fd, content:sub(written + 1), -1)
    if not n then
      return fail(werr)
    end
    if n == 0 then
      return fail("zero-length write")
    end
    written = written + n
  end

  if st then
    local mode = install_mode
    local ok_mod, err_mod = M._fs.fchmod(fd, mode)
    if not ok_mod then
      return fail("could not preserve mode after write: " .. tostring(err_mod))
    end
    local now = M._fs.fstat(fd)
    if not now then
      return fail("fstat after post-write fchmod failed")
    end
    if (now.mode % 0x1000) ~= mode or now.uid ~= st.uid or now.gid ~= st.gid then
      return fail(string.format(
        "refusing to write %s: mode/ownership mismatch after post-write fchmod (mode %o vs %o)",
        path, now.mode % 0x1000, mode))
    end
  end

  local ok, ferr = M._fs.fsync(fd)
  if not ok then
    return fail(ferr)
  end
  ok, ferr = M._fs.close(fd)
  if not ok then
    pcall(M._fs.unlink, tmp)
    return false, tostring(ferr)
  end

  -- Last hook before the swap. The diary uses it to prove, one syscall before
  -- the rename, that the destination is still the object it validated; a caller
  -- that returns false gets the temp removed and no write at all.
  if opts.on_before_rename then
    local cb_ok, cb_err = opts.on_before_rename(tmp, path)
    if cb_ok == false then
      pcall(M._fs.unlink, tmp)
      return false, cb_err or "on_before_rename refused"
    end
  end

  ok, ferr = M._fs.rename(tmp, path)
  if not ok then
    pcall(M._fs.unlink, tmp)
    return false, tostring(ferr)
  end
  return true
end

-- Stage 1 seam: safety/diary.lua accepts through this path only (IR-09 preserved).
M.diary_atomic_write = M.write_file

function M.delete_file(path)
  if not path or path == "" then
    return false, "no path"
  end
  path = M.abs_path(path)
  if vim.fn.filereadable(path) ~= 1 then
    if vim.fn.getftype(path) == "" then
      return true
    end
    return false, "path exists but is not a regular file"
  end
  local ok, err = M._fs.unlink(path)
  if not ok then
    return false, tostring(err)
  end
  return true
end

-- Save a buffer through Vim itself rather than raw io.write, for callers that
-- already hold the resolved content in a live buffer. `!` bypasses the W12
-- "changed since reading it" prompt — intentional, because the review buffer
-- is *supposed* to differ from disk mid-review. Resolve-time protection against
-- external disk edits is inline_diff's CAS (`change.disk_at_open`), not W12.
-- `noautocmd` stops the write from re-triggering autosave/format-on-save and
-- from tripping the BufWriteCmd guard registered on review buffers.
function M.save_buffer(bufnr)
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("noautocmd write!")
  end)
  return ok, err
end

local function snapshot_lines(text)
  local lines = vim.split(text or "", "\n", { plain = true })
  if #lines > 0 and lines[#lines] == "" then
    table.remove(lines)
  end
  return lines
end

function M.read_file_text(path)
  if not path or path == "" then
    return nil, "no path"
  end
  local abs = M.abs_path(path)
  if vim.fn.filereadable(abs) ~= 1 then
    return nil, "file not readable"
  end
  local lines = vim.fn.readfile(abs)
  if vim.v.shell_error ~= 0 then
    return nil, "read failed"
  end
  return table.concat(lines, "\n")
end

-- Raw on-disk bytes for CAS anchors. Unlike read_file_text this preserves
-- CRLF, BOM and final-EOL shape so later comparisons are byte-symmetric.
function M.read_file_bytes(path)
  if not path or path == "" then
    return nil, "no path"
  end
  local abs = M.abs_path(path)
  if vim.fn.filereadable(abs) ~= 1 then
    return nil, "file not readable"
  end
  local f = io.open(abs, "rb")
  if not f then
    return nil, "read failed"
  end
  local data = f:read("*a")
  f:close()
  return data
end

function M.disk_bytes_unchanged(path, snapshot_bytes)
  if snapshot_bytes == nil then
    return true
  end
  local disk, err = M.read_file_bytes(path)
  if disk == nil then
    return false, err or "could not read file from disk"
  end
  if disk ~= snapshot_bytes then
    return false, "file on disk changed since review opened"
  end
  return true
end

function M.buffer_text_normalized(bufnr)
  return table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
end

-- Canonical buffer bytes for CAS against staged_text and disk anchors.
function M.buffer_bytes_snapshot(bufnr)
  if vim.bo[bufnr].binary then
    return nil, "binary buffer cannot be reviewed inline"
  end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for _, line in ipairs(lines) do
    if line:find("\0", 1, true) then
      return nil, "NUL bytes in buffer"
    end
  end
  local eol_byte
  if vim.bo[bufnr].fileformat == "dos" then
    eol_byte = "\r\n"
  elseif vim.bo[bufnr].fileformat == "mac" then
    eol_byte = "\r"
  else
    eol_byte = "\n"
  end
  local body = table.concat(lines, eol_byte)
  if vim.bo[bufnr].endofline then
    body = body .. eol_byte
  end
  if vim.bo[bufnr].bomb then
    body = "\239\187\191" .. body
  end
  return body
end

function M.text_equal_snapshot(buf_text, snapshot)
  local a = snapshot_lines(buf_text)
  local b = snapshot_lines(snapshot or "")
  if #a ~= #b then
    return false
  end
  for i = 1, #a do
    if a[i] ~= b[i] then
      return false
    end
  end
  return true
end

function M.reload_file(path, opts)
  opts = opts or {}
  if not path or path == "" then
    return false, "no path"
  end
  local bufnr = vim.fn.bufnr(path)
  if bufnr <= 0 or not vim.api.nvim_buf_is_loaded(bufnr) then
    return true
  end
  local ok, err = pcall(vim.api.nvim_buf_call, bufnr, function()
    vim.cmd("checktime")
    if opts.force then
      vim.cmd("edit!")
    elseif vim.bo.modified then
      error("buffer modified")
    else
      vim.cmd("edit")
    end
  end)
  if not ok then
    return false, tostring(err)
  end
  return true
end

function M.show(change)
  if not change then
    return
  end

  vim.cmd("tabnew")
  if change.path and vim.fn.filereadable(change.path) == 1 then
    vim.cmd("edit " .. vim.fn.fnameescape(change.path))
  else
    local after = vim.split(change.after or "", "\n", { plain = true })
    local b = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(b, 0, -1, false, after)
    vim.bo[b].buftype = "nofile"
    pcall(vim.api.nvim_buf_set_name, b, "yana://after/" .. (change.rel or "file"))
  end
  vim.cmd("diffthis")
  local ft = vim.bo.filetype

  vim.cmd("leftabove vnew")
  local b = vim.api.nvim_get_current_buf()
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].swapfile = false
  vim.api.nvim_buf_set_lines(b, 0, -1, false, vim.split(change.before or "", "\n", { plain = true }))
  vim.bo[b].modifiable = false
  if ft and ft ~= "" then
    vim.bo[b].filetype = ft
  end
  pcall(vim.api.nvim_buf_set_name, b, "yana://before/" .. (change.rel or "file"))
  vim.cmd("diffthis")
end

-- Review a pending change: hunks open inline in the source buffer.
-- opts: { on_accept(change), on_reject(change), on_close() }
function M.review(change, opts)
  if not change then
    return
  end
  return require("yana.inline_diff").review(change, opts or {})
end

return M
