-- The creation TOUCH OWNER.
--
-- A proposed new file is NOT touched when the turn proposes it any more: the
-- review opens an empty buffer and nothing reaches disk until End saves an
-- accepted creation through that buffer. The pair below stays only for its remaining
-- callers (the review-open creation branch and the file-creation undo action).
--
-- ONE small module holding ONE pair, and nothing else creates or removes a
-- proposed file:
--   FORWARD  `touch`  -- bring the proposed path into existence, EMPTY.
--   REVERSE  `remove` -- take it back out, ONLY while it is still byte-empty.
--
-- The whole of "the file exists because yana proposed it" lives here.
--
-- So the reverse only ever removes a ZERO-BYTE file, which has no content to preserve:
-- `diff.delete_file`'s unlink is a lossless reverse here, and redo re-runs FORWARD (a
-- fresh touch) to reproduce the identical empty file. No trash store is built for this,
-- and `diff.delete_file` keeps its behaviour for every other caller.
--
-- WHAT "OCCUPIED" MEANS. Forward and reverse therefore agree on the same predicate
-- (`disk_is_ours`), which is why a refused forward can never be followed by a removal
-- that loses bytes.
--
-- Touched paths are remembered in memory only, for the life of THIS Neovim session, and
-- swept at `VimLeavePre` -- never persisted, so no NEW session can see proposal state
-- and no next-session sweep exists. A hard crash (SIGKILL/OOM/power) may therefore
-- leave ONE zero-byte file behind. That residue is ACCEPTED: the rule protects proposed
-- CONTENT and an empty file carries none.
local diff = require("yana.diff")

local M = {}

-- Touched-and-not-yet-reversed paths of THIS session. Memory only.
M._live = {}
M._leave_hooked = false

--- `change.before == nil` says "this turn proposes to CREATE this path"; it never says
--- anything about the file's BYTES, which for a touched file are the empty string.
function M.is_creation(change)
  return type(change) == "table"
    and change.before == nil
    and change.kind ~= "delete"
end

local function normalize(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  return diff.abs_path(path)
end

--- Is what is at `abs` yana's own empty touch (or nothing at all)? Returns true for
--- ABSENT and for a zero-byte regular file; false plus the refusal reason for content,
--- and for anything that is not a regular file.
function M.disk_is_ours(path)
  local abs = normalize(path)
  if abs == nil then
    return false, "no path"
  end
  local ftype = vim.fn.getftype(abs)
  if ftype == "" then
    return true, nil
  end
  if ftype ~= "file" then
    return false, "path exists but is not a regular file"
  end
  local st = diff._fs.stat(abs)
  if st == nil then
    return false, "could not stat " .. abs
  end
  if (st.size or 0) > 0 then
    -- Someone ELSE wrote content here: refused as an appearance.
    return false, "file appeared on disk since review opened"
  end
  return true, nil
end

local function hook_leave()
  if M._leave_hooked or vim.api == nil then
    return
  end
  M._leave_hooked = true
  local ok = pcall(vim.api.nvim_create_autocmd, "VimLeavePre", {
    group = vim.api.nvim_create_augroup("YanaCreationTouch", { clear = true }),
    desc = "a touched-but-empty proposed file does not outlive its session",
    callback = function()
      pcall(M.reverse_all)
    end,
  })
  if not ok then
    M._leave_hooked = false
  end
end

--- FORWARD -- touch-if-absent, refuse-if-occupied. Creates `path` EMPTY when nothing is
--- there, no-ops when yana's own empty touch is already there, and REFUSES when the
--- path holds content or is not a regular file. Never adopts someone else's file.
function M.touch(path)
  local abs = normalize(path)
  if abs == nil then
    return false, "no path"
  end
  local ours, why = M.disk_is_ours(abs)
  if not ours then
    return false, why
  end
  if vim.fn.getftype(abs) == "file" then
    -- Already ours and already empty: forward is a no-op, but the path
    -- rejoins the live set so session death still owes it a reverse.
    M._live[abs] = true
    hook_leave()
    return true, nil
  end
  local dir = vim.fn.fnamemodify(abs, ":h")
  if dir ~= "" and vim.fn.isdirectory(dir) ~= 1 then
    if vim.fn.mkdir(dir, "p") ~= 1 then
      return false, "could not create directory " .. dir
    end
  end
  local fd, oerr = diff._fs.open(abs, "wx", tonumber("644", 8))
  if not fd then
    return false, "could not touch " .. abs .. ": " .. tostring(oerr)
  end
  diff._fs.close(fd)
  M._live[abs] = true
  hook_leave()
  return true, nil
end

--- REVERSE -- remove ONLY IF the file is still byte-empty. Absent is success (nothing
--- to take back).
function M.remove(path)
  local abs = normalize(path)
  if abs == nil then
    return false, "no path"
  end
  local ours, why = M.disk_is_ours(abs)
  if not ours then
    -- THE data-loss case: someone wrote at the path after the touch. Say so
    -- in the reverse's own words rather than the forward's.
    if why == "file appeared on disk since review opened" then
      why = "refusing to remove " .. abs .. ": it is no longer empty"
    end
    return false, why
  end
  M._live[abs] = nil
  if vim.fn.getftype(abs) == "" then
    return true, nil
  end
  local ok, derr = diff.delete_file(abs)
  if not ok then
    return false, tostring(derr)
  end
  return true, nil
end

--- Drops it from the session sweep without touching disk.
function M.forget(path)
  local abs = normalize(path)
  if abs ~= nil then
    M._live[abs] = nil
  end
end

--- Every live touch, only-if-still-empty. Refusals are counted, not raised: a path
--- someone else has written to is left exactly where it is.
function M.reverse_all()
  local removed, refused = 0, 0
  for abs in pairs(M._live) do
    local ok = M.remove(abs)
    if ok then
      removed = removed + 1
    else
      refused = refused + 1
      M._live[abs] = nil
    end
  end
  return removed, refused
end

--- Test seam: forget every live touch without touching disk.
function M._reset()
  M._live = {}
end

return M
