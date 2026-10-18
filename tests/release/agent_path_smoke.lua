-- FAMILY: dependency_gate's moved-agent refusal and selected-binary version labels.
local source = debug.getinfo(1, "S").source:sub(2)
local root = vim.fn.fnamemodify(source, ":h:h:h")
local scratch = assert(os.getenv("RELEASE_AGENT_SCRATCH"), "RELEASE_AGENT_SCRATCH required")
local agent = scratch .. "/cursor-agent"
vim.fn.mkdir(scratch, "p")
vim.fn.writefile({ "#!/bin/sh", "echo fixture-version" }, agent)
vim.uv.fs_chmod(agent, 493)

require("yana.config").setup({ backends = { cursor = { cmd = agent } }, mode = "inline" })
local dependencies = require("yana.runtime.dependencies")
for _, backend in ipairs({ "cursor", "claude", "codex" }) do
  local binary = backend == "cursor" and "cursor-agent" or backend
  local path = scratch .. "/" .. binary
  vim.fn.writefile({ "#!/bin/sh", "echo fixture-version" }, path)
  vim.uv.fs_chmod(path, 493)
  require("yana.config").setup({ backends = { default = backend, [backend] = { cmd = path } }, mode = "agentic" })
  local version
  for _, item in ipairs(dependencies.check("agentic")) do
    if item.id == "exec:" .. binary .. "-version" then version = item end
  end
  assert(version and version.message == binary .. " version: fixture-version",
    "version health row does not name selected binary " .. binary)
end
require("yana.config").setup({ backends = { default = "cursor", cursor = { cmd = agent } }, mode = "inline" })
local before
for _, row in ipairs(dependencies.check("inline")) do
  if row.id == "exec:cursor-agent" then before = row end
end
assert(before and before.level == "ok", "fixture agent did not resolve")
assert(vim.uv.fs_rename(agent, agent .. ".moved"), "could not move fixture agent")

local done_code, done_message
local job = require("yana.agent.agent").run({
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
