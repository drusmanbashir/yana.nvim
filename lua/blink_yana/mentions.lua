-- blink.cmp source: yana @mentions.
--
-- A dumb adapter over yana.mentions — reads ONLY that module's
-- get_mentions() and knows nothing about panel internals beyond the panel
-- handle yana.ui.focused_panel() gives it.
--
-- enabled() is scoped on b:yana_prompt, never filetype (see
-- blink_yana/commands.lua for why).

local M = {}

function M.new()
	return setmetatable({}, { __index = M })
end

function M:enabled()
	return vim.b[vim.api.nvim_get_current_buf()].yana_prompt == true
end

function M:get_trigger_characters()
	return { "@" }
end

function M:get_completions(ctx, callback)
	local ok, items = pcall(function()
		local panel = require("yana.ui").focused_panel()
		if not panel then
			return {}
		end
		local list = require("yana.mentions").get_mentions(panel)
		local kind = require("blink.cmp.types").CompletionItemKind.Variable
		local out = {}
		for _, m in ipairs(list) do
			out[#out + 1] = {
				label = "@" .. m.command,
				kind = kind,
				insertText = "@" .. m.command,
				documentation = { kind = "markdown", value = m.details or m.description or "" },
			}
		end
		return out
	end)
	-- get_completions never throws into blink: on failure, empty list -- but
	-- the failure itself was previously swallowed with no trace anywhere.
	if not ok then
		require("yana.log").write("WARN", "blink_yana.mentions: get_completions failed: " .. tostring(items))
	end
	callback({ items = ok and items or {}, is_incomplete_forward = false, is_incomplete_backward = false })
end

-- On accept: insert the mention text as usual, then fire the mention's own
-- callback if it has one (@file opens the picker, @buffers/@quickfix insert
-- paths). @diagnostics has no callback — it is strip-and-flag, handled at
-- submit time by yana.mentions.extract_mentions, not here.
function M:execute(_ctx, item, resolve, default_implementation)
	default_implementation()
	local ok, err = pcall(function()
		local panel = require("yana.ui").focused_panel()
		if not panel then
			return
		end
		local list = require("yana.mentions").get_mentions(panel)
		local cmd = item.insertText and item.insertText:match("^@(.+)$")
		for _, m in ipairs(list) do
			if m.command == cmd and m.callback then
				m.callback(panel)
				break
			end
		end
	end)
	if not ok then
		require("yana.log").write("WARN", "blink_yana.mentions: execute failed: " .. tostring(err))
	end
	resolve()
end

return M
