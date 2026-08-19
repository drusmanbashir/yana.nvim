local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":h:h:h")
local target = assert(os.getenv("RELEASE_MISSING_EXEC"), "RELEASE_MISSING_EXEC required")
local dependencies = require("yana.dependencies")
local config = require("yana.config")

config.setup({ cmd = root .. "/tests/release/fake-cursor-agent", mode = "inline" })

local function die(message)
  error("dependency smoke: " .. message)
end

local rows = dependencies.check("inline")
local wanted
for _, item in ipairs(rows) do
  if item.id == "exec:" .. target then
    wanted = item
    break
  end
end
if not wanted or wanted.level ~= "error" or not wanted.remedy or wanted.remedy == "" then
  die("health row does not name missing dependency and remedy: " .. target)
end

local ready, preflight_error = dependencies.preflight("inline")
if ready or not preflight_error:find("[" .. wanted.id .. "]", 1, true)
  or not preflight_error:find(wanted.remedy, 1, true) then
  die("preflight disagrees with dependency row: " .. tostring(preflight_error))
end

local emitted = {}
local original_health = vim.health
local original_check = dependencies.check
vim.health = {
  start = function() end,
  ok = function() end,
  warn = function() end,
  error = function(message, advice)
    emitted[#emitted + 1] = { message = message, advice = advice }
  end,
}
dependencies.check = function()
  return { wanted }
end
package.loaded["yana.health"] = nil
require("yana.health").check()
dependencies.check = original_check
vim.health = original_health
package.loaded["yana.health"] = nil

local health_match = false
for _, item in ipairs(emitted) do
  local advice = item.advice and item.advice[1] or ""
  if item.message:find("[" .. wanted.id .. "]", 1, true) and advice == wanted.remedy then
    health_match = true
  end
end
if not health_match then
  die("health output disagrees with dependency row")
end

local done_code, done_message
local job = require("yana.agent").run({
  prompt = "must not start",
  jail_session = {},
  on_done = function(code, message)
    done_code, done_message = code, message
  end,
})
if job ~= nil or done_code ~= -1 or not done_message:find("[" .. wanted.id .. "]", 1, true)
  or not done_message:find(wanted.remedy, 1, true) then
  die("spawn preflight did not refuse with the shared row")
end

print("ALL PASS: missing dependency " .. target)
