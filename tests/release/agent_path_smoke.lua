local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":h:h:h")
local scratch = assert(os.getenv("RELEASE_AGENT_SCRATCH"), "RELEASE_AGENT_SCRATCH required")
local agent = scratch .. "/cursor-agent"
vim.fn.mkdir(scratch, "p")
vim.fn.writefile({ "#!/bin/sh", "exit 0" }, agent)
vim.uv.fs_chmod(agent, 493)

require("yana.config").setup({ cmd = agent, mode = "inline" })
local dependencies = require("yana.dependencies")
local before
for _, row in ipairs(dependencies.check("inline")) do
  if row.id == "exec:cursor-agent" then before = row end
end
assert(before and before.level == "ok", "fixture agent did not resolve")
assert(vim.uv.fs_rename(agent, agent .. ".moved"), "could not move fixture agent")

local done_code, done_message
local job = require("yana.agent").run({
  prompt = "must not start",
  jail_session = {},
  on_done = function(code, message)
    done_code, done_message = code, message
  end,
})
assert(job == nil and done_code == -1, "moved agent path reached spawn")
assert(done_message:find("[exec:cursor-agent]", 1, true), "moved agent refusal lacks dependency ID")
assert(done_message:find("install and sign in", 1, true), "moved agent refusal lacks remedy")
print("ALL PASS: moved agent path is revalidated")
