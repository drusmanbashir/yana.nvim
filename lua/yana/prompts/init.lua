-- The one loader for agent-facing text; wording lives in prompts/templates.lua.
local M = {}

local templates = require("yana.prompts.templates")

--- Template `key` with each `{name}` replaced by `tostring(vars[name])`.
--- An unknown key or a missing var is an error, never blank text.
function M.render(key, vars)
  local template = templates[key]
  if type(template) ~= "string" then
    error("yana.prompts: no template named " .. tostring(key), 2)
  end
  return (template:gsub("{([%w_]+)}", function(name)
    local value = vars and vars[name]
    if value == nil then
      error("yana.prompts: template " .. key .. " needs {" .. name .. "}")
    end
    return tostring(value)
  end))
end

return M
