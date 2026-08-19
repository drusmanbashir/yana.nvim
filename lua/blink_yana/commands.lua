-- blink.cmp source: yana slash commands.
--
-- A dumb adapter over yana.commands — reads ONLY that module's
-- get_commands() and knows nothing about panel internals beyond the panel
-- handle yana.ui.focused_panel() gives it.
--
-- enabled() is scoped on b:yana_prompt, never filetype: both yana
-- panel buffers are filetype=markdown, so a filetype-scoped source would
-- fire in every markdown file the user edits.

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

-- `/` completes at a word boundary: start of any prompt line, or after
-- whitespace mid-sentence. The whitespace requirement is what keeps ordinary
-- paths quiet -- `src/foo`, `a/b` have a non-space char before the slash, so
-- they never open the menu -- while `please /rev` does, which is the Cursor
-- behaviour. A bare `/` with no match is harmless: blink hides the menu as
-- soon as the typed keyword stops matching any command.
local function at_slash_trigger(ctx)
	local before = ctx.line:sub(1, ctx.cursor[2])
	return before:match("^/%S*$") ~= nil or before:match("%s/%S*$") ~= nil
end

function M:get_completions(ctx, callback)
	local ok, items = pcall(function()
		if not at_slash_trigger(ctx) then
			return {}
		end
		local panel = require("yana.ui").focused_panel()
		if not panel then
			return {}
		end
		local list = require("yana.commands").get_commands(panel)
		local kinds = require("blink.cmp.types").CompletionItemKind
		-- Distinguish skills from commands in the menu: a different icon
		-- (Module vs Function) AND a labelled `label_description` column
		-- (blink.lua's menu.draw.columns already renders label_description
		-- next to the label) — belt and braces so the distinction survives
		-- any menu-theming that drops one of the two signals.
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
	-- get_completions never throws into blink: on failure, empty list -- but
	-- the failure itself was previously swallowed with no trace anywhere.
	if not ok then
		require("yana.log").write("WARN", "blink_yana.commands: get_completions failed: " .. tostring(items))
	end
	callback({ items = ok and items or {}, is_incomplete_forward = false, is_incomplete_backward = false })
end

return M
