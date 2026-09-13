-- yana: read images (or image files, or text) off the system clipboard
-- so a screenshot can be pasted straight into the prompt buffer.
--
-- The two operations that actually touch the system clipboard live behind
-- M.backend so tests can substitute a fake and NEVER touch the real,
-- live desktop clipboard (see tests/image_paste_smoke.lua).
local uv = vim.uv or vim.loop

local M = {}

----------------------------------------------------------------------
-- mime <-> extension
----------------------------------------------------------------------

-- Preference order when several image mimes are offered: PNG first.
local IMAGE_MIME_ORDER = {
  "image/png",
  "image/jpeg",
  "image/jpg",
  "image/gif",
  "image/bmp",
  "image/tiff",
  "image/webp",
}

local EXT_FOR_MIME = {
  ["image/png"] = "png",
  ["image/jpeg"] = "jpg",
  ["image/jpg"] = "jpg",
  ["image/gif"] = "gif",
  ["image/bmp"] = "bmp",
  ["image/tiff"] = "tiff",
  ["image/webp"] = "webp",
}

local IMAGE_EXTS = {
  png = true, jpg = true, jpeg = true, gif = true,
  bmp = true, tiff = true, tif = true, webp = true,
}

-- Preference order for plain-text targets.
local TEXT_MIME_ORDER = {
  "text/plain;charset=utf-8",
  "text/plain",
  "UTF8_STRING",
  "STRING",
  "TEXT",
}

----------------------------------------------------------------------
-- injectable backend (the only code that shells out to xclip/wl-paste)
----------------------------------------------------------------------

local function has_wayland()
  return vim.env.WAYLAND_DISPLAY and vim.env.WAYLAND_DISPLAY ~= ""
    and vim.fn.executable("wl-paste") == 1
end

local NO_BACKEND_ERR = "no clipboard backend found: install xclip (X11) or wl-clipboard (Wayland, wl-paste)"

M.backend = {
  -- Returns a newline-separated string of offered mime targets, or nil, err.
  targets = function()
    if has_wayland() then
      local out = vim.fn.system({ "wl-paste", "--list-types" })
      if vim.v.shell_error ~= 0 then
        return nil, "wl-paste --list-types failed (clipboard empty?)"
      end
      return out
    end
    if vim.fn.executable("xclip") == 1 then
      local out = vim.fn.system({ "xclip", "-selection", "clipboard", "-t", "TARGETS", "-o" })
      if vim.v.shell_error ~= 0 then
        return nil, "xclip TARGETS query failed (clipboard empty?)"
      end
      return out
    end
    return nil, NO_BACKEND_ERR
  end,

  -- Reads the given mime target straight to `path` via shell redirection
  -- (never through a Lua string) so binary image bytes cannot be mangled.
  -- Returns true, nil or false, err.
  read_to_file = function(mime, path)
    local sh
    if has_wayland() then
      sh = string.format("wl-paste --type %s > %s", vim.fn.shellescape(mime), vim.fn.shellescape(path))
    elseif vim.fn.executable("xclip") == 1 then
      sh = string.format(
        "xclip -selection clipboard -t %s -o > %s",
        vim.fn.shellescape(mime),
        vim.fn.shellescape(path)
      )
    else
      return false, NO_BACKEND_ERR
    end
    vim.fn.system({ "sh", "-c", sh })
    if vim.v.shell_error ~= 0 then
      return false, "clipboard read failed (exit " .. tostring(vim.v.shell_error) .. ")"
    end
    return true, nil
  end,
}

----------------------------------------------------------------------
-- cache dir
----------------------------------------------------------------------

function M.cache_dir()
  return vim.fn.stdpath("cache") .. "/yana/clip"
end

local function ensure_cache_dir()
  local dir = M.cache_dir()
  vim.fn.mkdir(dir, "p")
  return dir
end

-- Collision-free destination for a new pasted image: increments until an
-- unused name is found rather than trusting os.time() second-granularity.
local function unique_image_path(dir, ext)
  local base = os.time()
  local n = 0
  while true do
    local suffix = n == 0 and "" or ("-" .. n)
    local candidate = string.format("%s/img-%d%s.%s", dir, base, suffix, ext)
    if vim.fn.filereadable(candidate) == 0 and vim.fn.isdirectory(candidate) == 0 then
      return candidate
    end
    n = n + 1
  end
end

