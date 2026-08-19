-- yana: :checkhealth yana
local config = require("yana.config")
local dependencies = require("yana.dependencies")

local M = {}

local health = vim.health or require("health")
local start = health.start or health.report_start
local ok = health.ok or health.report_ok
local warn = health.warn or health.report_warn
local err = health.error or health.report_error

function M.check()
  start("yana")

  for _, item in ipairs(dependencies.check(config.options.mode)) do
    local message = string.format("[%s] %s", item.id, item.message)
    if item.level == "ok" then
      ok(message)
    elseif item.level == "warn" then
      warn(message, item.remedy and { item.remedy } or nil)
    else
      err(message, item.remedy and { item.remedy } or nil)
    end
  end

  local mode = config.options.mode
  if mode == "agentic" then
    warn("mode = 'agentic': explicit enable_agentic opt-in is active. The agent writes files directly; there is no overlay, review, or diary.")
  elseif mode == "inline" and config.agent_needs_permission_flag() then
    warn(
      "mode = 'inline': the agent runs confined in the overlay and every change is reviewed before it reaches disk, "
        .. "but its argv carries the vendor permission-bypass flag. "
        .. "Your protection is Yana's host-enforced overlay plus review, not the vendor's prompts. See :help yana-security."
    )
  else
    ok("default mode: " .. tostring(mode))
  end
  if config.options.approve_mcps then
    warn("approve_mcps = true: MCP servers are auto-approved (--approve-mcps).")
  end

  local log = require("yana.log")
  if log.durable_healthy() then
    ok("durable log: healthy (" .. log.path .. ")")
  else
    err("durable log: unhealthy — " .. tostring(log.durable_unhealthy_reason() or "unknown"))
  end
end

return M
