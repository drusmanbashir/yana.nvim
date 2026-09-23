local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":h:h:h")
require("yana.config").setup({ cmd = root .. "/tests/release/fake-cursor-agent", mode = "inline" })

local dependencies = require("yana.runtime.dependencies")
local ready, reason = dependencies.preflight("inline")
assert(ready, "optional tools became hard dependencies: " .. tostring(reason))

-- dependency_gate.sh runs this file on a PATH holding only the required
-- executables, so an absent sqlite3/md5 is what preflight just accepted; if
-- the fixture ever leaks them in, this stops proving anything.
for _, optional in ipairs({ "sqlite3", "md5" }) do
  assert(vim.fn.executable(optional) == 0, "fixture PATH supplies " .. optional .. "; absence no longer proven")
end
assert(require("blink_yana.commands").new(), "command source fails without blink loaded")
assert(require("blink_yana.mentions").new(), "mention source fails without blink loaded")
print("ALL PASS: optional dependencies remain optional")
