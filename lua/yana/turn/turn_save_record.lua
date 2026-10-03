-- THE OPERATOR'S OWN SAVE OF A CREATION, OBSERVED. A creation review's buffer
-- carries one BufWritePost observer (never a write interception) that records
-- the stat identity -- dev, inode, size, mtime -- of the file Neovim just wrote
-- from it. End removes a rejected or undecided creation only while the path is
-- still exactly that file (CORE "Saving is Neovim's", LEDGER N51): a file
-- another program made, or one it replaced after the save, is never deleted.
--
-- Bookkeeping only: it changes no save, decision, prompt or review behaviour,
-- and it reads no content. Turn-scoped: a wiped buffer keeps its Turn's record
-- (the file is still a Turn member End settles); the Turn's end drops it.
local diff = require("yana.diff")

local M = {}

-- [resolved parent + literal final name] = { turn, bufnr, observer, identity }
local records = {}

-- Resolve parent symlinks for the same canonical key as an absent creation,
-- without letting a later final symlink point the lookup at another record.
local function key(path)
  local literal = diff.abs_path_literal(path)
  local parent = vim.fn.fnamemodify(literal, ":h")
  return vim.fs.normalize(diff.abs_path(parent) .. "/" .. vim.fn.fnamemodify(literal, ":t"))
end

--- The path's stat identity now (one lstat), or nil when it is absent.
function M.identity(path)
  local st = (vim.uv or vim.loop).fs_lstat(path)
  if not st then
    return nil
  end
  return { dev = st.dev, ino = st.ino, size = st.size, sec = st.mtime.sec, nsec = st.mtime.nsec }
end

local function drop(key)
  local rec = records[key]
  records[key] = nil
  if rec and rec.observer then
    pcall(vim.api.nvim_del_autocmd, rec.observer)
  end
end

--- Drop every record `turn` owns, by the key stored at watch time: the path is
--- not re-resolved, so one that became a symlink still goes (critic N51 L1).
function M.forget_turn(turn)
  for key, rec in pairs(records) do
    if rec.turn == turn then
      drop(key)
    end
  end
end

--- Observe `bufnr`'s writes to `path` for `turn` (idempotent per buffer). The
--- same Turn watching the path from a new buffer keeps the identity already
--- recorded; another Turn starts fresh.
function M.watch(path, bufnr, turn)
  if type(path) ~= "string" or not (type(bufnr) == "number" and vim.api.nvim_buf_is_valid(bufnr)) then
    return
  end
  path = key(path)
  local old = records[path]
  if old and old.turn == turn and old.bufnr == bufnr then
    return
  end
  drop(path)
  local rec = {
    turn = turn,
    bufnr = bufnr,
    identity = old and old.turn == turn and old.identity or nil,
  }
  records[path] = rec
  rec.observer = vim.api.nvim_create_autocmd("BufWritePost", { buffer = bufnr, callback = function(ev)
    if records[path] == rec and key(ev.match) == path then
      rec.identity = M.identity(path)
    end
  end })
end

--- True when the review buffer wrote `path` and the path is still that file.
function M.matches(path)
  path = key(path)
  local rec = records[path]
  local now = rec and rec.identity and M.identity(path)
  local st = now and (vim.uv or vim.loop).fs_lstat(path)
  return st ~= nil and st.type ~= "link" and vim.deep_equal(now, rec.identity)
end

--- End keeps a file at a creation that ends absent because this review did
--- not write it (or it changed since): one WARN line, and the End goes on.
function M.report_kept(rel)
  local msg = "yana: kept " .. tostring(rel) .. ": changed outside this review"
  require("yana.log").write("WARN", msg)
  pcall(vim.notify, msg, vim.log.levels.WARN)
end

return M
