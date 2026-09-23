-- yana: generic long-scheduler descriptor comparison seam.
--
-- This module reports vendor drift.
local M = {}

local function is_null(value)
  return value == nil or (vim.NIL ~= nil and value == vim.NIL)
end

local function is_array(value)
  if type(value) ~= "table" then
    return false
  end
  local count = 0
  for key in pairs(value) do
    if type(key) ~= "number" or key < 1 or key % 1 ~= 0 then
      return false
    end
    count = math.max(count, key)
  end
  for index = 1, count do
    if value[index] == nil then
      return false
    end
  end
  return true
end

local function quote(value)
  return string.format('%q', tostring(value))
end

local function format_value(value)
  if is_null(value) then
    return "<deleted>"
  end
  if type(value) == "string" then
    return quote(value)
  end
  if type(value) ~= "table" then
    return tostring(value)
  end

  if is_array(value) then
    local items = {}
    for index = 1, #value do
      items[#items + 1] = format_value(value[index])
    end
    return "[" .. table.concat(items, ",") .. "]"
  end

  local keys = {}
  for key in pairs(value) do
    keys[#keys + 1] = tostring(key)
  end
  table.sort(keys)
  local items = {}
  for _, key in ipairs(keys) do
    items[#items + 1] = key .. "=" .. format_value(value[key])
  end
  return "{" .. table.concat(items, ", ") .. "}"
end

local function sorted_keys(left, right)
  local seen, keys = {}, {}
  for key in pairs(left or {}) do
    seen[key] = true
    keys[#keys + 1] = key
  end
  for key in pairs(right or {}) do
    if not seen[key] then
      keys[#keys + 1] = key
    end
  end
  table.sort(keys, function(a, b)
    return tostring(a) < tostring(b)
  end)
  return keys
end

local function collect_changes(path, current, expected, changes)
  if type(current) == "table" and type(expected) == "table" then
    for _, key in ipairs(sorted_keys(current, expected)) do
      local child_path = path == "" and tostring(key) or path .. "." .. tostring(key)
      collect_changes(child_path, current[key], expected[key], changes)
    end
    return
  end
  if is_null(current) and is_null(expected) then
    return
  end
  if type(current) == type(expected) and current == expected then
    return
  end
  changes[#changes + 1] = path .. " = " .. format_value(current) .. " -> " .. format_value(expected)
end

--- Report descriptor drift without changing either descriptor.
---@param entry_id string
---@param current table configured descriptor
---@param expected table fixture descriptor
---@param notify fun(message: string)
---@return boolean changed whether the fixture differs from the descriptor
function M.report_descriptor_drift(entry_id, current, expected, notify)
  assert(type(entry_id) == "string" and entry_id ~= "", "entry_id must be non-empty")
  assert(type(current) == "table", "current descriptor must be a table")
  assert(type(expected) == "table", "expected descriptor must be a table")
  assert(type(notify) == "function", "notify callback is required")

  local changes = {}
  collect_changes("", current, expected, changes)
  if #changes == 0 then
    return false
  end

  notify("vendor drift [" .. entry_id .. "]: " .. table.concat(changes, "; ")
    .. "; descriptor unchanged (reported only)")
  return true
end

return M