-- Keep only the newest `keep` pasted images (by mtime, not filename) in dir.
function M.prune(dir, keep)
  dir = dir or M.cache_dir()
  keep = keep or 20
  local handle = uv.fs_scandir(dir)
  if not handle then
    return
  end
  local files = {}
  while true do
    local name, typ = uv.fs_scandir_next(handle)
    if not name then
      break
    end
    if typ == "file" and name:match("^img%-") then
      local full = dir .. "/" .. name
      files[#files + 1] = { path = full, mtime = vim.fn.getftime(full) }
    end
  end
  table.sort(files, function(a, b)
    return a.mtime > b.mtime
  end)
  for i = keep + 1, #files do
    pcall(vim.fn.delete, files[i].path)
  end
end

----------------------------------------------------------------------
-- text/uri-list parsing
----------------------------------------------------------------------

local function percent_decode(s)
  return (s:gsub("%%(%x%x)", function(h)
    return string.char(tonumber(h, 16))
  end))
end

-- file://[host]/abs/path -> /abs/path (percent-decoded).
local function file_uri_to_path(uri)
  local rest = uri:match("^file://[^/]*(/.*)$")
  if not rest then
    return nil
  end
  return percent_decode(rest)
end

local function ext_of(path)
  return (path:match("%.([%w]+)$") or ""):lower()
end

-- Reads the text/uri-list target and, if its first entry is an existing
-- image file, returns that absolute path. Returns nil (no error surfaced —
-- caller falls back to the text branch) when the target isn't usable.
local function resolve_uri_list_file()
  local dir = ensure_cache_dir()
  local tmp = string.format("%s/.uri-list-%d-%d.tmp", dir, os.time(), math.random(1, 1e6))
  local ok = M.backend.read_to_file("text/uri-list", tmp)
  if not ok then
    return nil
  end
  local f = io.open(tmp, "r")
  if not f then
    pcall(vim.fn.delete, tmp)
    return nil
  end
  local raw = f:read("*a")
  f:close()
  pcall(vim.fn.delete, tmp)

  for _, line in ipairs(vim.split(raw or "", "\r?\n")) do
    local trimmed = vim.trim(line)
    if trimmed ~= "" and not trimmed:match("^#") then
      local path = file_uri_to_path(trimmed)
      if path and IMAGE_EXTS[ext_of(path)] and vim.fn.filereadable(path) == 1 then
        return path
      end
      -- First real entry wasn't a readable image file; do not keep scanning
      -- later entries (matches "first file:// URI" from the spec).
      return nil
    end
  end
  return nil
end

----------------------------------------------------------------------
-- public API
----------------------------------------------------------------------

-- Inspects what the clipboard currently holds, without writing anything.
-- Returns one of:
--   { kind = "image", mime = "image/png" }
--   { kind = "file", path = "/abs/path.png" }
--   { kind = "text", mime = "text/plain" }
--   { kind = "none", error = "..." }   -- error set when detection itself failed
function M.detect()
  local raw, err = M.backend.targets()
  if not raw then
    return { kind = "none", error = err }
  end

  local offered = {}
  for _, line in ipairs(vim.split(raw, "\n", { plain = true })) do
    local t = vim.trim(line)
    if t ~= "" then
      offered[t] = true
    end
  end
  if not next(offered) then
    return { kind = "none" }
  end

  for _, mime in ipairs(IMAGE_MIME_ORDER) do
    if offered[mime] then
      return { kind = "image", mime = mime }
    end
  end

  if offered["text/uri-list"] then
    local path = resolve_uri_list_file()
    if path then
      return { kind = "file", path = path }
    end
    -- Not a usable image file URI: fall through to plain text below.
  end

  for _, mime in ipairs(TEXT_MIME_ORDER) do
    if offered[mime] then
      return { kind = "text", mime = mime }
    end
  end

  return { kind = "none" }
end

-- Writes the clipboard image to a file in the cache dir and returns its
-- path, or nil, err. opts.mime overrides the mime to read (defaults to
-- detecting one now). opts.keep overrides the prune retention count.
function M.save_image(opts)
  opts = opts or {}
  local mime = opts.mime
  if not mime then
    local info = M.detect()
    if info.kind ~= "image" then
      local reason = info.error or ("clipboard does not hold an image (kind: " .. info.kind .. ")")
      return nil, reason
    end
    mime = info.mime
  end

  local dir = ensure_cache_dir()
  local ext = EXT_FOR_MIME[mime] or "png"
  local path = unique_image_path(dir, ext)

  local ok, err = M.backend.read_to_file(mime, path)
  if not ok then
    return nil, err or "failed to read clipboard image"
  end

  local size = vim.fn.getfsize(path)
  if not size or size <= 0 then
    pcall(vim.fn.delete, path)
    return nil, "clipboard image read produced an empty file (clipboard owner vanished mid-read?)"
  end

  M.prune(dir, opts.keep)
  return path, nil
end

-- Reads a plain-text clipboard target as a Lua string. Returns text, nil or
-- nil, err. mime defaults to "text/plain".
function M.read_text(mime)
  mime = mime or "text/plain"
  local dir = ensure_cache_dir()
  local tmp = string.format("%s/.text-%d-%d.tmp", dir, os.time(), math.random(1, 1e6))
  local ok, err = M.backend.read_to_file(mime, tmp)
  if not ok then
    return nil, err or "failed to read clipboard text"
  end
  local f = io.open(tmp, "r")
  if not f then
    pcall(vim.fn.delete, tmp)
    return nil, "could not open clipboard text tempfile"
  end
  local content = f:read("*a")
  f:close()
  pcall(vim.fn.delete, tmp)
  return content, nil
end

return M
