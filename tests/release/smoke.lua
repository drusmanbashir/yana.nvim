local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":h:h:h")
local failures = {}

local function check(value, message)
  if value then
    print("PASS: " .. message)
  else
    failures[#failures + 1] = message
    print("FAIL: " .. message)
  end
end

check(vim.fn.isdirectory(root .. "/spec") == 0, "installed plugin has no internal specification tree")
local yana = require("yana")
local options = yana.setup({
  cmd = root .. "/tests/release/fake-cursor-agent",
  mode = "ask",
})
check(options.mode == "ask", "setup returns public configuration")
local legacy_name = "neo" .. "cursor"
check(not pcall(require, legacy_name), "old Lua namespace is absent")
check(vim.fn.exists(":Yana") == 2, "panel command exists")
check(vim.fn.exists(":YanaEdit") == 2, "inline-edit command exists")
check(vim.fn.exists(":" .. legacy_name:gsub("^%l", string.upper)) == 0, "old command is absent")

local ok_open, open_err = pcall(vim.cmd, "YanaOpen")
check(ok_open, "panel entry opens: " .. tostring(open_err))
if ok_open then
  check(require("yana.ui").is_open(), "panel is visible to Neovim")
  pcall(vim.cmd, "YanaClose")
end

local rows = require("yana.dependencies").check("agentic")
local by_id = {}
for _, item in ipairs(rows) do
  by_id[item.id] = item
end
check(by_id["nvim:min"] and by_id["nvim:min"].level == "ok", "declared Neovim floor passes")
check(by_id["exec:cursor-agent"] and by_id["exec:cursor-agent"].level == "ok", "fixture agent resolves")

if #failures > 0 then
  error(string.format("release smoke failed: %s", table.concat(failures, "; ")))
end
print("ALL PASS: yana release smoke")
