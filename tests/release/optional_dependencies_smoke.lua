local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":h:h:h")
require("yana.config").setup({ cmd = root .. "/tests/release/fake-cursor-agent", mode = "inline" })

local dependencies = require("yana.dependencies")
local ready, reason = dependencies.preflight("inline")
assert(ready, "optional tools became hard dependencies: " .. tostring(reason))

local rows = {}
for _, row in ipairs(dependencies.check("inline")) do
  rows[row.id] = row
end
assert(rows["exec:sqlite3"] and rows["exec:sqlite3"].level == "warn", "missing sqlite3 is not optional")
assert(rows["exec:md5"] and rows["exec:md5"].level == "warn", "missing md5 helper is not optional")
assert(require("blink_yana.commands").new(), "command source fails without blink loaded")
assert(require("blink_yana.mentions").new(), "mention source fails without blink loaded")
print("ALL PASS: optional dependencies remain optional")
