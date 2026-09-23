-- blink.cmp source: yana slash commands. Adapter over yana.commands.get_commands().
-- enabled() is scoped on b:yana_prompt, not filetype (panel buffers are markdown).

local M = {}

function M.new()
	return setmetatable({}, { __index = M })
end

function M:enabled()
	return vim.b[vim.api.nvim_get_current_buf()].yana_prompt == true
end

function M:get_trigger_characters()
	return { "/" }
end

-- `/` completes at line start or after whitespace, so `src/foo` never opens the menu.
local function at_slash_trigger(ctx)
	local before = ctx.line:sub(1, ctx.cursor[2])
	return before:match("^/%S*$") ~= nil or before:match("%s/%S*$") ~= nil
end

function M:get_completions(ctx, callback)
	local ok, items = pcall(function()
		if not at_slash_trigger(ctx) then
			return {}
		end
		local panel = require("yana.panel.ui").focused_panel()
		if not panel then
			return {}
		end
		local list = require("yana.commands").get_commands(panel)
		local kinds = require("blink.cmp.types").CompletionItemKind
		-- Skills get a different icon AND a `label_description`, so the distinction survives theming.
		local out = {}
		for _, c in ipairs(list) do
			local is_skill = c.kind == "skill"
			out[#out + 1] = {
				label = "/" .. c.name,
				kind = is_skill and kinds.Module or kinds.Function,
				label_description = is_skill and "skill" or nil,
				insertText = "/" .. c.name,
				documentation = { kind = "markdown", value = c.details or c.description or "" },
			}
		end
		return out
	end)
	if not ok then
		require("yana.log").write("WARN", "blink_yana.commands: get_completions failed: " .. tostring(items))
	end
	callback({ items = ok and items or {}, is_incomplete_forward = false, is_incomplete_backward = false })
end

return M
