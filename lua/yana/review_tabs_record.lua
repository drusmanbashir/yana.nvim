-- The review-tab ownership record on disk: one JSON file per turn naming the
-- tabs Yana opened. Owner of every read and write of that file; the live
-- record it mirrors is `st.review_tabs` (lua/yana/review_tabs.lua).
local M = {}

function M.state_path(opts)
  if opts and type(opts.review_tabs_state_path) == "string" and opts.review_tabs_state_path ~= "" then
    return opts.review_tabs_state_path
  end
  return nil
end

function M.read_json(path)
  if type(path) ~= "string" or path == "" then
    return nil
  end
  local fh = io.open(path, "rb")
  if not fh then
    return nil
  end
  local raw = fh:read("*a")
  fh:close()
  if type(raw) ~= "string" or raw == "" then
    return nil
  end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then
    return nil
  end
  return decoded
end

function M.write_json(path, value)
  local dir = vim.fn.fnamemodify(path, ":h")
  if dir and dir ~= "" then
    pcall(vim.fn.mkdir, dir, "p")
  end
  local ok, payload = pcall(vim.json.encode, value)
  if not ok or type(payload) ~= "string" then
    return false
  end
  local fh = io.open(path, "wb")
  if not fh then
    return false
  end
  fh:write(payload)
  fh:close()
  return true
end

-- Persist one turn record.
function M.save(rt)
  if type(rt) ~= "table" or not rt.state_path or not rt.turn_key then
    return false
  end
  local owned = {}
  for abs, entry in pairs(rt.owned or {}) do
    owned[abs] = { tab_id = entry.tab_id, rel = entry.rel }
  end
  local ever_owned = {}
  for abs, _ in pairs(rt.ever_owned or {}) do
    ever_owned[abs] = true
  end
  for abs, _ in pairs(owned) do
    ever_owned[abs] = true
  end
  rt.ever_owned = ever_owned
  return M.write_json(rt.state_path, {
    version = 1,
    turn_key = rt.turn_key,
    sidebar_open = rt.sidebar_open,
    owned = owned,
    ever_owned = ever_owned,
  })
end

return M
